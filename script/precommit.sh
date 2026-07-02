#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

changed_paths() {
  git diff --cached --name-only --diff-filter=ACMRTUXB
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

run swift test --filter ArchitectureFitnessTests.ArchitectureFitnessTests
run script/focused_test_targets_tests.sh
changed_files=()
while IFS= read -r path; do
  changed_files+=("$path")
done < <(changed_paths)
if ((${#changed_files[@]} > 0)); then
  run_focused_targets_for_changed_paths "${changed_files[@]}"
fi
run git diff --cached --check
