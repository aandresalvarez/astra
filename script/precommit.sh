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

changed_files=()
while IFS= read -r path; do
  changed_files+=("$path")
done < <(changed_paths)

run script/test_architecture.sh
if ((${#changed_files[@]} > 0)); then
  validation_plan="$(script/focused_validation_plan.sh "${changed_files[@]}")"
  while IFS= read -r lane; do
    if [[ "$lane" == "git-contracts" ]]; then
      run script/test_git_contracts.sh
    fi
  done <<< "$validation_plan"
fi
run script/focused_validation_plan_tests.sh
run script/focused_test_targets_tests.sh
if ((${#changed_files[@]} > 0)); then
  run_focused_targets_for_changed_paths "${changed_files[@]}"
fi
run git diff --cached --check
