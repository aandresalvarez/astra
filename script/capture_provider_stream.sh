#!/usr/bin/env bash
# Capture one provider CLI's real stdout stream as a redacted test fixture.
#
#   script/capture_provider_stream.sh <provider> <scenario> [--keep-raw DIR]
#
# providers: claude copilot codex antigravity cursor
# scenarios: answer-write-signoff   (every provider)
#            subagent               (claude only)
#
# The CLI runs with ASTRA's stream-format flags, in a fresh scratch workspace
# that holds only question.txt, under that provider's most restrictive mode that
# still allows writing inside the workspace. The prompt is fixed and harmless,
# but the run is real: it uses your provider login and quota. Run it by hand,
# never in CI, and review the fixture before committing it.
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
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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
  subagent)
    [[ "$provider" == "claude" ]] || { echo "subagent is a claude-only scenario" >&2; exit 64; }
    prompt='Use the Task tool to start one subagent that reads question.txt in the current directory and returns a one-sentence summary of it. When it returns, tell me that summary in one short paragraph.'
    ;;
  *) usage ;;
esac

workspace="$(mktemp -d "${TMPDIR:-/tmp}/astra-capture.XXXXXX")"
cleanup() { [[ -n "$keep_raw" ]] || rm -rf "$workspace"; }
trap cleanup EXIT
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
    cmd=(agy --print "$prompt" --output-format stream-json --print-timeout "${TIMEOUT_SECONDS}s" --sandbox
         ${model_args[@]+"${model_args[@]}"}) ;;
  cursor)
    cmd=(cursor-agent --print --output-format stream-json --trust --workspace "$workspace"
         --sandbox enabled ${model_args[@]+"${model_args[@]}"} "$prompt") ;;
  *) usage ;;
esac

raw="$workspace/stdout.jsonl"
stderr_file="$workspace/stderr.txt"
echo "==> $provider/$scenario in $workspace" >&2
(cd "$workspace" && exec "${cmd[@]}") >"$raw" 2>"$stderr_file" </dev/null &
pid=$!
( sleep "$TIMEOUT_SECONDS"; kill -TERM "$pid" ) 2>/dev/null &
watchdog=$!
status=0
wait "$pid" || status=$?
pkill -P "$watchdog" 2>/dev/null || true
kill "$watchdog" 2>/dev/null || true
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
python3 "$ROOT_DIR/script/redact_provider_stream.py" "$raw" "$workspace" >"$out.tmp"
mv "$out.tmp" "$out"
echo "==> wrote ${out#"$ROOT_DIR/"} ($(wc -l <"$out" | tr -d ' ') lines)" >&2
if [[ -s "$stderr_file" ]]; then
  echo "==> stderr (not saved):" >&2
  tail -5 "$stderr_file" >&2
fi
keep_raw_copy
