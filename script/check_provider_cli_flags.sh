#!/usr/bin/env bash
# Checks that the permission flags ASTRA passes to each provider CLI still exist
# in the CLIs installed on this machine. A provider that renames or drops a flag
# makes ASTRA's Ask/Auto levels silently stop meaning what the UI says, and no
# unit test can see that, because the tests never run the real CLI.
#
# Local only: it needs the CLIs installed, so it is not part of CI or the hooks.
# A CLI that is not installed is skipped. Exits non-zero if any flag is missing.
#
# The flags mirror the builders in Astra/Services/Runtime/*CLIRuntime.swift and
# are pinned per level by Tests/AgentPolicyRuntimeMatrixTests.swift. Keep the
# three in step.
set -uo pipefail

failures=0

# check LABEL BINARY "HELP ARGS" FLAG...   (flag must appear in the help text)
check() {
  local label="$1" bin="$2" help_args="$3"
  shift 3
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'skip     %-10s not installed\n' "$label"
    return
  fi
  local help
  # shellcheck disable=SC2086
  help="$("$bin" $help_args 2>&1 </dev/null)"
  local flag
  for flag in "$@"; do
    if printf '%s\n' "$help" | grep -qE -- "(^|[^[:alnum:]-])${flag}([^[:alnum:]-]|$)"; then
      printf 'ok       %-10s %s\n' "$label" "$flag"
    else
      printf 'MISSING  %-10s %s\n' "$label" "$flag"
      failures=$((failures + 1))
    fi
  done
}

check claude claude "--help" \
  --dangerously-skip-permissions --allowedTools --disallowedTools --permission-prompt-tool
check codex codex "exec --help" \
  --sandbox --dangerously-bypass-approvals-and-sandbox -c
check cursor agent "--help" \
  --force --sandbox --mode
check copilot copilot "--help" \
  --allow-all --allow-all-tools --allow-all-paths --allow-all-urls \
  --allow-tool --available-tools --excluded-tools --no-ask-user
check antigravity agy "--help" \
  --sandbox --dangerously-skip-permissions

# OpenCode no longer lists --dangerously-skip-permissions (the documented flag is
# --auto) but still accepts it as a hidden alias. Without a message, a recognised
# flag reaches "You must provide a message"; an unknown one prints usage instead.
# No model is called either way.
if command -v opencode >/dev/null 2>&1; then
  flag=--dangerously-skip-permissions
  probe="$(cd "${TMPDIR:-/tmp}" && opencode run "$flag" 2>&1 </dev/null | head -5)"
  if printf '%s\n' "$probe" | grep -q "You must provide a message"; then
    printf 'ok       %-10s %s (undocumented alias)\n' opencode "$flag"
    if ! opencode run --help 2>&1 </dev/null | grep -qE -- '--auto'; then
      printf 'WARN     %-10s --auto is no longer documented either\n' opencode
    fi
  else
    printf 'MISSING  %-10s %s (rejected; the documented replacement is --auto)\n' opencode "$flag"
    failures=$((failures + 1))
  fi
else
  printf 'skip     %-10s not installed\n' opencode
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\n%d flag(s) ASTRA relies on are gone from the installed CLIs.\n' "$failures" >&2
  exit 1
fi
printf '\nAll checked flags are still accepted.\n'
