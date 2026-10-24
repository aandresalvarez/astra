# Safe automatic recovery: resume the owned process

## Safety boundary

After an independent investigation identifies a likely stall, ASTRA can recover
an OS-suspended provider by resuming **the same child process** once. This applies
to the shared runner for all six task providers. It does not create another task,
run, provider session, command or process, replay the prompt, or restart a tool.
Existing worker admission and resource leases remain held throughout recovery.

This is deliberately narrower than restarting a hung or dead provider. Current
adapters cannot prove that escaped descendants, remote jobs, or partially
committed tool actions have stopped. Process-group cleanup and a model verdict
are not that proof. Such attempts retain the supervised stop and explain why
automatic relaunch is blocked. No new provider capability is assumed.

## Admission and ownership

1. Only `provider_supervisor_stalled` can trigger recovery. An inconclusive model
   assessment, budget stop, cancellation, policy stop or wall-clock stop cannot.
2. `AgentExecutionScopedProcess` checks macOS process information: the provider
   must be a suspended, unreaped child of this ASTRA process with no stop request.
   The independent investigator receives this positive OS observation, separately
   from silence and file changes. Missing confirmation remains unknown.
3. `RuntimeRecoveryService` checks the current task/run owner and saves a typed
   `runtime.recovery` intent with operation ID, supervisor attempt ID and PID.
   A prior intent for the run blocks another operation, including after reload.
   Save failure blocks the action.
4. Before SIGCONT, the monitor rechecks the progress revision and stop flags;
   the process owner rechecks suspension, identity and cancellation. Reaping and
   signalling share a lock. PID reuse cannot redirect a late recovery signal.
   Only the child PID receives SIGCONT, never its process group or remote jobs.
5. Admission is bounded to 10 seconds. After resuming, ASTRA allows 30 seconds
   for actual parsed progress. Success means a response was observed, not that
   the task succeeded. Normal settlement still decides the task's outcome.
6. New progress, cancellation and completion invalidate pending recovery. A late
   persistence result cannot act. Failed recovery stops normally; there is no
   retry loop. Original token, turn and wall-clock limits are not reset.

The saved intent is an audit record, not a startup command. Startup reconciliation
continues to fail interrupted running requests; it never resumes by a persisted
PID or replays this recovery action. A crash after the intent or signal may leave
an incomplete recovery history, which is safer than trying the action again.

## Status and verification

The task timeline shows intent, resumption, observed response, or the concrete
reason recovery was blocked/expired. Typed events provide the operation and
process identity for auditing. No separate mutable task status is introduced.

Regression suites cover repeated callbacks, stale progress, cancellation, late
admission, persistence failure, reloaded duplicate intents, current run ownership,
bounded recovery, PID checks, cancellation before signalling, all six providers'
shared launch path, and persisted worker settlement with one launch and one run.
Native acceptance uses a separate development bundle, private store and synthetic
workspace with a real provider. Live results are recorded on the PR.

## Future replacement-process recovery

A replacement requires an adapter-specific continuation and cleanup contract,
including remote leases and unfinished tool effects, plus durable fencing across
crashes. It must retain the same remaining limits and refuse unknown ownership.
This implementation does not claim those contracts exist.
