# Multi-thread Execution

ASTRA treats each accepted user action as a durable execution request. The
runtime process, task status, sidebar, and in-memory scheduler are projections
of that durable state; none of them independently owns whether work exists.

## Source of truth

`TaskTurnRequest` owns admission lifecycle state for initial runs, follow-ups,
retries, scheduled runs, and plan steps. The source `TaskEvent` owns the user or
system intent. Submission persists both before the composer clears or the queue
attempts admission.

The request lifecycle is:

```text
waiting_for_worker -> waiting_for_resource -> admitted -> running
                                                       -> completed
                                                       -> failed
waiting states ----------------------------------------> cancelled
```

Startup reconciliation converts interrupted active states into replayable or
terminal states and then asks the same request-native scheduler to continue.

## Scheduling invariants

- Requests are considered globally by submission time.
- Only the first active request for a task is eligible, preserving per-task
  FIFO ordering and one worker per task.
- An unavailable workspace or resource may be bypassed so unrelated projects
  continue; the blocked request retains its place and blocker state.
- Resource claims, not workspace UI selection, decide whether work conflicts.
- Process-local worker and lock ownership is cancellable and drainable, but it
  is never a second durable queue.

## UI projection

The sidebar Activity section derives running and waiting rows from durable
requests across all workspaces. Workspace expansion controls navigation only;
it does not control whether concurrent work is visible or scheduled.

## Operational diagnostics

Queue audit events contain identifiers and aggregate counts, never prompts,
task titles, workspace names, or paths. `task_dequeued` and `queue_drained`
expose:

- `active_request_count`
- `admittable_task_count`
- `active_task_count`
- `active_workspace_count`
- `waiting_worker_count`
- `waiting_resource_count`
- `admitted_count`
- `running_request_count`
- `orphan_request_count`
- `oldest_wait_seconds`
- `pool_size` and `active_worker_count`

When diagnosing work that appears stalled, first confirm the durable active
count, then distinguish worker saturation from resource contention. A nonzero
`waiting_resource_count` with other projects dequeuing is healthy head-of-line
bypass. A rising `oldest_wait_seconds` with no dequeue or terminal event is a
scheduler/lifecycle fault and should be investigated with the request ID.

## Development-store recovery

ASTRA Dev may explicitly create a fresh current-schema store after an unknown
open failure. It validates the new SQLite store before atomically activating
the new generation and retains the prior store for inspection. Production
ASTRA cannot invoke this action and remains fail-closed.

## Acceptance gates

Run the scheduler, durable admission, UI projection, and recovery suites before
shipping changes to this path:

```bash
swift test --filter ExecutionRequestAdmissionSchedulerTests
swift test --filter TaskTurnRequestAdmissionTests
swift test --filter TaskActivityPresentationTests
swift test --filter PersistentStoreRecoveryTests
./script/prepush.sh
```

The scheduler suite includes a 120-request, 60-task, three-project backlog that
proves per-task FIFO and cross-project bypass. Admission tests are serialized
because they intentionally create long-lived main-actor queue coroutines; this
keeps test-container teardown deterministic while production scheduling remains
concurrent across tasks.
