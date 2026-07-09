#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNTIME_SECURITY_STAGES=(
  connector_preflight
  launch_resources
  sandbox_settings_kernel
  sandbox_runner
  policy_manifests
  permission_actions
  denial_diagnostics
)

stage_label() {
  case "$1" in
    connector_preflight) printf 'Connector preflight\n' ;;
    launch_resources) printf 'Launch resources\n' ;;
    sandbox_settings_kernel) printf 'Sandbox settings + kernel\n' ;;
    sandbox_runner) printf 'Sandbox runner\n' ;;
    policy_manifests) printf 'Policy manifests\n' ;;
    permission_actions) printf 'Permission actions\n' ;;
    denial_diagnostics) printf 'Denial diagnostics\n' ;;
    *) printf 'Unknown runtime-security stage: %s\n' "$1" >&2; return 1 ;;
  esac
}

stage_suites() {
  case "$1" in
    connector_preflight)
      printf '%s\n' ConnectorPreflightServiceTests
      ;;
    launch_resources)
      printf '%s\n' TaskLaunchResourcePlanTests LaunchResourcePolicyExposureTests
      ;;
    sandbox_settings_kernel)
      printf '%s\n' \
        ExecutionSandboxTests \
        ExecutionSandboxCommandTests \
        ExecutionSandboxDeveloperToolchainTests
      ;;
    sandbox_runner)
      printf '%s\n' ExecutionSandboxRunnerTests
      ;;
    policy_manifests)
      printf '%s\n' RunPermissionManifestTests
      ;;
    permission_actions)
      printf '%s\n' \
        TaskRuntimePermissionActionHandlerTests \
        RuntimePermissionGrantRegressionTests
      ;;
    denial_diagnostics)
      printf '%s\n' RuntimePolicyGuardTests RuntimeSandboxDenialDiagnosticsTests
      ;;
    *)
      printf 'Unknown runtime-security stage: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

all_suites() {
  local stage

  for stage in "${RUNTIME_SECURITY_STAGES[@]}"; do
    stage_suites "$stage"
  done
}

suite_test_count() {
  local listing="$1"
  local suite="$2"
  local count

  count="$(printf '%s\n' "$listing" | grep -c "^ASTRATests\.${suite}/" || true)"
  printf '%s\n' "$count"
}

inventory_test_count() {
  local listing="$1"
  local suite count
  local total=0

  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    count="$(suite_test_count "$listing" "$suite")"
    total=$((total + count))
  done < <(all_suites)

  printf '%s\n' "$total"
}

validate_suite_inventory() {
  local listing="$1"
  local stage suite count stage_count label
  local total=0
  local missing=0

  for stage in "${RUNTIME_SECURITY_STAGES[@]}"; do
    stage_count=0
    while IFS= read -r suite; do
      [[ -n "$suite" ]] || continue
      count="$(suite_test_count "$listing" "$suite")"
      if ((count == 0)); then
        printf 'ERROR: runtime-security suite matched zero tests: %s\n' "$suite" >&2
        missing=1
      fi
      stage_count=$((stage_count + count))
    done < <(stage_suites "$stage")
    label="$(stage_label "$stage")"
    printf '  %-29s %3d tests\n' "$label" "$stage_count"
    total=$((total + stage_count))
  done

  if ((missing != 0 || total == 0)); then
    printf 'ERROR: runtime-security inventory is incomplete; update the suite manifest before running.\n' >&2
    return 1
  fi

  printf '  %-29s %3d tests\n' 'Total' "$total"
}

validate_run_output() {
  local output_file="$1"
  local expected_count="$2"
  local executed_count

  executed_count="$(
    sed -n 's/.*Test run with \([0-9][0-9]*\) tests .*/\1/p' "$output_file" | tail -n 1
  )"
  if [[ -z "$executed_count" || "$executed_count" == "0" ]]; then
    printf 'ERROR: runtime-security filter executed zero tests or emitted no test summary.\n' >&2
    return 1
  fi
  if [[ "$executed_count" != "$expected_count" ]]; then
    printf 'ERROR: runtime-security filter listed %s tests but executed %s.\n' \
      "$expected_count" "$executed_count" >&2
    return 1
  fi
}

test_filter() {
  local suite
  local joined=""

  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    if [[ -n "$joined" ]]; then
      joined="${joined}|${suite}"
    else
      joined="$suite"
    fi
  done < <(all_suites)

  printf '^ASTRATests\.(%s)/\n' "$joined"
}

main() {
  local listing filter expected_count output_file test_status

  cd "$ROOT_DIR"

  printf '==> Inventory\n'
  listing="$(swift test list)"
  validate_suite_inventory "$listing"
  expected_count="$(inventory_test_count "$listing")"

  filter="$(test_filter)"
  printf '\n==> Runtime-security regressions\n'
  output_file="$(mktemp "${TMPDIR:-/tmp}/astra-runtime-security.XXXXXX")"
  set +e
  swift test --no-parallel --filter "$filter" 2>&1 | tee "$output_file"
  test_status="${PIPESTATUS[0]}"
  set -e
  local count_status=0
  validate_run_output "$output_file" "$expected_count" || count_status=$?
  if ((test_status != 0)); then
    printf '\n==> Failure summary\n' >&2
    grep -E 'recorded an issue|Test run with .* failed|error:' "$output_file" | tail -n 40 >&2 || true
  fi
  if ((count_status != 0)); then
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
  return "$test_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
