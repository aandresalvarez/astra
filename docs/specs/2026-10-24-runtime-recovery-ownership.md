# Durable execution ownership and recovery

Recovery checks the existing execution before changing its provider session or launching a replacement. The shared worker applies this boundary to every provider.

## Authority and admission

A protected journal beside the SwiftData store records the task, owner generation, run, execution, native session, process identity, remaining allowance, and termination receipt. A stable per-task kernel lock is held through worker settlement. The journal is written and synced before launching; a crash between launch intent and binding the child is an unknown execution, never an unused slot. Task events are an audit projection, not another source of launch authority. Workspace imports cannot supply a recovery receipt.

Automatic recovery, Retry, Resume, direct worker admission, and startup reconciliation share this boundary. A competing worker is rejected before changing the saved provider session. An abandoned owner can be replaced only before launch, after verified termination, or after a durably completed turn with its matching process-exit receipt.

## Existing-session outcomes

- **Working:** keep the existing in-process connection. The suspended-child recovery from #548 can resume that exact child under the same owner.
- **Waiting for input:** keep the existing request; do not restart it. Interactive asks record this state.
- **Finished:** preserve the result and native session. A new user turn can proceed after the matching provider child has been reaped and its process group is empty. Startup can reconcile a result settled after the old app crashed.
- **Stopped:** continue with the saved context and remaining limits only when the termination receipt allows it.
- **Unknown:** preserve the task and explain that replacement is blocked.

Current CLI transports cannot reattach a lost stdout pipe after ASTRA restarts. If the prior process still exists, ASTRA identifies it and explains this limitation. The old run and admission request are marked `runtime_connection_lost`, so the UI stops claiming it is running; the execution journal remains unresolved and keeps replacement blocked. Process existence alone is not proof of useful progress. Provider-native continuation remains subject to the existing session-store and launch-signature checks; incompatible or unavailable native sessions use the history-carrying continuation path.

## Restart proof

A replacement of unfinished work requires all of:

1. A receipt bound to this exact execution and PID plus OS process-start identity.
2. The original child reaped by ASTRA, and its process group confirmed empty.
3. A recognized terminal stream with no tool, teammate, unclassified frame, or uncertain execution activity.
4. No remote SSH route or container execution requiring a separate termination attestation.
5. The old process identity still absent, a persisted owner, and remaining time, turns, and tokens.

A returned tool result does not prove that a detached command or remote job stopped. Such work remains unverified. A model explanation, silence, a success exit code, or missing provider-session files cannot grant restart permission. The existing empty native-resume fallback now requires this proof and a persisted one-attempt allowance. This change does not add a generic restart loop or claim universal remote-tool cleanup.

## Context and limits

Retry of a verified unfinished execution submits a continuation instead of repeating the original command or clearing usage. The next owner inherits the native session when its provider still matches, original token ceiling, recorded consumption, remaining turns/time, cost, and automatic-retry count. Failed preflight and ASTRA restart do not refill these allowances. Enlarging task settings cannot enlarge a recovery allowance. Only a completed task can accept a new explicit user turn under its usual limits. Provider completion followed by failed or pending validation remains unfinished work. Every Retry of a tracked execution requires the full termination proof and retains its remaining allowance, including after a completed provider turn.

A **new explicit user follow-up, approved plan step, or permission approval** is not an automatic replay or Retry. It may continue an unfinished conversation after a matching receipt confirms the prior provider was reaped, its local process group was empty, and its process identity remains absent. It inherits the unfinished execution's remaining limits. It does not attest remote/tool cleanup and cannot grant automatic restart permission. Older tool uncertainty survives every owner handoff, so a later tool-free turn cannot erase it. Retry and Resume requests remain subject to the full proof gate, even when their stored prompt is a continuation. Admission derives authority from the durable source event and typed envelope, never the worker phase, request kind alone, or prompt wording. Startup never invents a new user turn.

All existing tasks with execution history or a native session but no receipt are blocked, including historical failures, cancellations, timeouts and completions. A missing journal never grants a fresh allowance. Imported or legacy execution requires reconciliation; there is no unchecked Retry exception.

## Settlement ownership

Startup permission recovery, orphan-run reconciliation, pending-request recovery and result settlement all defer without changing task state when another app holds the kernel lease. A stale checkpoint for a superseded run cannot pause a newer owner. Uncertain settlement retains the lease through its reconciliation verdict.

The same kernel lease covers result settlement and final plan validation. Before any validator can launch, the journal persists an in-progress barrier. A crash leaves that barrier in place even if the provider has stopped or a task completion was saved. Startup does not turn a validation result or a missing app process into termination proof.

Test commands, syntax checks and AI utilities share process-group cleanup and reaping. A sealed settlement scope records whether all launched local children and groups stopped. New explicit user work can proceed after those local receipts; arbitrary validators may have detached or remote effects, so they never certify tool cleanup for automatic recovery or Retry. An interrupted validation remains blocked rather than replaying it.

Input estimates are charged when the provider reports no usage; finalized run accounting reconciles the journal without double charging. Launch preparation and supervision baselines consume the remaining deadline. Zero remaining time blocks the replacement before spawning, rather than disabling the process timeout.

## Validation

Regression coverage includes competing contexts and workers, exclusive kernel leases, Retry during a live run, preserved usage and continuation requests, crash windows, settled results, corrupt journals, stale process/execution receipts, remote/tool uncertainty, unchanged native-session fallback accounting, and same-process recovery across all six provider adapters. Native acceptance uses a separate development bundle, App Support store, and synthetic workspace with a real provider; evidence is recorded in the PR.
