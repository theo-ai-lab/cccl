#!/usr/bin/env bash

# Compare the SASS of the CUB benchmarks between two git refs.
#
# The script adds a worktree for each ref, builds the selected benchmark targets
# in both, dumps the disassembly of every built binary with `cuobjdump -sass`,
# and compares the result.
#
# Exit status:
#   0  the SASS is unchanged,
#   1  the SASS changed. The report was written and printed,
#   2+ the build or the comparison itself failed.
#
# A changed SASS therefore marks the CI job as failed, which makes it visible in
# the job list. That job is left out of the aggregate `ci` branch-protection
# job, so a difference never gates a merge.
#
# No GPU is necessary. The targets are compiled and disassembled, not run.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <base-ref> <test-ref> [options]

Compare CUB benchmark SASS between two git refs, for example:

  $0 origin/main HEAD -arch all-major-cccl

Options:
  -preset <name>            CMake preset. Default: "cub-benchmark".
  -target-filter <regex>    Regex matched against the ninja target names
                            (repeatable). Default: "^cub\\\\.bench\\\\.".
  -target-filters-json <j>  The same filters as a JSON array. Used by CI, which
                            reads them from ci/matrix.yaml.
  -output-dir <path>        Artifact directory. Default: "<repo>/sass-artifacts".

Every other option goes to ci/build_common.sh; run it with -h for the list.
-configure is not among them: both sides must be built to be compared. Note that
the cub-benchmark preset sets the architecture to "native", so -arch must be
given for a multi-architecture comparison.

The artifact directory holds the raw dumps under base/ and test/. Under result/
it holds the normalized text the comparison acted on (base/ and test/), the
unified diff of every changed architecture (diff/), report.json and summary.md.
EOF
}

PRESET="cub-benchmark"
OUTPUT_DIR=""
TARGET_FILTERS=()
declare -a common_args=()

[[ "$#" -ge 2 ]] || { usage; exit 2; }
BASE_REF="$1"
TEST_REF="$2"
shift 2

# Take the sass-specific options and leave the rest for `build_common.sh`, which
# parses `$@` as its own. Same split as `ci/build_compile_time_bench.sh`.
while (($#)); do
  case "$1" in
    -h|-help|--help)           usage; exit 0 ;;
    -preset)                   PRESET="$2"; shift 2 ;;
    -output-dir)               OUTPUT_DIR="$2"; shift 2 ;;
    -target-filter)            TARGET_FILTERS+=("$2"); shift 2 ;;
    -configure)
      echo "-configure cannot be used: both sides must be built to compare." >&2
      exit 2
      ;;
    -target-filters-json)
      # The CI job has the filters as a JSON array, from ci/matrix.yaml. Taking
      # them directly saves the workflow from unpacking them into flags. An
      # empty array must not become one empty filter, which matches everything.
      # `mapfile` does not see the exit status of jq, so an empty result covers
      # both a parse error and an empty array.
      mapfile -t json_filters < <(jq -er '.[]' <<< "$2")
      if [[ "${#json_filters[@]}" -eq 0 ]]; then
        echo "-target-filters-json needs a non-empty JSON array, got: $2" >&2
        exit 2
      fi
      TARGET_FILTERS+=("${json_filters[@]}")
      shift 2
      ;;
    *) common_args+=("$1"); shift ;;
  esac
done

[[ "${#TARGET_FILTERS[@]}" -gt 0 ]] || TARGET_FILTERS=('^cub\.bench\.')
# One alternation, so a target is matched with a single grep.
filter_regex="$(IFS='|'; echo "${TARGET_FILTERS[*]}")"
readonly filter_regex

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
ci_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${ci_dir}/.." && pwd)"
readonly repo_root

# `build_common.sh` declares readonly globals, so it can only be sourced once per
# process. Each side sources its own copy in `run_side`; the parent needs the
# logging helpers only.
# shellcheck source=ci/pretty_printing.sh
source "${ci_dir}/pretty_printing.sh"

# Per cub/benchmarks/CMakeLists.txt: <path>/<stem>.cu -> cub.<path>.<stem>.base.
# Reading the source tree means no configured build tree is needed here.
matching_targets() {
  find "$1/cub/benchmarks" -name '*.cu' -printf '%P\n' \
    | sed -e 's/\.cu$/.base/' -e 's|/|.|g' -e 's/^/cub./' \
    | grep -E -- "${filter_regex}" \
    | sort -u
}

# ============================================================================
# Test the comparison scripts
# ============================================================================

# Before the builds, because a broken script would otherwise be found only after
# them. The suite runs in well under a second. `pytest` is absent from some
# images, and a comparison must not fail because of that, so a missing pytest is
# reported and skipped.
if python3 -c 'import pytest' 2>/dev/null; then
  run_command "🧪 Test SASS scripts" python3 -m pytest "${script_dir}" -q
else
  echo "pytest is not installed; skipping the tests of the comparison scripts." >&2
fi

# ============================================================================
# Set up both worktrees
# ============================================================================

# The base ref can be a remote branch that was not fetched yet. `rev-parse` does
# not name the ref it rejected, so print both here.
git -C "${repo_root}" fetch --no-tags origin "${BASE_REF}" >/dev/null 2>&1 || true
echo "Resolving ${BASE_REF} and ${TEST_REF}..."
base_commit="$(git -C "${repo_root}" rev-parse --verify "${BASE_REF}^{commit}")"
test_commit="$(git -C "${repo_root}" rev-parse --verify "${TEST_REF}^{commit}")"

artifact_dir="${OUTPUT_DIR:-${repo_root}/sass-artifacts}"
mkdir -p "${artifact_dir}"/{base,test,meta,result}
artifact_dir="$(cd "${artifact_dir}" && pwd)"

# A fixed path, never `mktemp -d`. The path of the compilation unit reaches the
# preprocessed source, so it is part of the sccache key. With a fresh random path
# per run, no run could ever hit what an earlier run stored, and every object was
# compiled cold on both sides.
worktree_root="${repo_root}/build/sass-worktrees"
base_path="${worktree_root}/base"
test_path="${worktree_root}/test"

echo "Base ref:  ${BASE_REF} (${base_commit})"
echo "Test ref:  ${TEST_REF} (${test_commit})"
echo "Preset:    ${PRESET}"
echo "Artifacts: ${artifact_dir}"

# Remove the worktrees on a normal exit and on the signals CI sends when a job
# is cancelled; without the signal traps a cancelled job leaves them registered.
# shellcheck disable=SC2329  # Invoked indirectly by the traps below.
cleanup() { git -C "${repo_root}" worktree remove --force "$1" >/dev/null 2>&1 || true; }
# shellcheck disable=SC2329  # Invoked indirectly by the traps below.
cleanup_all() {
  cleanup "${base_path}"
  cleanup "${test_path}"
  rm -rf "${worktree_root}"
  [[ "$#" -eq 0 ]] || { trap - EXIT HUP INT TERM; exit "$1"; }
}
trap cleanup_all EXIT
trap 'cleanup_all 129' HUP
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

declare -A side_path=([base]="${base_path}" [test]="${test_path}")
declare -A side_commit=([base]="${base_commit}" [test]="${test_commit}")
declare -A preset_dir=()

for side in base test; do
  # The path is fixed, so a run that was killed can have left it behind. The
  # prune drops the registration that `rm -rf` leaves stale.
  cleanup "${side_path[${side}]}"
  rm -rf "${side_path[${side}]}"
  git -C "${repo_root}" worktree prune
  git -C "${repo_root}" worktree add --detach \
    "${side_path[${side}]}" "${side_commit[${side}]}" >/dev/null
  # Pin the build configuration to the current tree, so a preset change is not
  # measured as a code change. Copy, never symlink: CMake resolves ${sourceDir}
  # from the real path of this file, and a symlink would point it at the current
  # checkout instead of the worktree.
  cp "${repo_root}/CMakePresets.json" "${side_path[${side}]}/CMakePresets.json"
done

# ============================================================================
# Build both sides
# ============================================================================

# `build_common.sh` derives its paths from where it is sourced. Never symlink
# into a worktree: that resolves back to the current checkout.
run_side() {
  local side="$1"
  shift
  local -a cmd=("$@")
  (
    cd "${side_path[${side}]}/ci"
    # `build_common.sh` parses `$@` as its own arguments.
    set -- "${common_args[@]}"
    # shellcheck source=ci/build_common.sh
    source ./build_common.sh
    "${cmd[@]}"
  )
}

# Both sides use the same toolchain, so one report is enough. It names the
# compilers and says whether sccache was found, which is what a slow run needs.
run_side base print_environment_details

for side in base test; do
  # shellcheck disable=SC2031  # `build_common.sh` shadows PRESET locally.
  run_side "${side}" configure_preset "SASS ${side}" "${PRESET}"
  # The preset's binaryDir; `run_side` only reads these, never assigns them.
  # shellcheck disable=SC2031
  preset_dir[${side}]="${side_path[${side}]}/build/${CCCL_BUILD_INFIX:-}/${PRESET}"
done

# The architectures the build really used, for the report header.
report_arch="$(
  awk -F= '/^CMAKE_CUDA_ARCHITECTURES:/ {print $2}' "${preset_dir[test]}/CMakeCache.txt"
)"

# Only the targets both sides have can be compared. A target that only one side
# has is reported separately by compare_sass.py.
mapfile -t targets < <(
  comm -12 <(matching_targets "${side_path[base]}") \
           <(matching_targets "${side_path[test]}")
)
# An empty intersection is a successful `comm`, so it must be caught here.
# `--target` with no target would otherwise build everything.
if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "No CUB benchmark target common to both sides matched: ${filter_regex}" >&2
  exit 1
fi
printf "%s\n" "${targets[@]}" > "${artifact_dir}/meta/selected_targets.txt"
echo "Selected ${#targets[@]} benchmark target(s)."

for side in base test; do
  # shellcheck disable=SC2031  # `build_common.sh` shadows PRESET locally.
  run_side "${side}" build_preset "SASS ${side}" "${PRESET}" --target "${targets[@]}"
done

# ============================================================================
# Dump and compare
# ============================================================================

# `cu++filt` strips the path hash and the pid that nvcc puts in the name of an
# internal-linkage or anonymous-namespace entity. Both differ between the two
# worktrees, so without it every such kernel compares as changed.
# shellcheck disable=SC2329  # Invoked indirectly by `run_command`.
dump_side() {
  local side="$1"
  # `pipefail` again, because `bash -c` starts a fresh shell. Without it a failed
  # `cuobjdump` writes an empty dump and still reports success.
  printf '%s\n' "${targets[@]}" \
    | xargs -P "$(nproc)" -I{} bash -c \
        "set -o pipefail; cuobjdump -sass -sort '${preset_dir[${side}]}/bin/{}' | cu++filt > '${artifact_dir}/${side}/{}.sass'"
}

for side in base test; do
  run_command "🔍 Dump SASS ${side}" dump_side "${side}"
done

# What `render_report.py` cannot work out for itself: the refs that were
# compared and the architectures the build really used. The URL of the artifacts
# is not here, because it exists only after CI uploaded them.
jq -n \
  --arg base_ref "${BASE_REF}" \
  --arg test_ref "${TEST_REF}" \
  --arg arch "${report_arch}" \
  '$ARGS.named' > "${artifact_dir}/result/meta.json"

# The comparison returns 1 when the SASS changed and 2 when it broke. Both must
# still be reported, so the status is captured here and acted on at the end,
# after the summary was rendered and printed.
compare_status=0
run_command "📊 Compare SASS" \
  python3 "${script_dir}/compare_sass.py" \
  --base-dir "${artifact_dir}/base" \
  --test-dir "${artifact_dir}/test" \
  --output-dir "${artifact_dir}/result" \
  --verbose || compare_status=$?

# A broken comparison has no report to render, so it stops here.
if [[ "${compare_status}" -ge 2 ]]; then
  echo "The SASS comparison failed with status ${compare_status}." >&2
  exit "${compare_status}"
fi

run_command "📝 Render report" \
  python3 "${script_dir}/render_report.py" \
  --report "${artifact_dir}/result/report.json" \
  --meta "${artifact_dir}/result/meta.json" \
  --output "${artifact_dir}/result/summary.md"

echo
cat "${artifact_dir}/result/summary.md"
echo
echo "Wrote report:  ${artifact_dir}/result/report.json"
echo "Wrote summary: ${artifact_dir}/result/summary.md"

print_time_summary

# A SASS difference exits non-zero, so that the CI job is marked as failed and
# the change is visible in the job list.
if [[ "${compare_status}" -ne 0 ]]; then
  echo "The SASS changed. See the summary above." >&2
fi
exit "${compare_status}"
