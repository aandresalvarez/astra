# Runtime Selection and Active-Run Switching

## Root cause

A runtime picker describes how a future execution should launch. An active
execution is instead owned by an immutable launch manifest, a broker-issued
execution ID, and fenced authority. Treating both concepts as one mutable
"selected runtime" value lets a harmless preference edit accidentally become
process control, makes stale UI state authoritative, and encourages implicit
kill-and-relaunch behavior.

The core contracts therefore separate two operations:

1. `NextExecutionRuntimeSelectionReducer` changes only the configuration for
   the next launch. Its state keeps the active identity observation unchanged,
   and its result contains no cancellation or process-control command.
2. `RuntimeSwitchPolicy` evaluates a separately submitted active-run control
   request. The default request is a graceful handoff. Immediate termination is
   a different request variant with force-only audit and confirmation fields.

Neither contract contains a PID or fallback runtime. Control is compare-and-
swap fenced by execution ID, authority ID/epoch, and active configuration
revision.

## Decision table

Checks occur in the order shown so identical inputs produce identical results.
A blocked result never emits a directive.

| Request / observed fact | Result | Control directive |
| --- | --- | --- |
| Same accepted request ID and exact payload | `idempotent` | Replay original directive |
| Same accepted request ID, changed payload | `request_id_conflict` | None |
| A different switch is already accepted | `switch_already_pending` | None |
| Execution ID differs | `execution_identity_mismatch` | None |
| Authority ID or epoch differs | `stale_authority` | None |
| Active configuration revision differs | `stale_configuration_revision` | None |
| Active configuration payload differs under the same revision | `active_configuration_mismatch` | None |
| Execution is terminal | `execution_not_active` | None |
| Target equals active configuration | `target_matches_active_configuration` | None |
| Graceful request with an in-flight effect/tool | `in_flight_effects` | None |
| Graceful request with an in-flight tool operation | `in_flight_tool_operations` | None |
| Graceful request without checkpoint evidence | `safe_checkpoint_unavailable` | None |
| Provider continuation absent/unsupported | Typed provider continuation block | None |
| Supervisor continuation absent/unsupported | Typed supervisor continuation block | None |
| All graceful safety facts are present | `applied` | Handoff at the pinned checkpoint |
| Force request without confirmation | `force_confirmation_required` | None |
| Force confirmation names another request | `force_confirmation_request_mismatch` | None |
| Force confirmation names another execution | `force_confirmation_execution_mismatch` | None |
| Force confirmation names another target configuration | `force_confirmation_target_mismatch` | None |
| Force confirmation predates the request | `force_confirmation_predates_request` | None |
| Explicit force request has matching fresh confirmation | `applied` | Force termination, then exact target launch |

"Continuation supported" is an affirmative declaration from both the provider
adapter and detached supervisor. Missing information is not inferred as
support. A safe checkpoint additionally requires a stable checkpoint ID and
zero in-flight effects or tool operations.

## RunBroker integration seam

This change is value-only and does not migrate provider launches. Once the
RunBroker service lands, its active-run command handler should:

1. Load the canonical active execution identity, current authority, current
   configuration revision, effect projection, and supervisor checkpoint
   capability from the ledger/supervisor channel.
2. Call `RuntimeSwitchPolicy.reduce` before writing control intent.
3. Append the accepted request and pinned checkpoint atomically under the same
   authority/configuration compare-and-swap.
4. Send only the returned directive to the authenticated supervisor.
5. Project the accepted/blocked result back to SwiftData/UI idempotently.

The runtime picker should persist `NextExecutionRuntimeSelectionState.next`
through its existing task-settings service. It must not call the active-run
command handler. The full provider-launch migration and checkpoint transport
belong to the broker integration PR; there must be no temporary "try broker,
then launch locally" path.
