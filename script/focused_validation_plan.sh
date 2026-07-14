#!/usr/bin/env bash
set -euo pipefail

if (($# == 0)); then
  printf 'root\n'
  exit 0
fi

needs_git_contracts=0
needs_root=0

if [[ "${ASTRA_RELEASE_GATE:-0}" == "1" ]]; then
  # Release signing must always run the root release-number, update, and app
  # packaging gates regardless of which paths changed since main.
  needs_root=1
fi

for path in "$@"; do
  case "$path" in
    ASTRAGitContracts/Tests/*)
      needs_git_contracts=1
      ;;
    ASTRAGitContracts/*)
      # Production contract or package changes must also compile the ASTRA
      # consumer so API drift cannot pass the isolated package lane alone.
      needs_git_contracts=1
      needs_root=1
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
