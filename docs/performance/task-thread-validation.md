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
event=screen_transition_to_view_ready destination=task duration_ms=<value>
event=screen_transition_to_view_ready destination=shelf_markdown duration_ms=<value>
```

Slow task-open phases appear at `DEBUG` from 8 ms and `WARNING` from 50 ms:

```text
event=task_open_phase phase=mark_task_read_persistence
event=task_open_phase phase=task_initialization
event=task_open_phase phase=thread_reset
event=task_open_phase phase=context_state_refresh
event=task_open_snapshot_input_capture
event=task_open_snapshot_queue_wait
event=task_open_snapshot_apply_hop
event=task_open_snapshot_apply
event=task_open_snapshot_apply_to_transcript_ready
event=thread_history_page_read
event=thread_snapshot_apply_hop
event=chat_stream_snapshot_cadence
event=chat_scroll_recovery
event=task_selection_timeout
```

Every line includes only safe correlation and scale fields: abbreviated task and
workspace IDs, trace ID, task status, read/unread state, run/event count
buckets, window omission counts, snapshot cache state, cache-derived snapshot counts, and output-size
buckets. Task-open results additionally include bounded main-actor probe-gap and
hitch summaries plus visible transcript size / Markdown-shape buckets. It must
never include a title, prompt, output, path, or secret.

### Reading a slow `chat_stream_snapshot_cadence` sample

Each cadence line carries its own decomposition, so a slow sample does not need
a second run to explain: `build_ms` is the snapshot build, `apply_hop_ms` is the
gap between the executor finishing and the main actor applying the result, and
`main_actor_max_stall_ms` / `main_actor_hitch_count` / `main_actor_probe_count`
summarise a 50 ms main-actor probe that runs only while the task streams.
`thread_snapshot_build` additionally reports `cpu_ms` from
`CLOCK_THREAD_CPUTIME_ID`, which separates "the build got more expensive" from
"the build got descheduled".

Read the hitch count before the maximum. Every streamed event enqueues its own
main-actor continuation, so a burst delays the probe and the apply together:
**many hitches with a modest maximum means main-actor queue depth**, and the fix
is scheduling, not the work itself. **One hitch with a large maximum means a
single synchronous call blocked the thread**, and the fix is to move that call
off the main actor. `main_actor_max_stall_ms` alone cannot tell those apart.

### Reading the live pacing fields

While a task streams, `TaskThreadLiveSnapshotPacer` holds the next transcript
update until the measured main-actor cost of the previous one is at most half of
the elapsed period. The cadence line carries the whole control state:

| Field | Meaning |
| --- | --- |
| `pace_render_ms` | Main-actor time the previous period actually spent on the transcript: the synchronous apply plus every probe overshoot after it, which is what makes the SwiftUI layout pass visible for the first time. |
| `pace_period_ms` | Wall time between the last two live applies. |
| `pace_duty` | `pace_render_ms / pace_period_ms`. The controller drives this towards 0.50. |
| `pace_target_ms` | The admission period the controller most recently computed, `pace_render_ms / 0.5`, clamped to 2000. |
| `throttle_delay_ms` | Delay this pacer actually inserted during the window. Same field name as before, but it used to be structurally pinned at `0.00`; a non-zero value now means real back-pressure. |
| `deferred_snapshot_count` | Updates held during the window, for the same reason. |
| `pace_reconcile_count` | Re-arms inside one window. Persistently above ~2 means the main actor is busy with work the transcript did not cause. |
| `pace_state` | `unpaced` (no live apply measured yet, or disarmed by a terminal transition), `debounce` (deadline already passed; the 120 ms coalescing floor is binding), `duty` (the measured duty cycle is holding the update), `ceiling` (the deadline was clamped at 2 s). |

`pace_state=ceiling` is the sample worth chasing. It means observed occupancy
asked for a period longer than 2 s, which the transcript alone cannot account
for — look for another main-actor producer rather than tuning the pacer. The
clamp is also the reason the loop cannot wedge: admission at
`lastApplyAt + 2 s` is independent of the measurement, so the worst case is a
transcript refreshing at 0.5 Hz, never one that stops.

`pace_render_ms ≈ 0` with a large `pace_period_ms` means the pacer is inactive
and the cadence is whatever the debounce and the build cost produce — the
unchanged pre-existing behaviour for cheap threads.

If an open remains incomplete for five seconds while its view is still alive,
`task_selection_timeout` records the elapsed time and whether the shell and
transcript stages were reached before closing the trace. This makes a stuck
open distinguishable from an intentional rapid task switch.

`task_selection_to_shell_visible` means the destination shell has entered the
SwiftUI update path; it is not labeled as a frame-presented or input-handled
measurement. `screen_transition_to_view_ready` uses the same explicit
semantics for Chat ↔ Shelf transitions. Use the main-actor probe summary and
Instruments' Hangs/Hitches track to determine whether the view subsequently
stalled.

## Diagnostic report summary

The existing **Diagnostic Reports** action now includes a **UI Responsiveness**
section. It calculates nearest-rank p50, p95, maximum, warning count, and
cache-state cohorts for completed responsiveness events in the selected log
window. It also lists the five slowest correlated traces with their named
phases. This is the first support artifact to inspect before opening
Instruments.

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
| Running task while output streams | Checks sampled snapshot cadence, scroll behavior, and hitches. |
| Chat ↔ Plan/Browser/Markdown/Query | Checks generic major-screen transition latency. |

## Instruments procedure

1. Build and open `ASTRA Dev.app`.
2. Open Instruments and choose the **SwiftUI** template. Keep the SwiftUI,
   Time Profiler, Hangs/Hitches, and `os_signposts` tracks enabled.
3. Select the target task, wait for the transcript, scroll it, switch Chat and
   Files, then select a different task and return.
4. In the `os_signposts` track, inspect
   `task_selection_to_shell_visible` and
   `task_selection_to_transcript_ready`, plus
   `screen_transition_to_view_ready` for shelf switches.
5. For a slow interval, use Time Profiler plus the SwiftUI update lanes to
   determine whether the time is main-actor persistence, snapshot preparation,
   Markdown/layout, or unrelated CPU work.

## Expected shape

- Initial and previous transcript history is fetched through bounded SwiftData
  pages before `TaskThreadSnapshot.init`; `thread_history_page_read` records the
  page and total counts without message content.
- Live task invalidations coalesce before the bounded database read and snapshot
  build. They do not poll or scan the complete event relationship.
- Plan-state UI reads only plan mutation rows plus runs containing persisted
  protocol markers; ordinary conversation messages and runs are not faulted
  through SwiftData relationships.
- `TaskGeneratedFiles.filesAsync` does folder enumeration off the main actor and only refreshes when the task folder or latest-run file-change state changes.
- `SidebarTaskIndex.init` replaces repeated per-workspace scans during sidebar rendering.
- `MarkdownLinkifier.markdownAttributed` should appear less often on repeated renders because rendered blocks share a bounded attributed-string cache.
- Startup store-scale telemetry records counts only; it does not fetch all runs
  and events on the main actor just to produce detailed diagnostics.

## Local checks

```bash
swift test --filter PerformanceTelemetryTests
swift test --filter TaskOpenResponsivenessTelemetryTests
swift test --filter UIResponsivenessDiagnosticsTests
swift test --filter ScreenTransitionTelemetryTests
swift test --filter TaskThreadViewModelTests
swift test --filter TaskThreadSnapshotTests
swift test --filter TaskThreadSnapshotBackpressureTests
swift test --filter TaskThreadLiveSnapshotPacerTests
swift test --filter TaskThreadMainActorStallSamplerTests
swift test --filter TaskThreadHistoryReaderTests
swift test --filter TaskPlanServiceTests
./script/build_and_run.sh --verify
git diff --check
```
