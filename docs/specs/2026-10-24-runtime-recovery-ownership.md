# Durable execution ownership and recovery

Recovery checks the existing execution before changing its provider session or launching a replacement. The shared worker applies this boundary to every provider.

## Authority and admission

A protected journal beside the SwiftData store records the task, owner generation, run, execution, native session, process identity, remaining allowance, and termination receipt. A stable per-task kernel lock is held through worker settlement. The journal is written and synced before launching; a crash between launch intent and binding the child is an unknown execution, never an unused slot. Task events are an audit projection, not another source of launch authority. Workspace imports cannot supply a recovery receipt.

Automatic recovery, Retry, Resume, direct worker admission, and startup reconciliation share this boundary. A competing worker is rejected before changing the saved provider session. An abandoned owner can be replaced only before launch, after verified termination, or after a durably completed turn with its matching process-exit receipt.

## Existing-session outcomes

- **Working:** keep the existing in-process connection. The suspended-child recovery from #548 can resume that exact child under the same owner.
- **Waiting for input:** keep the existing request; do not restart it. Interactive asks record this state.
- **Finished:** preserve the result and native session. A new user turn requires the same full execution and tool termination proof as Retry. Startup can reconcile a result settled after the old app crashed without authorizing uncertain new work.
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

A **new explicit user follow-up, approved plan step, or permission approval** remains distinct from replay for context and limits, but requires the same full cleanup proof. It inherits the unfinished execution's remaining limits. Older tool uncertainty survives every owner handoff, including an interrupted preparation from an older app version. Retry and Resume remain subject to this gate even when their stored prompt is a continuation. Admission derives intent from the durable source event and typed envelope, never the worker phase, request kind alone, or prompt wording. Startup never invents a new user turn.

Execution history from before this journal existed has no receipt, so it requires reconciliation. A task qualifies only when the journal never tracked it (no ownership event), every run has a terminal status and a recorded completion, every run ran on the host rather than in a container, every run ended before the current app process started (so the app instance that supervised it has exited), and the latest run records a stop reason other than an app restart or a lost connection. The first owner it admits records the settled run in the journal, the task records why, and from then on that receipt governs the task. This accepts the older version's own settlement; those versions never recorded tool, SSH or container termination, so it does not claim that proof.

Every other task with execution history or a native session but no receipt is blocked, including a tracked task whose journal is missing and historical runs that were cut off, still marked running, unsettled or containerized. A missing journal never grants a fresh allowance, and there is no unchecked Retry exception.

## Settlement ownership

Startup permission recovery, orphan-run reconciliation, pending-request recovery and result settlement all defer without changing task state when another app holds the kernel lease. A stale checkpoint for a superseded run cannot pause a newer owner. Uncertain settlement retains the lease through its reconciliation verdict.

The same kernel lease covers result settlement and final plan validation. Before any validator can launch, the journal persists an in-progress barrier. A crash leaves that barrier in place even if the provider has stopped or a task completion was saved. Startup does not turn a validation result or a missing app process into termination proof.

Test commands, syntax checks and AI utilities share process-group cleanup and reaping. A sealed settlement scope records whether all launched local children and groups stopped. Arbitrary validators may have detached or remote effects, so local receipts alone never certify tool cleanup for new work or recovery. An interrupted validation remains blocked rather than replaying it. New validation cannot start while the provider's own cleanup remains uncertain.

Already persisted resource releases from older versions remain historical decisions; this change does not retroactively claim that they carried the stronger proof. Unreleased legacy ownership remains fenced.

Input estimates are charged when the provider reports no usage; finalized run accounting reconciles the journal without double charging. Launch preparation and supervision baselines consume the remaining deadline. Zero remaining time blocks the replacement before spawning, rather than disabling the process timeout.

## Validation

Regression coverage includes competing contexts and workers, exclusive kernel leases, Retry during a live run, preserved usage and continuation requests, crash windows, settled results, corrupt journals, settled and unsettled pre-journal history, stale process/execution receipts, remote/tool uncertainty, unchanged native-session fallback accounting, and same-process recovery across all six provider adapters. Native acceptance uses a separate development bundle, App Support store, and synthetic workspace with a real provider; evidence is recorded in the PR.
