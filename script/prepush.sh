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

run_validation_plan() {
  local plan="$1"
  local lane

  ROOT_VALIDATION_REQUIRED=0
  while IFS= read -r lane; do
    case "$lane" in
      git-contracts)
        run script/test_git_contracts.sh
        ;;
      root)
        ROOT_VALIDATION_REQUIRED=1
        ;;
      "")
        ;;
      *)
        echo "Unknown focused validation lane: $lane" >&2
        return 2
        ;;
    esac
  done <<< "$plan"
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
FOCUSED_SWIFT_TEST_FILTER="RuntimeReadinessServiceTests|WorkspacePersistenceTests|AgentRuntimeAdapterTests|TaskContextStateTests|CapsuleSnapshotTests|CapsuleSelectionPressureTests|ExecutionSandboxTests|RuntimePolicyGuardTests|CopilotCLICommandPlanningTests|TaskCapabilityResolverTests|RunPermissionManifestTests|ReleaseBuildNumberDerivationTests|ReleaseUpdateScriptTests|AppBundlePackagingTests"

changed_files=()
while IFS= read -r path; do
  changed_files+=("$path")
done < <(changed_paths)

run script/test_architecture.sh
if ((${#changed_files[@]} > 0)); then
  run_validation_plan "$(script/focused_validation_plan.sh "${changed_files[@]}")"
else
  run_validation_plan "$(script/focused_validation_plan.sh)"
fi

if [[ "$ROOT_VALIDATION_REQUIRED" == "1" ]]; then
  run swift test --filter "$FOCUSED_SWIFT_TEST_FILTER"
fi
run script/focused_validation_plan_tests.sh
run script/focused_test_targets_tests.sh
if [[ "$ROOT_VALIDATION_REQUIRED" == "1" ]] && ((${#changed_files[@]} > 0)); then
  run_focused_targets_for_changed_paths "${changed_files[@]}"
fi
check_whitespace
