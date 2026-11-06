# Export memory ownership evidence (PR 1)

This investigation starts from `c23ff0c5079f5fad8b1a57f811223a5b80b9b3d3`,
verified against `origin/main` on November 6, 2026. That is also the embedded
commit examined in the November 5 production report. No comparison here can
establish a regression from an earlier release.

## Reproduction

Use a free local Swift slot and at least 12 GiB free disk. All fixtures are
generated from seed `20261106`, with fixed UUIDs, timestamps and payloads.
Each mode starts a fresh Swift test process with its own disk-backed store,
workspace folders and mirror registry. No credentials or provider requests are
needed. Each workload copy is removed at test exit; the reusable fixture and
evidence logs remain in the explicit output directory. No application is
launched or stopped.
Diagnostic subprocesses use an OS/toolchain environment allowlist, excluding
inherited provider credentials and host preference-domain overrides. The app
benchmark also assigns an isolated provider coordination namespace and removes
only that namespace after its owned process exits.

```sh
script/swift_test.sh --no-parallel --jobs 2 --filter WorkspaceExportMemoryEvidenceTests
python3 script/benchmarks/export_memory_evidence.py --output /private/tmp/astra-export-small
python3 script/benchmarks/export_memory_evidence.py --scale representative --output /private/tmp/astra-export-representative
python3 script/benchmarks/export_memory_evidence.py --scale representative --modes export --profile --output /private/tmp/astra-export-profile
```

Small means 12 tasks, 12 runs and 300 events. Representative means 2,200 tasks,
2,200 runs and 75,000 events in one task. Events use the synthetic
`validation.synthetic` recovery type, which the existing exporter preserves in
full. Both have two workspaces, one empty.
One separate Swift process seeds tasks, runs and a single event prototype.
After that process exits, the runner expands only that generated event row in
offline SQLite, preserving its task/run foreign keys and checking schema,
UUID encoding, primary-key metadata and integrity. Every workload opens a
private backup through real SwiftData, which verifies stored counts and reads
the relationships. This avoids measuring expensive inverse-relationship
construction/allocator fragmentation as part of the export workload. The
fixture store hash and actual table counts are recorded in the manifest.
Actual persisted counts are checked before and after work. Every projected or
published mirror is checked for its full task/event counts.

The current mirror is **not** a full transcript export: `MirrorLimits` caps
ordinary events at 10 per task and retains recovery evidence separately. An
initial `system.info` fixture correctly persisted 300 events but exported only
10; those failed fixture-contract runs are not lifetime-reproduction results.
Switching the fixture to a supported recovery type preserves complete synthetic
output without changing product semantics. PR 3 must explicitly reconcile the
plan's complete-history requirement with this existing bounded mirror contract.

`export` drives committed saves through `WorkspacePersistenceCoordinator`,
the normal asynchronous reader, JSON writer and completion. `history` repeatedly
reads the real bounded history page without exporting. `combined` does both.
`direct` is the synchronous immutable-snapshot projection control. `cleanup`
uses one shared startup-style snapshot and checks that both workspace mirrors
are published with exactly one backup. `failure` injects ENOSPC at staging,
checks pending work, and drains it. `cancellation` cancels a sealed job before
projection, awaits it, then drains the pending revision. `termination` drains a
sealed, paused job synchronously, then releases and awaits the retired job.
Existing replacement tests cover cancellation/failure after projection too.

Block 0 is warm-up; blocks 1–6 repeat equivalent work with fixed history.
`--blocks` can change this within 1–30. `--assert-teardown` enables the opt-in
post-work reader/descriptor contract without making machine memory numbers a
normal CI threshold. Normal CI skips the workload.

The runner reuses the existing `dev_scale_benchmark.py` provenance/file helpers.
The in-process fixture is necessary to reach internal coordinator seams and
weak lifetimes. `record_memory_trace.sh` retains its packaged-Dev-only guard;
the test runner instead captures synthetic process heap graphs directly.
`--profile` accepts one mode, two generations, 60-second pause boundaries,
12-second probes and a 2 GiB per-probe file limit. Probe errors/timeouts remain
in the evidence files and must be considered before drawing conclusions.

## Measurement interpretation

Each boundary records charged physical footprint and resident bytes from
`task_vm_info`, aggregate live malloc bytes/blocks, weak SwiftData container and
context counts, actual open snapshot descriptors by device/inode, unique
unlinked inode bytes, pending obligations, snapshot directories and staging
files. `awaited_jobs_active=0` describes this sequential harness's completed
jobs; it is not instrumentation of a global production queue.

Weak observations are task-local and keep no reader alive. Descriptors use the
existing test helpers and `fstat`, so removed paths are still measured. Snapshot
disk bytes must never be added to heap/footprint. Malloc totals include the test
runtime and source-store caches. Graph differences show surviving allocations
between two boundaries, not every temporary allocation or Instruments epoch.
The manifest includes commit, source hashes, test binary hashes, toolchain,
invocation, exit statuses and all samples.

## Service controls

The baseline plus diagnostic observer/fixture code completed all eight modes
at both scales. [Raw measurements and source/binary hashes](../benchmarks/export-memory-2026-11-06.json)
retain every sample. There is no teardown implementation change in these runs.
Each row below compares warm-up block 0 with block 6, in MiB.

| Representative mode | Physical footprint | RSS | Live malloc bytes |
| --- | ---: | ---: | ---: |
| History only | 33.83 → 34.02 | 204.80 → 204.98 | 3.59 → 3.62 |
| Async export | 171.03 → 168.44 | 436.52 → 488.44 | 3.56 → 3.64 |
| Combined | 170.72 → 202.59 | 444.94 → 524.41 | 3.76 → 3.82 |
| Direct read | 59.16 → 78.78 | 325.47 → 345.22 | 3.51 → 3.55 |
| Shared cleanup | 204.52 → 132.06 | 470.98 → 453.67 | 3.59 → 3.63 |
| Staging failure/retry | 159.47 → 151.86 | 472.17 → 474.61 | 4.10 → 4.19 |
| Cancellation/drain | 182.33 → 183.08 | 448.69 → 502.86 | 3.56 → 3.63 |
| Termination drain | 223.14 → 180.72 | 489.59 → 499.47 | 3.56 → 3.66 |

All 112 small/representative boundaries had zero live observed snapshot
containers/contexts, pending
obligations, snapshot directories and staging files. The tracker observed seven
readers per ordinary export/direct/combined/drain mode, and fourteen per shared
cleanup/failure-retry mode; history-only opened none. The original direct runs
missed descriptor instrumentation because detached tasks do not inherit task
locals. The corrected direct reruns are recorded separately. The other modes
reported zero snapshot descriptors and unlinked bytes. Small-control footprint
increases were at most 0.70 MiB. The representative combined run's 31.87 MiB
footprint increase accompanies only about 0.06 MiB additional live malloc
bytes. These endpoints do not establish a sustained trend or attribute all
charged pages to retained objects.

The first representative fixture attempt was stopped before any export:
2,200 tasks and 12,000 events had been saved, physical footprint was 3.3 GiB,
and vmmap reported 647.8 MiB allocated with about 2.6 GiB allocator
fragmentation. A one-second stack sample was in SwiftData insertion and
relationship identity checks. This is a fixture-construction confounder, not
evidence that the same owner caused the production growth. Reusable offline
fixtures remove that setup from measured workload processes. A separate
WAL-opening setup failure was also excluded; reusable stores are normalized to
DELETE journal mode and integrity-checked before workload copies.

## App and reference evidence

The app fixture adapter reuses the generated representative store with the
existing external Dev benchmark. It records its source hash, places the long
thread and a one-event short thread in Scale 01, and puts the remaining tasks
in Scale 00. App transcript events are ordinary user messages; their bounded
JSON mirror semantics intentionally differ from the full recovery-event stress
fixture above. The durable app fixture contains 75,001 events, with 75,000 in
the long thread. Its task IDs have unique folder prefixes.

```sh
python3 script/benchmarks/prepare_export_app_fixture.py --source /private/tmp/astra-export-representative/fixture --output /private/tmp/astra-export-app-fixture
python3 script/benchmarks/dev_scale_benchmark.py --app 'dist/ASTRA Dev.app' --build-dir <matching-build-products> --profile no-files --omit-task-files --fixture /private/tmp/astra-export-app-fixture --plan /private/tmp/astra-export-app-fixture/combined-plan.json --runs 1 --cycles 6 --idle-seconds 2 --memory-graphs --output /private/tmp/astra-export-app
```

`--memory-graphs` adds RSS, per-boundary lsof snapshot device/inode metadata,
and bounded no-content warm/final heap graphs. Descriptor parsing tests cover
duplicate descriptors, link counts and exclusion of other store roots.
An optional `--allocations-seconds 60` run invokes the unchanged guarded
`record_memory_trace.sh` on a private, uniquely identified `ASTRA Dev.app`
copy. Capture is capped at 180 seconds. Trace processes are owned and drained
before the app exits; profiled results are reported separately. Heap probes
have a 2 GiB per-file limit, and profiling workloads require 12 GiB free disk.

The isolated Dev bundle opened the disposable store. The accessibility wait
for the first long-thread click timed out before any save. The run recorded
101.3 MiB of physical footprint and zero open snapshot descriptors at launch.
It provides no app export measurements. The initial invocation also exposed
a missing zero file count in the fixture manifest, which is now included.

SwiftPM buffered stdout in the first profiling attempt. Parked-process markers
now use an atomic file as the attachment boundary.

The owned-request variant adds one completed typed request referencing the
oldest event. All seven async exports preserved the full fixture and ended
with zero snapshot readers or descriptors. At the test's sampling boundary,
malloc bytes rose from 4,583,312 to 5,373,376. The parked heap generations
measured 3,913,648 to 3,981,024 live bytes, a net increase of 67,376 bytes.
The final graph contained one SwiftData container, one SwiftData context and
one NSSQLCore. The new-allocation diff includes logging, runtime caches and
diagnostic bookkeeping. The largest class in that diff is untyped allocations.
These observations do not identify a retained snapshot reader.

The full local serial Swift suite passed, including 10,015 main app tests
and 126 architecture tests. The Dev bundle passed signature verification.

A manual no-content graph captured PID 32763 during the final parked block
of that synthetic run. It contains one `ModelContainer`, one `ModelContext`,
one `NSManagedObjectContext`, one `NSPersistentStoreCoordinator` and one
`NSSQLCore`. The source container's `_mainContext` reference and active test
task are visible in the reverse reference graph. This matches the deliberately
live source fixture, while all seven observed snapshot readers had expired.
It identifies the expected source owner, not a leaking export owner. This
single graph is not an allocation-generation comparison; the two automated
attachments in the original buffered-output attempt missed the exited process
and are excluded.

## PR 2 decision and acceptance gap

**Hold the teardown implementation decision.** The service controls do not
reproduce the production failure and do not identify its retaining allocation
owner. Neither another autorelease pool nor a disposable helper is justified
by these results alone. PR 1's failing normal-path reproduction and owner
evidence remain unresolved. This draft is diagnostic work, not release-ready
remediation, and does not establish that production's readers close correctly.
