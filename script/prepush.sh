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

FOCUSED_SWIFT_TEST_FILTER="ArchitectureFitnessTests|RuntimeReadinessServiceTests|WorkspacePersistenceTests|AgentRuntimeAdapterTests|TaskContextStateTests|CapsuleSnapshotTests|CapsuleSelectionPressureTests|ExecutionSandboxTests|RuntimePolicyGuardTests|CopilotCLICommandPlanningTests|TaskCapabilityResolverTests|RunPermissionManifestTests"

run swift test --filter "$FOCUSED_SWIFT_TEST_FILTER"
changed_files=()
while IFS= read -r path; do
  changed_files+=("$path")
done < <(changed_paths)
run_focused_targets_for_changed_paths "${changed_files[@]}"
check_whitespace
