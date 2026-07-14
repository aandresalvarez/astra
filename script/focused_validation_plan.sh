#!/usr/bin/env bash
set -euo pipefail

if (($# == 0)); then
  printf 'root\n'
  exit 0
fi

needs_git_contracts=0
needs_root=0

for path in "$@"; do
  case "$path" in
    ASTRAGitContracts/*)
      needs_git_contracts=1
      ;;
    Tests/ArchitectureFitnessTests/*)
      # Architecture fitness always runs through its independent package.
      ;;
    Package.swift|script/test_git_contracts.sh)
      needs_git_contracts=1
      needs_root=1
      ;;
    *)
      needs_root=1
      ;;
  esac
done

if [[ "$needs_git_contracts" == "1" ]]; then
  printf 'git-contracts\n'
fi
if [[ "$needs_root" == "1" ]]; then
  printf 'root\n'
fi
