#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DURATION="${ASTRA_MEMORY_TRACE_DURATION:-3m}"
OUTPUT_DIR="${ASTRA_MEMORY_TRACE_OUTPUT_DIR:-$ROOT_DIR/.artifacts/memory-trace}"
PID="${ASTRA_MEMORY_TRACE_PID:-}"

if [[ -z "$PID" ]]; then
  matches="$(pgrep -f '/ASTRA Dev.app/Contents/MacOS/ASTRA$' || true)"
  if [[ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]]; then
    echo "Launch exactly one ASTRA Dev.app process or set ASTRA_MEMORY_TRACE_PID" >&2
    exit 2
  fi
  PID="$matches"
fi

command_path="$(ps -p "$PID" -o command=)"
if [[ "$command_path" != *"/ASTRA Dev.app/Contents/MacOS/ASTRA"* ]]; then
  echo "Refusing to profile PID $PID because it is not ASTRA Dev.app: $command_path" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
trace="$OUTPUT_DIR/astra-dev-allocations.trace"
summary="$OUTPUT_DIR/summary.md"
rm -rf "$trace"

echo "Recording ASTRA Dev PID $PID for $DURATION"
echo "Perform the documented warm-up and repeated shelf/task workflow now."
xcrun xctrace record \
  --template Allocations \
  --attach "$PID" \
  --time-limit "$DURATION" \
  --no-prompt \
  --output "$trace"

leaks_output="$(leaks --noContent -q "$PID" 2>&1 || true)"
vmmap_output="$(vmmap -summary "$PID" 2>&1 || true)"
leak_summary="$(printf '%s\n' "$leaks_output" | awk '/ leaks for / { print; exit }')"
physical_footprint="$(printf '%s\n' "$vmmap_output" | awk '/Physical footprint:/ { print $3 " " $4; exit }')"

{
  printf '# ASTRA Dev memory trace summary\n\n'
  printf -- '- Git SHA: `%s`\n' "$(git rev-parse HEAD)"
  printf -- '- PID: `%s`\n' "$PID"
  printf -- '- Duration: `%s`\n' "$DURATION"
  printf -- '- Physical footprint after workload: `%s`\n' "${physical_footprint:-unavailable}"
  printf -- '- Leaks result: `%s`\n' "${leak_summary:-no summary returned}"
  printf -- '- Full trace: `astra-dev-allocations.trace`\n'
} >"$summary"

echo "Summary: $summary"
echo "Trace: $trace"
