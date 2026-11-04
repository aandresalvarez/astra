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
| Starting physical footprint | 39 MiB | 38 MiB |
| Sampled workload peak | 410 MiB | 65 MiB |
| Footprint after two seconds idle | 410 MiB | 59 MiB |

The two extra rows are the goal and active run. At each 1,000-event checkpoint,
the before footprints were **98, 157, 205, 260, 327, 410 MiB**; after they were
**58, 63, 58, 58, 62, 59 MiB**. The table uses the final-source after run; earlier after runs measured
64–71 MiB peak and 54–66 MiB idle with the same 300-event/302-row bound. These are
sequential runs on a shared developer machine, not a statistical performance
claim. Test execution took 241.719 seconds before and 75.632 seconds in the final
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

## Avoiding repeated legacy searches

A second review replay showed that scanning unrelated failures on every tail
read was expensive even for tasks without PR intent. Legacy evidence is now
intent-gated. Valid typed requests are checked first and remain authoritative
when task wording is edited.

The history store owns one bounded derived cache entry. It checks relevant
persisted counts/latest records, selected evidence, scope/run identity and the
explicit history-invalidation generation. Save-boundary observers invalidate
existing publication/tool-evidence edits and deletions at both `willSave` and
`didSave`. The revision is captured before the page's first query, so a read
overlapping a commit cannot cache old evidence under a post-commit revision.
Only pending changes are inspected on their context's saving thread. Locked
value state and weak context identities connect the two boundaries; models
and contexts are not retained. A later save attempt replaces an abandoned
scope, and an unmatched `didSave` invalidates conservatively. Readers never
wait for a completion notification, including after failed saves.
The observers do not change domain state or treat ordinary message/response
changes as publication edits. Inserts/backdating are detected
by the persisted signature. The observers are removed with the store. Tool uses
after the newest failure do not invalidate the evidence signature.

Deterministic tests with 1,500 unrelated failures verify zero legacy scans or
preceding-use lookups for non-PR tasks. For PR-intent tasks, twelve ordinary
appends (including a later tool use) add zero scans/lookups after priming and
hit the cache. An older unselected failure edit and an explicit invalidation
both force a rescan. Typed requests still win after PR wording is removed.
The commit-boundary regression holds a disposable SQLite writer slot while a
second context edits an older unselected failure. A read after `willSave` sees
the old committed evidence; after the real save commits, the cached read agrees
with both the uncached read and durable resolver. An aborted notification scope
and its superseding ordinary save also preserve read progress and cache hits.
The 78-test focused history/decision/work/commit run passed in eleven suites.
The final 6,000-event allocation replay also passed after this correction; its
measurements are the after column above.

The opt-in `TaskPublicationTailReplayTests` mirrors the review fixture with fresh
read contexts. Non-PR reads at 100/750/1,500 failures measured
1.55–2.16 / 1.94–2.26 / 2.20–2.77 ms (three reads each). The review's
`bcef2f5e` observations were about 22–29 / 187–203 / 441–473 ms. A PR-intent
store performed its initial 1,500-row search in 511.25 ms; the next two reads
were 4.27 and 4.08 ms with the scan/lookup counts unchanged at 1,500.
These are observations, with no wall-clock CI threshold. Run with:

```bash
ASTRA_MEASURE_PUBLICATION_TAIL=1 script/swift_test.sh --no-parallel \
  --filter TaskPublicationTailReplayTests
```

## Cached and final view state

An applied terminal cache hit seeds the browsing cursor and baseline totals
from that snapshot. The first retained/earlier read restores run inputs and
evidence before building a replacement. The placeholder never supplies this baseline. Pausing
pins the displayed identities and queues a retained-window replacement; it
cannot discard the final build and wait for another event that may never come.
Explicit earlier paging owns its own replacement and scroll anchor.

An owner-scoped save observation requests a paced history refresh after relevant
publication evidence commits, even when task timestamps and counts stay equal.
It also handles inserted failures and receipts without invalidating prior
failure evidence for ordinary new tool uses. Changed publication packet values
participate in snapshot-trigger equality. Relevant commits evict that owner's
terminal cache entries. Each entry retains its owner's save observation while
inactive, and carries the paired-save revision captured before its source read.
Lookup rejects a changed revision synchronously; a late build cannot store a
snapshot under a later revision. Observations are reused for the same owner and
container and released with cache eviction (at most twelve cached entries),
alongside the active view's observation. The observation retains no context or
container. Publication saves do not advance a UUID-wide history token, so
imported owners sharing a portable task UUID cannot invalidate one another.

Disk-backed view-model regressions cover a terminal cache hit followed by 400
new messages while browsing, pausing the final build without an extra refresh,
and saved same-count failure edits in both live and cached terminal tasks. They
compare the real dock resolver to the durable decision and verify that clearing
the failure remains cleared after reopening. Imported-owner paging additionally
checks New activity and Jump to latest across the A-to-B-to-A cancellation race.

Combining that owner suite with the real background commit replay exposed an
existing saved-export observer accepting another context's notification before
assuming MainActor isolation. Both save boundaries now check reference identity;
the view-side save observer does too. The imported schedule fixture settles its
own export in disposable paths so it cannot leave global pending work behind.
The combined 42-test view/commit/owner/export run passed.
The broader pass completed 308 tests in 27 suites plus 14 package tests with no
failures. The final hosted allocation replay also passed with the same bounds.
The final cache-seed extension passed the 23-test view/owner/commit group,
including direct earlier paging with waiting activity. The unchanged isolated
main-actor scaling gate passed: at 5,000 events, send measured 152.84 ms, view
refresh 5.22 ms, and the full-history control 336.36 ms.

The inactive-owner regression warms A, selects B, edits A's evicted failure
without changing its timestamp or event count, and reopens A. Both actionable
and cleared transitions agree with the durable resolver. A separate parameter
case gives A and B the same portable UUID. B remains a cache hit with zero
extra history reads, and B's ordinary append leaves A cached. A weak-reference
test verifies immediate rejection after a save revision changes and observation
release on eviction. The final 25-test focused group and broader 310-test /
27-suite pass succeeded, alongside 14 package tests.

The reader's single evidence-cache entry also scopes its mutation observation
to its current persistent owner, before capturing the read revision. An added
counter regression reproduced 1,501 extra failure scans and tool lookups after a
different owner (with the same portable UUID) was edited. With the scope fixed,
the subsequent ordinary append adds zero scans/lookups; edits to the actual
owner still invalidate normally. The 25-test combined group passed this check.

The latest isolated current-source send gate missed its unchanged bound
(176.32 ms send versus 170.21 ms), after an earlier miss of 191.58 versus
175.89 ms. An isolated checkout of original main
`37aca81f8b5ea7df61658582ea9ca363b3e0fec7`, using the identical scaling-test
file, also failed that gate: 204.76 ms send versus 172.67 ms. The corresponding
current/main view-update costs were 6.10/6.56 ms against full-history controls
of 340.41/345.34 ms. These runs establish that this gate also fails on the
baseline here; they do not establish a cause or a statistical speedup. No
threshold was changed. Functional history/decision/export coverage passed
310 tests in 27 suites plus 14 package tests after the fixture awaited its
own export before cleanup.
