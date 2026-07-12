#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

diff_range() {
  local range

  if range="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    && git merge-base "$range" HEAD >/dev/null; then
    printf '%s\n' "${range}...HEAD"
  elif git rev-parse --verify --quiet origin/main >/dev/null \
    && git merge-base origin/main HEAD >/dev/null; then
    printf 'origin/main...HEAD\n'
  else
    return 1
  fi
}

changed_paths() {
  local range

  if range="$(diff_range)"; then
    git diff --no-ext-diff --name-only --diff-filter=ACMRTUXB "$range"
  else
    git diff-tree --no-commit-id --name-only --diff-filter=ACMRTUXB --root -r HEAD
  fi
}

check_whitespace() {
  local range

  if range="$(diff_range)"; then
    run git diff --no-ext-diff --check "$range"
  else
    run git diff-tree --check --no-commit-id --root -r HEAD
  fi
}

run_focused_targets_for_changed_paths() {
  local targets
  targets="$(script/focused_test_targets.sh "$@")"

  if [[ -z "$targets" ]]; then
    return 0
  fi

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    run swift test --filter "$target"
  done <<< "$targets"
}

# ReleaseBuildNumberDerivationTests/ReleaseUpdateScriptTests/AppBundlePackagingTests
# are listed here unconditionally, not left to the path-diff-based mapping
# in focused_test_targets.sh below (PR #253 review comment on
# script/focused_test_targets.sh:62): the release workflow's "Run release
# test gate" step runs THIS script against a detached tag checkout, where
# diff_range() falls back to origin/main...HEAD -- and when the tag points
# at current origin/main, that diff is empty, so changed_paths() never
# surfaces .github/workflows/release.yml or script/build_and_run.sh and the
# path-based mapping is never consulted. Running these here guarantees the
# release-number regression suite always executes before a tag is signed,
# regardless of diff state.
FOCUSED_SWIFT_TEST_FILTER="ArchitectureFitnessTests.ArchitectureFitnessTests|RuntimeReadinessServiceTests|WorkspacePersistenceTests|AgentRuntimeAdapterTests|TaskContextStateTests|CapsuleSnapshotTests|CapsuleSelectionPressureTests|ExecutionSandboxTests|RuntimePolicyGuardTests|CopilotCLICommandPlanningTests|TaskCapabilityResolverTests|RunPermissionManifestTests|ReleaseBuildNumberDerivationTests|ReleaseUpdateScriptTests|AppBundlePackagingTests"

run swift test --filter "$FOCUSED_SWIFT_TEST_FILTER"
run script/focused_test_targets_tests.sh
changed_files=()
while IFS= read -r path; do
  changed_files+=("$path")
done < <(changed_paths)
if ((${#changed_files[@]} > 0)); then
  run_focused_targets_for_changed_paths "${changed_files[@]}"
fi
check_whitespace
