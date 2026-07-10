#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source script/runtime_security_tests.sh

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

listing=""
while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  listing="${listing}ASTRATests.${suite}/fixture()"$'\n'
done < <(all_suites)

validate_suite_inventory "$listing" >/dev/null \
  || fail 'complete suite inventory should pass'

missing_listing="$(printf '%s' "$listing" | grep -v '^ASTRATests\.RuntimePolicyGuardTests/')"
if validate_suite_inventory "$missing_listing" >/dev/null 2>&1; then
  fail 'missing suite should fail inventory validation'
fi

renamed_listing="${missing_listing}ASTRATests.RuntimePolicyGuardTestsRenamed/fixture()"$'\n'
if validate_suite_inventory "$renamed_listing" >/dev/null 2>&1; then
  fail 'similarly named suite should not satisfy an exact inventory match'
fi

expected_filter="^ASTRATests\.($(all_suites | paste -sd '|' -))/"
actual_filter="$(test_filter)"
[[ "$actual_filter" == "$expected_filter" ]] \
  || fail "unexpected test filter: $actual_filter"

summary_file="$(mktemp "${TMPDIR:-/tmp}/astra-runtime-security-test.XXXXXX")"
trap 'rm -f "$summary_file"' EXIT
printf 'Test run with 11 tests in 7 suites passed after 0.100 seconds.\n' >"$summary_file"
validate_run_output "$summary_file" 11 \
  || fail 'matching nonzero execution summary should pass'

printf 'Test run with 0 tests in 0 suites passed after 0.001 seconds.\n' >"$summary_file"
if validate_run_output "$summary_file" 11 >/dev/null 2>&1; then
  fail 'zero-test execution summary should fail'
fi

printf 'Test run with 10 tests in 7 suites passed after 0.100 seconds.\n' >"$summary_file"
if validate_run_output "$summary_file" 11 >/dev/null 2>&1; then
  fail 'listed and executed test count drift should fail'
fi

printf 'runtime_security_tests_tests: PASS (7 checks)\n'
