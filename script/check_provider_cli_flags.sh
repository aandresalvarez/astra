#!/usr/bin/env bash
# Checks that the permission flags ASTRA passes to each provider CLI still exist
# in the CLIs installed on this machine. A provider that renames or drops a flag
# makes ASTRA's Ask/Auto levels silently stop meaning what the UI says, and no
# unit test can see that, because the tests never run the real CLI.
#
# Local only: it needs the CLIs installed, so it is not part of CI or the hooks.
# A CLI that is not installed is skipped. Exits non-zero if a required flag is
# missing; an optional one (ASTRA only emits it when the CLI advertises it, with
# a fallback otherwise) is reported as a warning.
#
# It checks the binaries on PATH, not the per-runtime executable path stored in
# ASTRA's settings, so after pointing ASTRA at a different install put that
# one first on PATH for the run.
#
# The flags mirror the builders in Astra/Services/Runtime/*CLIRuntime.swift and
# are pinned per level by Tests/AgentPolicyRuntimeMatrixTests.swift. Keep the
# three in step.
set -uo pipefail

failures=0

# check LABEL BINARY "HELP ARGS" FLAG...           (flag must appear in the help text)
# check_optional LABEL BINARY "HELP ARGS" FLAG...  (a missing flag only warns)
check() { check_flags required "$@"; }
check_optional() { check_flags optional "$@"; }

check_flags() {
  local kind="$1" label="$2" bin="$3" help_args="$4"
  shift 4
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'skip     %-10s not installed (%s)\n' "$label" "$bin"
    return
  fi
  local help
  # shellcheck disable=SC2086
  help="$("$bin" $help_args 2>&1 </dev/null)"
  local flag
  for flag in "$@"; do
    # A here-string, not `printf | grep -q`: grep -q exits at the first match, and
    # under pipefail the writer's SIGPIPE would turn a long help into a false miss.
    if grep -qE -- "(^|[^[:alnum:]-])${flag}([^[:alnum:]-]|$)" <<<"$help"; then
      printf 'ok       %-10s %s\n' "$label" "$flag"
    elif [[ "$kind" == optional ]]; then
      printf 'optional %-10s %s (not advertised; ASTRA falls back)\n' "$label" "$flag"
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
check cursor cursor-agent "--help" \
  --force --sandbox --mode
check copilot copilot "--help" --allow-tool
# ASTRA detects each of these independently and only emits the ones advertised.
check_optional copilot copilot "--help" \
  --allow-all --allow-all-tools --allow-all-paths --allow-all-urls \
  --available-tools --excluded-tools --no-ask-user
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
