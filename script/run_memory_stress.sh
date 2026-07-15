#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUNS="${ASTRA_MEMORY_STRESS_RUNS:-3}"
OUTPUT_DIR="${ASTRA_MEMORY_STRESS_OUTPUT_DIR:-$ROOT_DIR/.artifacts/memory-stress}"
FILTER="${ASTRA_MEMORY_STRESS_FILTER:-UIStress|MemoryLifecycleTests}"

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ASTRA_MEMORY_STRESS_RUNS must be a positive integer" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
summary="$OUTPUT_DIR/summary.json"
rss_values=()
footprint_values=()

write_failure_summary() {
  local failed_run="$1"
  local reason="$2"
  local git_sha
  git_sha="$(git rev-parse HEAD)"

  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "status": "failed",\n'
    printf '  "git_sha": "%s",\n' "$git_sha"
    printf '  "requested_run_count": %s,\n' "$RUNS"
    printf '  "completed_run_count": %s,\n' "${#rss_values[@]}"
    printf '  "failed_run": %s,\n' "$failed_run"
    printf '  "failure_reason": "%s",\n' "$reason"
    printf '  "filter": "%s"\n' "$FILTER"
    printf '}\n'
  } >"$summary"
}

for run in $(seq 1 "$RUNS"); do
  log="$OUTPUT_DIR/run-$run.log"
  timing="$OUTPUT_DIR/run-$run.time"
  echo "Memory stress run $run/$RUNS"
  if ! RUN_UI_STRESS=1 /usr/bin/time -lp \
    swift test --no-parallel --filter "$FILTER" >"$log" 2>"$timing"; then
    write_failure_summary "$run" "test_failure"
    cat "$log"
    cat "$timing" >&2
    exit 1
  fi
  rss="$(awk '/maximum resident set size/ { print $1; exit }' "$timing")"
  footprint="$(awk '/peak memory footprint/ { print $1; exit }' "$timing")"
  if [[ -z "$rss" || -z "$footprint" ]]; then
    write_failure_summary "$run" "metric_parse_failure"
    echo "Unable to parse macOS time metrics for run $run" >&2
    exit 1
  fi
  rss_values+=("$rss")
  footprint_values+=("$footprint")
done

sorted_rss="$(printf '%s\n' "${rss_values[@]}" | sort -n)"
sorted_footprint="$(printf '%s\n' "${footprint_values[@]}" | sort -n)"
median_line=$(((RUNS + 1) / 2))
median_rss="$(printf '%s\n' "$sorted_rss" | sed -n "${median_line}p")"
median_footprint="$(printf '%s\n' "$sorted_footprint" | sed -n "${median_line}p")"
max_rss="$(printf '%s\n' "$sorted_rss" | tail -n 1)"
max_footprint="$(printf '%s\n' "$sorted_footprint" | tail -n 1)"
git_sha="$(git rev-parse HEAD)"

{
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "status": "passed",\n'
  printf '  "git_sha": "%s",\n' "$git_sha"
  printf '  "run_count": %s,\n' "$RUNS"
  printf '  "filter": "%s",\n' "$FILTER"
  printf '  "maximum_resident_set_size_bytes": [%s],\n' "$(IFS=,; echo "${rss_values[*]}")"
  printf '  "peak_memory_footprint_bytes": [%s],\n' "$(IFS=,; echo "${footprint_values[*]}")"
  printf '  "median_maximum_resident_set_size_bytes": %s,\n' "$median_rss"
  printf '  "maximum_maximum_resident_set_size_bytes": %s,\n' "$max_rss"
  printf '  "median_peak_memory_footprint_bytes": %s,\n' "$median_footprint"
  printf '  "maximum_peak_memory_footprint_bytes": %s\n' "$max_footprint"
  printf '}\n'
} >"$summary"

echo "Memory stress summary: $summary"
cat "$summary"
