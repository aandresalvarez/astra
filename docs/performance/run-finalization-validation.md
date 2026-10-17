# Run finalization responsiveness — October 15–16, 2026

## October 17 update on current main

The PR now includes main `709f56a90222` (including #522). Run finalization keeps
main's stable per-run trace IDs and its discovery scan/queue/resume measurements.
Focused routing selects both the saved-export suites and `TaskOutputDiscoveryTests`
for runtime persistence changes, rather than allowing the earlier shell case to
shadow the new discovery coverage.

The updated same-run opt-in benchmark measured 1,507.47 ms wall / 1,502.93 ms
main-thread CPU for synchronous projection versus 28.80 ms wall / 28.65 ms CPU
for save-and-enqueue. The main actor serviced 148 heartbeat ticks while the real
background export completed; the maximum gap was 28.86 ms. The exported JSON
contained the new workspace name and all 600 expected tasks. Fixture totals
remain 2,180 tasks, 5,518 runs, and 56,621 events. These are local synthetic
measurements, not population percentiles or total-export speedups.

Review regressions use a real read-only SwiftData store to fail each of the four
coordinator save APIs and a direct raw save. All five retain the last durable
projection and export its saved rows, never the failed edits. A successful
explicit write clears its superseded pending projection; a failed write stays
owed. Older completions cannot clear a newer saved or debounced request. The
writer fences with the saving main actor before accepting snapshots, while
encoding and filesystem work remain off-main.

Explicit export preparation now issues its replacement ticket only after both
snapshot construction and mirror registration succeed. Regressions reproduce
both a nil snapshot (the store-fetch failure boundary) and a real blocked
registry; either failure preserves the prior queued snapshot and its actual
JSON write. Deletion still retires prior writes separately.

A fresh background context did not protect lazy relationship rows from a
concurrent delete. A disk-backed regression now pauses after reading relationship
identifiers, deletes the event or entire workspace in the live store, and then
continues the projection. The original read aborted; the immutable snapshot
keeps the earlier rows readable. Disk-backed projection now uses ASTRA's
existing SQLite backup service, opens the temporary copy read-only, and removes
it after producing the value config. The temporary directory lives beside the
source store, within its owner's protection boundary rather than provider-writable
temp roots, and has mode 0700. Regressions check placement, permissions and cleanup.
Snapshot copying and projection remain off-main; snapshotting adds background
I/O proportional to store size. In-memory preview/test stores have no SQLite
snapshot and serialize their projection with main-actor edits instead.

Removing synchronous projection also exposed a receipt-recovery dependency:
SwiftData rollback can restore lazy to-many relationship futures as arrays and
abort on the next access. The confirmed GitHub-review receipt transaction now
resolves only the affected task's relationships before its first reversible
edit, through the same helper used for reversible deletion. It does not scan the
workspace. The failure reproduced even with auto-export disabled. Regression
coverage reopens faulted tasks with empty/populated relationships in both
in-memory and disk-backed stores, injects the receipt-save failure, and checks
one network post, durable recovery, and preserved artifacts/skills.

The measurements and local suite counts in the October 15–16 sections below
are historical validation of the original implementation. Current full-suite,
native Dev and remote CI results are tracked separately on PR #511.

## Finding and scope

At `19bb27e668d4`, `WorkspacePersistenceCoordinator.saveAndAutoExport`
saved SwiftData and synchronously constructed the entire workspace recovery
mirror on the main actor. Only JSON encoding and writing ran off-main.
Settlement invokes this path at several durable checkpoints, so workspace-wide
model traversal could delay unrelated transcript updates during completion.

A synthetic disk-backed reproduction on the current implementation measured:

| Synchronous operation | Wall time | Calling thread CPU | Main thread |
| --- | ---: | ---: | --- |
| Save one workspace name | 0.64 ms | 0.63 ms | Yes |
| Prepare workspace mirror | 2,557.71 ms | 2,207.76 ms | Yes |

These are individual local measurements, not population percentiles. Other
builds were active on the machine. Measuring CPU for the calling Mach thread
separates substantial app computation from scheduler delay; the remaining wall
time is not classified as exclusive CPU or database work.

A two-second `sample` at 10 ms intervals captured 153 main-thread samples, all
inside this path:

```text
WorkspaceConfigManager.export(workspace:modelContext:)
  WorkspaceConfigManager.export(workspace:globalSkills:globalConnectors:globalTools:)
    WorkspaceConfigManager.taskConfig(_:modelContext:)
      WorkspaceConfigManager.taskRecoveryMirror(task:modelContext:)
        TaskEvent.type.getter / SwiftData
```

This reproduces main-thread monopolization in a real app service without model
or provider calls. It does not reproduce SwiftUI/AppKit layout behavior or prove
the exact cause of the October 15 09:43 Pacific production cluster. Production
was an older build (`390b91e0c459`); current main already included PR #487's
waiting-for-resource invalidation fix. The later simultaneous Prod/Dev stalls
under extreme global load are not evidence of this implementation failing.
The production-to-main diff leaves the inspected run-persistence, persistence
coordinator, thread view model, and updater-safety files unchanged; #487 changes
the turn-request state machine. This fix addresses the measured export path
rather than reimplementing that sidebar fix.

The final October 16 opt-in regression passed with verified fixture counts.
Within that same run, the synchronous projection took **2,472.86 ms
wall / 2,377.10 ms main-thread CPU**. The new coordinator save-and-enqueue path
took **47.39 ms wall / 47.24 ms main-thread CPU**, including initial mirror target
and registry preparation. While the actual background projection/encode/write
completed, the main actor serviced **197 heartbeat ticks**, with **47.46 ms**
maximum observed gap across the whole window (including enqueue). The resulting
mirror contained the new workspace name and all 600 expected tasks. The earlier
October 15 comparison was 2,046.21 ms versus 46.75 ms; both logs are preserved.

This comparison measures removal of synchronous projection from the UI actor;
it does not claim that total finalization or total export now takes 47.39 ms.
An isolated save in the final run took 0.82 ms wall / 0.82 ms CPU. The new phase
diagnostics recorded 42.74 ms for the coordinator's synchronous save, 2,332.78 ms
for background snapshotting, and 40.42 ms for background JSON encoding. The
expensive projection is still present; it no longer holds the UI actor.
File-write telemetry has the same 8 ms reporting threshold. Phase diagnostics
report elapsed time; exclusive CPU was measured separately by the benchmark.

## Reproduction

```sh
RUN_FINALIZATION_BENCHMARK=1 swift test --jobs 2 --no-parallel \
  --filter RunFinalizationResponsivenessTests
```

The opt-in test creates and removes one temporary SwiftData store: 2,180 tasks,
5,518 runs, 56,621 events, and 23 workspaces. The measured workspace deliberately
contains 600 tasks; one chat contains 2,200 events. This distribution is
synthetic, not a recovered production distribution. Payloads are small and
artifacts are omitted. The updater probe has no active tasks and does not
reproduce the slow production updater query. Seeding is outside the measurements,
saved in batches with main-actor yields. No production store, credentials,
workspace, app, or Dev app identity is used.

The test reports the old synchronous projection separately from the new
save-and-enqueue call, and services a 10 ms main-actor heartbeat while the real
background projection, JSON encoding, and mirror write finish. This validates
scheduling and actual file contents; it is not a visual streaming test.

Local diagnostic artifacts are in
`/tmp/astra-ui-stalls-evidence-2026-10-15/`, including `baseline-harness.log`,
`baseline-harness-stacks.txt`, `benchmark-final-2026-10-16.log`, and a refreshed,
deduplicated channel-separated 72-hour log snapshot. Earlier review snapshots were preserved. The baseline
harness was generated from the test's fixture and linked against the unmodified
current-main persistence/model objects while the full app build completed.

## Implementation contract

- Successful saves remain synchronous and authoritative. Save failures do not
  enqueue exports, and existing throwing/nonthrowing behavior is preserved.
- Coordinator auto-exports read saved models on a serialized actor using a fresh
  read-only context per projection. Managed models never cross actors. Recovery
  evidence, redaction, and mirror limits are unchanged. SSH
  connections are read from canonical/legacy files without invoking migration;
  the ordinary SSH load retains ownership of that migration.
- At most one current pending request is retained per workspace. New requests
  invalidate older tickets before work is dispatched. Old reads are skipped
  before snapshotting or writing; an in-flight stale write cannot commit.
- Requests stay pending through the file write. Termination invalidates queued
  tickets and synchronously saves/exports current state. A late worker cannot
  overwrite the termination mirror or resurrect a deleted workspace.
- A source-context `didSave` observation invalidates a pending read only after
  a successful commit. Failed saves, including direct raw saves, leave the last
  durable projection valid. Before accepting a value snapshot, the writer
  crosses the main actor's save boundary, so a concurrent read cannot outrun
  the successful commit's notification. Encoding and filesystem writes stay
  on the writer actor. Superseded/failed projections remain owed
  until the next explicit export request or termination; they do not trigger
  hidden retries or domain transitions. Continuous saves can delay the mirror.
- Queued and deferred saved-projection requests hold weak persistence owners.
  Only an executing read resolves and retains its container; closed owners are skipped, as are
  stores removed before a queued read starts. This avoids prolonging a closed
  main context and its autosave timer. An invalidated request remains drainable
  only while its source context and container are alive.
- Explicit snapshot callers of `WorkspaceConfigManager.autoExport` retain their
  existing context semantics, including potentially unsaved state. Their tickets
  also supersede older coordinator projections. A successful write retires the
  covered pending projection through the coordinator; failed writes and newer
  saved or debounced requests remain owed.
- Persistence signposts and thresholded diagnostics distinguish `swiftdata_save`,
  `mirror_snapshot`, `mirror_encode`, and `mirror_write`. Finalization publishes
  synchronous main-thread phase markers and preserves main's stable per-run
  trace identity and separate discovery scan/queue/resume timings. Elapsed
  discovery and parent finalization timings include waits.
  Frequent transcript pre-read saves retain their existing silent success path;
  the new timing audits do not add work to that streaming refresh path.

## Lifecycle validation

The first full-suite run exposed a lifecycle bug in the initial implementation:
invalidated pending exports strongly retained their source contexts and
containers after a fixture removed its temporary disk store. A later SwiftData
autosave aborted while accessing that removed store. Pending bookkeeping now
uses weak owners, and a queued worker resolves the container on the reader actor
only when work starts. A synchronous preparation scope releases that owner
before awaiting the JSON writer; only values wait in the writer queue. A
regression verifies a prepared snapshot can still be written after its store
owner closes. Disk and memory regressions enable autosave and assert
that the owner is released even before the worker starts, no mirror is written,
and termination safely skips the closed owner. Tests also cover supersession,
raw/bookkeeping-save invalidation, deletion, path changes, and synchronous
termination drain against an already prepared late write.

The recovery cleanup regression now explicitly awaits its scheduled mirror
attempt before reading JSON. Its durable save and JSON-content assertions are
unchanged; JSON encoding and writing were asynchronous even before this change.
Waiting does not save, retry, or export a deferred bookkeeping state.

## Local verification

- Final focused regressions: 134 tests in 12 suites passed.
- Full `swift test --skip-build --jobs 2 --no-parallel`, after compiling the
  final source in the focused run: 7,949 tests passed across all package targets
  (7,805 app tests plus 144 support/architecture tests). The app target finished
  in 1,303.365 seconds. No SQLite errors or autosave abort recurred; the original
  failing preference-domain suite also passed in this full run.
- Architecture: 117 tests in 10 suites passed, both independently and in the
  full run. Focused-target/validation-plan shell regressions and diff checks passed.
- The final opt-in benchmark passed separately; it stays disabled in ordinary
  tests to avoid creating the large fixture on every run.

Logs are preserved under the evidence directory as
`focused-final-2026-10-16.log`, `benchmark-final-2026-10-16.log`,
`benchmark-final-phases-2026-10-16.log`, and `full-final-2026-10-16.log`.
This validates local service behavior and scheduling. GUI/streaming validation
requires an available Dev app identity; another checkout owned the running Dev
at preflight, and no takeover was authorized. CI and production validation are
separate from these local results.

## Remaining limits

The background projection still performs the same CPU work. A read already in
progress can finish after supersession, but its result is discarded. Explicit
exports and termination drains can still occupy the main actor; this change
targets automatic exports following coordinator saves. SwiftData save,
filesystem registration, reconciliation, and SwiftUI layout retain independent
costs. Historical freezes and real production behavior need validation after a
normal reviewed release; no release or production experiment is part of this PR.
