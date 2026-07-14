#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

assert_plan() {
  local expected="$1"
  shift

  local actual
  actual="$(script/focused_validation_plan.sh "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected validation plan:\n%s\nActual validation plan:\n%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

assert_plan "root"

assert_plan "git-contracts" \
  "ASTRAGitContracts/Tests/ASTRAGitContractsTests/GitStatusParserContractTests.swift"

assert_plan $'git-contracts\nroot' \
  "ASTRAGitContracts/Sources/ASTRAGitContracts/GitStatusContracts.swift"

assert_plan $'git-contracts\nroot' \
  "ASTRAGitContracts/Package.swift"

assert_plan "" \
  "Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift" \
  "Tests/ArchitectureFitnessTests/Package.swift"

assert_plan "root" \
  "Astra/Services/Git/GitService.swift"

assert_plan $'git-contracts\nroot' \
  "ASTRAGitContracts/Tests/ASTRAGitContractsTests/GitStatusParserContractTests.swift" \
  "Astra/Services/Git/GitService.swift"

assert_plan $'git-contracts\nroot' \
  "Package.swift"
