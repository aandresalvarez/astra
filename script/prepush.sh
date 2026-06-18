#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

check_whitespace() {
  local range

  if range="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    && git merge-base "$range" HEAD >/dev/null; then
    run git diff --no-ext-diff --check "${range}...HEAD"
  elif git rev-parse --verify --quiet origin/main >/dev/null \
    && git merge-base origin/main HEAD >/dev/null; then
    run git diff --no-ext-diff --check origin/main...HEAD
  else
    run git diff-tree --check --no-commit-id --root -r HEAD
  fi
}

FOCUSED_SWIFT_TEST_FILTER="ArchitectureFitnessTests|RuntimeReadinessServiceTests|WorkspacePersistenceTests|AgentRuntimeAdapterTests|TaskContextStateTests|CapsuleSnapshotTests|CapsuleSelectionPressureTests|ExecutionSandboxTests|RuntimePolicyGuardTests|CopilotCLICommandPlanningTests|TaskCapabilityResolverTests|RunPermissionManifestTests"

run swift test --filter "$FOCUSED_SWIFT_TEST_FILTER"
check_whitespace
