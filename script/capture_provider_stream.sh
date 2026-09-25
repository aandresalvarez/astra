#!/usr/bin/env bash
# Capture one provider CLI's real stdout stream as a redacted test fixture.
#
#   script/capture_provider_stream.sh <provider> <scenario> [--keep-raw DIR]
#
# providers: claude copilot codex antigravity cursor
# scenarios: answer-write-signoff   (every provider)
#            write-file             (every provider; for CLIs such as agy that
#                                    end the turn after a text-only answer)
#            subagent               (claude only)
#
# The CLI runs with ASTRA's stream-format flags, in a fresh scratch workspace
# that holds only question.txt, under that provider's most restrictive mode that
# still allows writing inside the workspace. The prompt is fixed and harmless,
# but the run is real: it uses your provider login and quota. Run it by hand,
# never in CI, and review the fixture before committing it.
#
# The agent can still read anything your macOS user can. The CLI therefore gets
# an allowlisted environment (no session tokens), tool results never reach the
# fixture, and a capture whose tool calls reach outside the workspace or dump
# the environment is refused (set ASTRA_CAPTURE_ALLOW_OUTSIDE_PATHS=1 only after
# reviewing why). That audit is a best-effort filter over tool-call arguments,
# not a sandbox: the allowlisted environment and a human review of the fixture
# are the boundary.
#
# Output: Tests/Fixtures/ProviderStreams/<provider>/<scenario>.jsonl
# Set ASTRA_CAPTURE_REDACT_EMAIL to your account email so it is redacted too.
# Set ASTRA_CAPTURE_MODEL to pick the model; the stream shape does not depend
# on it, so a cheaper model keeps captures inexpensive. The CLI inherits this
# environment, so export AGY_ADC_AUTH=1 for Antigravity's ADC route.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_SECONDS="${ASTRA_CAPTURE_TIMEOUT_SECONDS:-300}"

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

[[ $# -ge 2 ]] || usage
provider="$1"
scenario="$2"
shift 2
keep_raw=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-raw) keep_raw="${2:?--keep-raw needs a directory}"; shift 2 ;;
    *) usage ;;
  esac
done

case "$scenario" in
  answer-write-signoff)
    prompt='You are helping test a transcript recorder. Do these four steps in order, each exactly once.
Step 1. Write one short sentence saying what you will do, then read question.txt in the current directory.
Step 2. Send the full draft reply to me as a chat message. Do not call any tool in this step. Use exactly this shape:
  - one sentence summarizing the answer
  - a line containing only: ## Suggested reply
  - the line "> Hi Dana,", then a line ">", then one quoted paragraph of at least 150 characters, then a line ">", then "> All the best,", then "> Alvaro"
  - a line "Two notes:" followed by two bullet points of at least 100 characters each
  - a markdown table with 2 columns and 2 data rows
Step 3. Only after that chat message, save the same draft to answer.md with your file-writing tool.
Step 4. Send one last short message whose first line is exactly:
ASTRA_EVENT {"v":1,"type":"complete","summary":"Drafted the reply and saved answer.md"}
then a blank line, then one sentence under 60 characters saying the draft is saved.'
    ;;
  write-file)
    prompt='Read question.txt in the current directory, then save a two-sentence reply to Dana in answer.md with your file-writing tool. After the file is saved, say in one short sentence that it is saved.'
    ;;
  subagent)
    [[ "$provider" == "claude" ]] || { echo "subagent is a claude-only scenario" >&2; exit 64; }
    prompt='Use the Task tool to start one subagent that reads question.txt in the current directory and returns a one-sentence summary of it. When it returns, tell me that summary in one short paragraph.'
    ;;
  *) usage ;;
esac

workspace="$(mktemp -d "${TMPDIR:-/tmp}/astra-capture.XXXXXX")"
# The raw stream and CLI diagnostics live outside the workspace the agent can
# list, read and write.
capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/astra-capture-logs.XXXXXX")"
pid=""
watchdog=""
# The fixture being redacted and audited, until it is moved into place.
staged=""
# TERM the provider's whole group, give it a bounded grace period, then KILL
# whatever ignored TERM.
# Once the group is gone its id is cleared, so a later cleanup cannot signal
# an unrelated group that reused it.
stop_provider_group() {
  [[ -n "$pid" ]] || return 0
  if kill -TERM -- "-$pid" 2>/dev/null; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 -- "-$pid" 2>/dev/null || break
      sleep 0.3
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  pid=""
}
# The watchdog must not outlive the capture: once the provider group is gone
# its id can be reused, and a late kill would reach an unrelated group.
stop_watchdog() {
  [[ -n "$watchdog" ]] || return 0
  pkill -P "$watchdog" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  watchdog=""
}
# Stop the provider before its workspace disappears, however the script ends.
# --keep-raw copies what it keeps first, so no unredacted original outlives it,
# and a fixture that has not passed the audit never stays in the repository.
cleanup() {
  stop_watchdog
  stop_provider_group
  rm -rf "$workspace" "$capture_dir"
  [[ -z "$staged" ]] || rm -f "$staged"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$workspace/question.txt" <<'EOF'
Dana asks: for the 32,872-day top-coding, did we cap each day offset with
LEAST(offset, 32872), or first work out whether the patient reached age 90?
Please draft a short reply.
EOF

model_args=()
if [[ -n "${ASTRA_CAPTURE_MODEL:-}" ]]; then
  model_args=(--model "$ASTRA_CAPTURE_MODEL")
fi

case "$provider" in
  claude)
    cmd=(claude -p "$prompt" --output-format stream-json --include-partial-messages --verbose
         --permission-mode acceptEdits ${model_args[@]+"${model_args[@]}"}) ;;
  copilot)
    cmd=(copilot --prompt "$prompt" --no-color --log-level error --output-format=json --stream=on
         --no-ask-user --allow-tool write ${model_args[@]+"${model_args[@]}"}) ;;
  codex)
    cmd=(codex exec --json --color never --skip-git-repo-check --sandbox workspace-write
         --cd "$workspace" ${model_args[@]+"${model_args[@]}"} "$prompt") ;;
  antigravity)
    # --add-dir makes the scratch workspace explicit to the model, and agy hides
    # account details only when ASTRA's AGY_CLI_HIDE_ACCOUNT_INFO is set.
    cmd=(env AGY_CLI_HIDE_ACCOUNT_INFO=1 agy --print "$prompt" --output-format stream-json
         --print-timeout "${TIMEOUT_SECONDS}s" --sandbox --mode accept-edits --add-dir "$workspace"
         ${model_args[@]+"${model_args[@]}"}) ;;
  cursor)
    cmd=(cursor-agent --print --output-format stream-json --trust --workspace "$workspace"
         --sandbox enabled ${model_args[@]+"${model_args[@]}"} "$prompt") ;;
  *) usage ;;
esac

raw="$capture_dir/stdout.jsonl"
stderr_file="$capture_dir/stderr.txt"
echo "==> $provider/$scenario in $workspace" >&2
# Only what the CLIs need to find themselves and their logins; everything else
# in this shell (API keys, session tokens) stays out of the agent's reach.
capture_env=(HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH="$PATH"
             SHELL="${SHELL:-/bin/zsh}" TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}"
             TMPDIR="$workspace/.tmp" NO_COLOR=1)
[[ -n "${AGY_ADC_AUTH:-}" ]] && capture_env+=(AGY_ADC_AUTH="$AGY_ADC_AUTH")
mkdir -p "$workspace/.tmp"
# Job control gives the provider its own process group, so the watchdog and
# the cleanup below reach every tool process it spawned, not just the CLI.
set -m
(cd "$workspace" && exec env -i "${capture_env[@]}" "${cmd[@]}") >"$raw" 2>"$stderr_file" </dev/null &
pid=$!
set +m
( sleep "$TIMEOUT_SECONDS"; kill -TERM -- "-$pid"; sleep 3; kill -KILL -- "-$pid" ) 2>/dev/null &
watchdog=$!
status=0
wait "$pid" || status=$?
stop_watchdog
# Anything the provider left running must not outlive the capture.
stop_provider_group
echo "==> exit $status, $(wc -l <"$raw" | tr -d ' ') stdout lines" >&2

keep_raw_copy() {
  [[ -n "$keep_raw" ]] || return 0
  mkdir -p "$keep_raw"
  cp "$raw" "$keep_raw/$provider-$scenario.raw.jsonl"
  cp "$stderr_file" "$keep_raw/$provider-$scenario.stderr.txt"
  cp -R "$workspace" "$keep_raw/$provider-$scenario.workspace"
}

# A failed, killed or silent run must not replace the committed fixture.
if [[ "$status" -ne 0 || ! -s "$raw" ]]; then
  echo "==> capture failed; fixture left unchanged. stderr (not saved):" >&2
  tail -5 "$stderr_file" >&2
  keep_raw_copy
  exit "$(( status == 0 ? 1 : status ))"
fi

out_dir="$ROOT_DIR/Tests/Fixtures/ProviderStreams/$provider"
mkdir -p "$out_dir"
out="$out_dir/$scenario.jsonl"
staged="$out.tmp"
if ! python3 "$ROOT_DIR/script/redact_provider_stream.py" "$raw" "$workspace" >"$out.tmp"; then
  echo "==> redaction refused the capture; fixture not written" >&2
  rm -f "$out.tmp"
  keep_raw_copy
  exit 4
fi
audit_status=0
findings="$(python3 "$ROOT_DIR/script/redact_provider_stream.py" --audit "$out.tmp")" || audit_status=$?
# Exit 3 is the audit's outside-path findings, which an owner may accept after
# reviewing them. Any other failure (a frame the audit cannot read, a crash)
# means the fixture was never audited, and is always refused.
if [[ "$audit_status" -eq 3 && "${ASTRA_CAPTURE_ALLOW_OUTSIDE_PATHS:-}" == 1 ]]; then
  echo "==> outside-path findings accepted by ASTRA_CAPTURE_ALLOW_OUTSIDE_PATHS=1:" >&2
  echo "$findings" >&2
elif [[ "$audit_status" -ne 0 ]]; then
  if [[ "$audit_status" -eq 3 ]]; then
    echo "==> tool calls reached outside the workspace; fixture not written:" >&2
  else
    echo "==> the audit could not check the capture (exit $audit_status); fixture not written:" >&2
  fi
  echo "$findings" >&2
  rm -f "$out.tmp"
  keep_raw_copy
  exit 3
fi
mv "$out.tmp" "$out"
staged=""
echo "==> wrote ${out#"$ROOT_DIR/"} ($(wc -l <"$out" | tr -d ' ') lines)" >&2
if [[ -s "$stderr_file" ]]; then
  echo "==> stderr (not saved):" >&2
  tail -5 "$stderr_file" >&2
fi
keep_raw_copy
