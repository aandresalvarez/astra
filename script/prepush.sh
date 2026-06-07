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

run swift test --filter ArchitectureFitnessTests
run swift test --filter RuntimeReadinessServiceTests
run swift test --filter WorkspacePersistenceTests
run swift test --filter AgentRuntimeAdapterTests
check_whitespace
