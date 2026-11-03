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
| Starting physical footprint | 39 MiB | 39 MiB |
| Sampled workload peak | 410 MiB | 64 MiB |
| Footprint after two seconds idle | 410 MiB | 61 MiB |

The two extra rows are the goal and active run. At each 1,000-event checkpoint,
the before footprints were **98, 157, 205, 260, 327, 410 MiB**; after they were
**59, 64, 52, 56, 57, 61 MiB**. The table uses the final-source after run; an earlier after run measured
67 MiB peak and 58 MiB idle with the same 300-event/302-row bound. These are
sequential runs on a shared developer machine, not a statistical performance
claim. Test execution took 241.719 seconds before and 79.553 seconds in the final
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

## Publication decisions outside the visible window

Review of the first draft found that retaining typed publication requests and
receipts did not cover historical publication failures without a typed request.
The disk-backed regression reproduced the dock/durable mismatch for all nine
combinations of durable failure, legacy message evidence, or preceding tool-use
evidence with same-run, runless, or older-run receipts: pending initially in
both paths, lost only by the dock after eviction, cleared by a later receipt.

The background history reader now supplies an additional publication evidence
packet, independently of rendered events. It retains at most six records for
the current run's decision. A valid typed request uses its own-run receipt;
legacy failures also use the latest task-wide receipt, even when its run is
outside the transcript. Valid durable failures and matching legacy failures are
selected in 64-row batches; unrelated failures and malformed payloads cannot
hide older actionable evidence. Legacy command context uses the latest
preceding tool-use record, with the same evidence-matching helper as the durable
resolver. A resolving receipt stops the search at its timestamp.

The packet is refreshed by tail, replacement/invalidation, and retained-window
reads. It participates in the immutable decision signature and dock resolver,
without joining `sortedEvents` or conversation rows. Main-actor refresh consumes
these values; it does not fetch publication history. Additional tests cover
batch boundaries, imported tasks sharing a UUID, Review visibility, and receipt
clearing after the receipt itself leaves the ordinary event page.

The first combined decision/scaling runs passed the functional comparisons but
missed the unchanged send-cost gate (180–189 ms send cost, 174–178 ms bounds).
The isolated scaling rerun passed (166.73 ms send, 174.12 ms bound). Its view
refresh measured 6.38 ms versus a 348.23 ms full-history control at 5,000 events.
No timing threshold was changed; these observations do not establish the cause
of the combined-run send-cost misses.

After the publication-evidence correction, all 75 functional history/decision
checks passed in the 76-test combined run; the remaining issue was the send-cost
gate described above. The isolated scaling check passed. The repeated 6,000-event
allocation probe passed with the same 300 retained events and 302 eager rows,
64 MiB sampled peak and 61 MiB idle.
