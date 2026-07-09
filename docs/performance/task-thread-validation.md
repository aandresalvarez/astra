# Task Thread Performance Validation

Use the development channel only for this check. Never copy a user's production
conversation into development; reproduce its scale with the deterministic test
fixture or a redacted task instead.

## What ASTRA records

Selecting an existing task creates one correlated responsiveness trace. The
existing **Logs** window exposes it under the `Performance` category and the
same sanitized lines are included in Download bundle and diagnostic reports.

Completed measurements are always visible at `INFO` (or `WARNING` at 250 ms or
above):

```text
event=task_selection_to_shell_visible duration_ms=<value>
event=task_selection_to_transcript_ready duration_ms=<value>
event=screen_transition_to_interactive destination=task duration_ms=<value>
```

Slow task-open phases appear at `DEBUG` from 8 ms and `WARNING` from 50 ms:

```text
event=task_open_phase phase=mark_task_read_persistence
event=task_open_phase phase=task_initialization
event=task_open_phase phase=thread_reset
event=task_open_phase phase=context_state_refresh
```

Every line includes only safe correlation and scale fields: abbreviated task and
workspace IDs, trace ID, task status, read/unread state, run/event count
buckets, window omission counts, snapshot cache state, cache-derived snapshot counts, and output-size
buckets. It must never include a title, prompt, output, path, or secret.

The same two end-to-end intervals are emitted as `OSSignposter` signposts for
Instruments. Signposts show the precise interval in a timeline; Logs provide
the durable, shareable result without requiring an Instruments capture.

## Reproduction matrix

Record each case at least three times and compare p50/p95—not a single lucky
run—on the same Mac and build.

| Case | Why it matters |
| --- | --- |
| Small task (under 10 runs) | Establishes baseline transition overhead. |
| Long task (50+ runs, 500+ events) | Exercises the normal progressive thread window. |
| Large deterministic history (250 runs, 5,000 events) | Protects the bounded initial transcript contract. |
| First open of an unread task | Includes mark-read persistence. |
| Reopen of the same read task | Separates persistence cost from thread/screen work. |
| Running task while output streams | Checks snapshot cadence, scroll behavior, and hitches. |

## Instruments procedure

1. Build and open `ASTRA Dev.app`.
2. Open Instruments and choose the **SwiftUI** template. Keep the SwiftUI,
   Time Profiler, Hangs/Hitches, and `os_signposts` tracks enabled.
3. Select the target task, wait for the transcript, scroll it, switch Chat and
   Files, then select a different task and return.
4. In the `os_signposts` track, inspect
   `task_selection_to_shell_visible` and
   `task_selection_to_transcript_ready`.
5. For a slow interval, use Time Profiler plus the SwiftUI update lanes to
   determine whether the time is main-actor persistence, snapshot preparation,
   Markdown/layout, or unrelated CPU work.

## Expected shape

- `TaskThreadSnapshot.init` runs when task events or runs change, not once per rendered bubble.
- `TaskGeneratedFiles.filesAsync` does folder enumeration off the main actor and only refreshes when the task folder or latest-run file-change state changes.
- `SidebarTaskIndex.init` replaces repeated per-workspace scans during sidebar rendering.
- `MarkdownLinkifier.markdownAttributed` should appear less often on repeated renders because rendered blocks share a bounded attributed-string cache.
- Startup store-scale telemetry records counts only; it does not fetch all runs
  and events on the main actor just to produce detailed diagnostics.

## Local checks

```bash
swift test --filter PerformanceTelemetryTests
swift test --filter TaskOpenResponsivenessTelemetryTests
swift test --filter TaskThreadViewModelTests
swift test --filter TaskThreadSnapshotTests
./script/build_and_run.sh --verify
git diff --check
```
