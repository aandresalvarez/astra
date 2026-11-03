# Bounded live chat history — November 3, 2026

The transcript's presentation window now rolls while a task stays selected.
Automatically retained history is limited to 300 event rows and 12 runs, plus
the latest state anchors for those runs and runless state. Explicit earlier-page
navigation can retain more history. Durable events, run output, provider context,
and recovery evidence are not truncated.

## Ownership and refresh paths

`AgentEventRecordingState` inserts events or coalesces stream chunks into an
existing event. `TaskThreadChangeObserver` requests a paced refresh through
`TaskThreadViewModel`. The view model flushes unsaved changes without exporting
the workspace; `TaskThreadHistoryStore` reads a fresh background context and
returns value snapshots.

Previously, `applyTailPage` accumulated every new event and run. Its backward
cursor stayed at the original boundary. A full-read fallback merged another
latest page, and invalidation could widen a replacement to the entire accumulated
count. `storageBackedInput` then projected that growing dictionary into a
snapshot. `TaskMainView.conversationItemsList` eagerly rendered every conversation
item in its `VStack`.

Tail application now evicts the oldest automatic event/run rows, removes anchors
for evicted runs, and moves the earlier-page cursor to the retained boundary.
Overflow, backdated insertion, deletion and explicit invalidation replace the
live window with a bounded latest page. Publication request/receipt anchors join
the existing plan, permission and runtime state anchors so eviction cannot hide
a publication decision or resurrect a resolved request.

Scrolling away from the bottom or loading an earlier page pins the retained
event identities. Refreshes re-read those identities, including mutations and
deletions, and fetch the latest run page and state anchors. New conversation rows
wait behind **New activity**; they cannot push out the reader's messages. Explicit
paging preserves the existing item anchor and walks the original older cursor.
**Jump to latest**, returning to the bottom, or sending a new message returns to
the bounded live window. Task reset clears the browsing mode. Read and snapshot
generations reject results captured before a mode change or earlier-page merge.
If a read is ahead of the rendered snapshot when browsing starts, its displayed
rows are pinned too, adding at most one bounded page. Browsed snapshots cannot
populate the default terminal snapshot cache.

The eager `VStack` remains in place because of the documented selectable-text
lazy-stack layout livelock. No production app or user store was used for testing.

## Isolated allocation probe

`TaskThreadLiveHistoryMeasurementTests.selectedDiskBackedStream` keeps the same
view model and hosting view selected for 600 incremental refreshes. Each refresh
adds ten separately persisted synthetic messages, for 6,000 events. A single
running task/run remains active. The hosted eager stack renders every
`conversationItems` entry with selectable text. It exercises the real store,
reader, view model and snapshot pipeline, with no workspace export or provider.

The before run used `37aca81f8b5ea7df61658582ea9ca363b3e0fec7` plus the same new
measurement test file. Its SHA-256 is
`6b4636c92295423bd4ebfff40dd19245d3b8a1a414d2d14b120679a5869f1753`.
Both runs use a fresh test process and disposable disk store, a debug build,
Apple Swift 6.4.2, arm64, macOS 26.6.2 (25G83).

| Measurement | Before | After |
| --- | ---: | ---: |
| Stored events at completion | 6,000 | 6,000 |
| Maximum retained snapshot events | 6,000 | 300 |
| Maximum eager conversation rows | 6,002 | 302 |
| Starting physical footprint | 39 MiB | 35 MiB |
| Sampled workload peak | 410 MiB | 64 MiB |
| Footprint after two seconds idle | 410 MiB | 54 MiB |

The two extra rows are the goal and active run. At each 1,000-event checkpoint,
the before footprints were **98, 157, 205, 260, 327, 410 MiB**; after they were
**56, 61, 56, 57, 58, 54 MiB**. The table uses the final-source after run; an earlier after run measured
67 MiB peak and 58 MiB idle with the same 300-event/302-row bound. These are
sequential runs on a shared developer machine, not a statistical performance
claim. Test execution took 241.719 seconds before and 74.520 seconds in the final
after run, excluding compilation;
there is no timing gate.

Run with the repository wrapper:

```bash
ASTRA_MEASURE_LIVE_HISTORY=1 script/swift_test.sh --no-parallel \
  --filter TaskThreadLiveHistoryMeasurementTests
```

Physical footprint is read from `TASK_VM_INFO.phys_footprint` after each batch;
the reported peak is the maximum of those samples, not the kernel lifetime peak.
Post-idle is sampled after two seconds with the transcript still hosted. Values
are whole MiB. This includes the test process, SwiftData writer and all persisted
synthetic models. The renderer uses selectable text rather than the full
`TaskMainView` bubbles, markdown and decision dock. It isolates a transcript
workload; it does not predict the production app's total footprint or export
peaks. There is no memory or timing threshold in CI.

## Regression coverage

`TaskThreadLiveHistoryTests` covers thousands of disk-backed incremental events,
tail overflow and invalidation, retained event/run/anchor counts, fresh-context
durable counts, older-page reachability, stable displayed identities while
browsing, active run and publication/permission anchors, task switching, terminal
cache isolation, and mode changes during reads and snapshot builds. Existing
history/concurrency tests cover coalescing, timestamp ties, backdated inserts,
deletions, flush failures and earlier-page loading failures. The new suite is
included in focused CI selection; the allocation probe is opt-in.

The focused history/recovery run passed **62 tests in seven suites**. The matching
allocation probe passed on both revisions, including its durable 6,000-event
count assertion. Whitespace and focused-test routing checks passed.

All Dev products compiled through `ASTRA_CHANNEL=dev ./script/build_and_run.sh
bundle`. Bundle staging/verification was blocked by the script's shared-identity
guard because an ASTRA Dev app from another checkout was running. It was left
open; no takeover override was used. The hosted synthetic renderer was exercised
without launching either ASTRA app.
