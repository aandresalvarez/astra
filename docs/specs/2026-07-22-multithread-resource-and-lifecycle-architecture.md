# Multithread Resource and Lifecycle Architecture

## Decision

ASTRA admits work globally across workspaces. Durable `TaskTurnRequest` rows are
the queue authority; resource claims decide which otherwise-runnable requests
may execute together. A request acquires its complete claim set atomically:
shared claims may coexist, while an exclusive claim conflicts with overlapping
shared or exclusive claims for the same canonical resource.

Workspace identity is only one resource namespace. Repository roots, host paths,
container mounts, and other external resources use typed, canonical identities,
so tasks in different ASTRA workspaces still conflict when they touch the same
underlying resource. Admission, persisted waiting state, runtime sandboxing, and
UI blocker projection must be derived from the same resolved claim set.

## Persistence lifetime

`TaskQueueStoreSession` owns both the `ModelContainer` and its main
`ModelContext`. Queue-owned asynchronous work captures the session or durable
identifiers, never a context borrowed without an owner. The task registry keeps
tokenized handles for processing, dispatch, and lifecycle coroutines until each
completion defer runs.

`cancelAll()` revokes authority synchronously but is not a teardown boundary.
`cancelAllAndWait()` cancels, awaits every registered handle, and only then
releases the store session. A queue cannot restart or bind a different context
while shutdown is draining.

Legacy queued-task conversion is a one-time store-session repair. The normal
admission loop reads durable requests only and never mutates queue state by
rescanning legacy task status.

## Deadline ownership

Elapsed-time behavior uses monotonic absolute deadlines. Timers are wake-up
mechanisms, not sources of truth:

- Sidebar settle state reconciles its deadline on every relevant event.
- Git authoring supplies one timeout budget to the process runner rather than
  racing a second watchdog.
- The process runner owns timeout, process-group termination, reaping, and final
  pipe drain; awaiting it never returns while the helper is still alive.

## Verification invariants

Regression coverage must prove:

1. Compatible shared claims run concurrently and conflicting claim sets acquire
   atomically without partial ownership.
2. Cross-workspace aliases of the same resource conflict after canonicalization.
3. Cancellation retains drain handles until their tasks actually finish, and a
   store is released only after awaited shutdown.
4. Legacy repair runs once per bound session, outside the admission loop.
5. Expired UI and provider deadlines are classified correctly even when timer
   delivery is delayed.
6. A timed-out helper process is reaped and its pipes drained before the caller
   resumes.

The full Swift test suite remains parallel. Serialization or larger wall-clock
thresholds may be diagnostic tools, but are not correctness fixes.
