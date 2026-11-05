# Startup sidebar and cleanup instrumentation

This change adds observations only. SwiftData, accordion state, cleanup leases,
snapshot lifetime and publication gates retain their existing authority.

## Reading a folder trace

`sidebar_folder_handler` records entry to the folder button action.
`sidebar_folder_view_ready` closes that trace from the stable row group's SwiftUI
lifecycle callback after the drawer values have been prepared. Every activation
has a new `trace_id`, including keyboard repeat and reopening an unchanged folder.
`sidebar_folder_unfinished` reports supersession or sidebar disappearance; an old
callback cannot complete a newer trace. Each sidebar instance owns its own trace.

| Field | Meaning |
| --- | --- |
| `input_queue_ms` | Supported current NSEvent timestamp to button handler entry, on the boot clock. Includes AppKit dispatch before action entry. Missing, unrelated and invalid timestamps report `unavailable`. |
| `handler_to_ready_ms` | Handler entry to the SwiftUI readiness callback. Excludes input queue delay. |
| `drawer_preparation_ms` | Cumulative synchronous preparation of this workspace row while the trace is pending; a subset of handler-to-ready time. |
| `input_to_ready_ms` | Queue plus handler-to-ready, when the event timestamp is usable. |
| `eligible_row_count` | Task rows admitted by the current drawer filters before the preview limit. |
| `displayed_row_count` | Task rows supplied to the expanded drawer after its preview limit; zero on collapse. These are view rows, not a visible-pixel count. |
| `displayed_app_count` | App rows supplied separately from task rows. |
| `ready_state` | `rows`, `empty`, `no_eligible_rows` (empty state suppressed), or `collapsed`. |
| `launch_age_ms` | Monotonic age since entry to `ASTRAApp.init`; `handler_launch_age_ms` anchors action entry. Headless tools/tests that never enter app init report `unavailable`. |

`readiness_basis=swiftui_lifecycle` and `pixels_displayed=not_measured` are explicit:
this does not measure layout completion, animation completion, compositor
submission or display scan-out. An offscreen group can become ready. No display
latency claim should be derived from this endpoint. The existing UI responsiveness
report summarizes `sidebar_folder_input_queue` separately from
`sidebar_folder_handler_to_view_ready:expand` / `:collapse`; unknown queue
timestamps contribute no sample.

The watchdog can name `sidebar_folder_toggle`, `sidebar_folder_state_update`,
`sidebar_drawer_prepare`, `sidebar_drawer_eligible_rows`,
`sidebar_drawer_relationship`, and `sidebar_drawer_apps`. Persistence's existing
`WorkspacePersistenceWork.measure` scopes now publish through the same
`MainThreadPhase` owner via `AuditLoggingSeam`. No phase is held across an await.
Cleanup admission, workspace fetch and scope recheck use
`cleanup_mirror_admission`, `cleanup_mirror_workspaces` and
`cleanup_mirror_scope_check`; startup's synchronous deletion/outbox stages have
named scopes too. All normal
performance lines, including stall reports, carry launch age for correlation.

## Reading cleanup work

The retained post-recovery cleanup task emits one `startup_cleanup_job` summary.
Job/pass entry also emits a small `*_started` marker, so an unfinished scope
can be identified before its summary exists. Each saved-mirror rewrite emits one `startup_cleanup_pass` summary, with the same
`job_id`, a fresh `pass_id`, and `trigger=connector_generation`,
`skill_generation`, or `plugin_secret_outbox`. A standalone/test invocation has
`job_id=none`; unspecified callers remain source-compatible.

Task-local diagnostic scopes follow awaited actor calls and inherited child
tasks. The job summary covers work through that task's return, not unrelated
detached background exports. A `returned` job is not a claim that every cleanup
debt was settled; a pass reports `ready` or `held` under the existing contract.

Summaries include copy attempts/success/failure, distinct workspace IDs counted
once, mirror request acknowledgements, JSON encode/write outcomes, encoded,
attempted and successfully published JSON bytes, and successful copies' logical
file lengths. `logical_snapshot_bytes` sums repeated copies; it is neither
allocated blocks nor physical device I/O. Unknown copy sizes are counted.
Mirror acknowledgements follow the existing API, which can acknowledge a skipped
export; actual copy/JSON counters show whether data work occurred.

Existing phase timings gain job/pass IDs and launch age. Summaries retain
per-phase count, total, main-thread total and maximum milliseconds, including
samples below the old timing threshold. New instrumentation adds no per-task or
per-copy log stream. Error counts use finite categories (disk full/quota,
permission, missing, busy, snapshot, encoding, cancelled, other), without error
descriptions, paths, workspace names, task text or credential values.

## Synthetic evidence

`SidebarFolderResponsivenessTelemetryTests` verifies these selected fields for
open, close, then open again, with unchanged eligible counts:

```text
sidebar_folder_view_ready trace_id=A action=expand   input_queue_ms=7000.00 handler_to_ready_ms=20.00 drawer_preparation_ms=4.00 eligible_row_count=2 displayed_row_count=2
sidebar_folder_view_ready trace_id=B action=collapse input_queue_ms=7000.00 handler_to_ready_ms=20.00 drawer_preparation_ms=4.00 eligible_row_count=2 displayed_row_count=0
sidebar_folder_view_ready trace_id=C action=expand   input_queue_ms=7000.00 handler_to_ready_ms=20.00 drawer_preparation_ms=4.00 eligible_row_count=2 displayed_row_count=2
```

A/B/C stand for distinct generated trace IDs. Duplicate readiness callbacks emit
nothing. Other scenarios exercise a keyboard repeat event, an empty drawer,
unknown timestamps, supersession, and the actual SwiftUI readiness modifier in
an offscreen synthetic hosting window. Two toggles coalesced before a SwiftUI
update report the first trace as unfinished and complete only the latest trace.

`StartupCleanupTelemetryTests` uses two 4 KiB synthetic copies for one workspace,
a failed copy for another, two 64-byte encodes and one failed JSON write. Across
an actor hop and an inherited child task, the job and pass both aggregate:

```text
copy_attempts=3 copy_succeeded=2 copy_failed=1 distinct_workspaces=2
logical_snapshot_bytes=8192 json_encoded_bytes=128 json_written_bytes=64
json_write_attempted_bytes=128 error_disk_full=2
```

Additional cases exercise quota/nested Cocoa errors, SQLite FULL, three successive
pass scopes, and the persistence-to-watchdog phase bridge. Existing credential
startup tests continue to own fail-closed cleanup behavior. Synthetic observations
do not establish the cause of any production stall.
