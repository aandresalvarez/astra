# Permission approval owns continuation

A provider exiting successfully does not establish that the user's request was
fulfilled. A structured blocked connector invocation remains unfinished work.
Task C3AF9E7F demonstrated the former mismatch: ASTRA marked the task completed,
saved a later Jira grant, and displayed “Continuing” without submitting a run.

## Durable ownership

Permission approval payloads carry optional, backwards-compatible execution
metadata: behavior (`continueBlockedTurn` or `futureUse`), originating run/source
identity, original user request, and live versus relaunch mode. The task's existing
permission JSON and append-only events remain the owners. No SwiftData schema
changes or provider-response keyword classification are required.

The worker discovers blocked calls at the run boundary and applies a permission
outcome before accepting successful process exit. The task waits for the user's
decision. Credential values stay in ASTRA; approval does not bypass connector
mutation gates or grant unrelated permissions.

## Approval transaction

`PermissionApprovalResolutionService` resolves the selected request. A task-scoped
grant, request resolution, approval event, and permission continuation submission
are persisted together through `ExecutionRequestSubmissionService`. Only then
does the lifecycle coordinator signal the existing queue. Submission keys include
the originating run and request id, so repeated clicks cannot create another run.
One-run grants travel in the execution request, rather than becoming task grants.

The continuation preserves the original turn's intent snapshot. Cancelled,
closed, superseded, and runtime-changed requests cannot restart work. A save
failure restores the grant/request state and reports that approval must be retried.
Future-use offers save permission without execution and have distinct UI wording.

Live asks resolve only their own control-channel waiter. A durable live approval
commit covers a restart before the provider acknowledges the answer. Startup
recovery finishes local settlement from the captured provider result.
An approval whose live delivery is uncertain requires reconciliation before
retrying; it never automatically replays potentially completed external work.
Known unwritten responses transfer authority to a durable continuation before
completion is accepted; normal queue replay performs admission.

## Compatibility and presentation

Older open connector requests bind to the run that recorded them. Older requests
whose task-scoped grant was already saved expose an explicit “Continue approved
request” action. Merely opening the task never restarts it.

The timeline says “Continuation queued” only when that submission was committed.
Older approval notices show “Permission approved,” because they do not prove that
execution started. Existing task/run presentation supplies running status after
queue admission.

## Verification

Regression coverage includes successful provider exit with a blocked connector,
delayed approval through the full worker/queue path, original-turn preservation,
legacy requests, explicit recovery of already-approved tasks, future-use offers,
independent requests, duplicate submission, rollback on save failure, cancelled
and superseded tasks, persistence across store reopening, and live acknowledgement
recovery. Provider and connector traffic in these tests is simulated locally.

## Shared result settlement

`RuntimeTurnSettlementService` owns two typed, run-scoped events, without adding
another mutable model or changing the SwiftData schema:

1. `runtime.result.captured`: after draining provider events, the result,
   acknowledgement evidence and immutable execution/plan envelope are saved
   together. The runner returns transport evidence and never saves receipts.
2. `runtime.turn.settled`: the shared outcome and plan finalizers have reconciled
   permission delivery and validation. The final task/run/request outcome,
   continuation (if required) and downstream-work intent are committed together.

Normal runs and restart recovery call the same settlement service. Orphan-run
and admission recovery leave captured results to that service. Startup completes
local settlement before queue replay and never invokes the original provider
turn to recover an already-captured result. Unsupported/corrupt results fail
closed for review. A verdict also requires the original request to still belong
to this task and run, and its terminal transition to be accepted. Missing or
superseded ownership cannot release downstream work.

Chained work is released only from a saved verdict, using a stable child ID.
Schedule routing records its consumed intent with the schedule result so repeated
startup dispatch cannot publish it twice. Approved-plan checkpoints and final
contracts run before either effect becomes eligible. Permission continuations
preserve the original budget, validation command, resource claims and launch
settings; newly approved authority is additive.

A native live waiter and its durable approval card are published in the same
main-actor turn after earlier stream events drain. A failed card save denies the
waiter and restores the request state. This closes the admission race between a
live response and a relaunch.

Regression coverage includes reopening the store between capture and verdict,
failed capture/verdict saves, known unwritten and uncertain written responses,
ordinary/plan completion ordering, missing plan outputs after restart, immutable
continuation settings, rejected request ownership, and idempotent chained/scheduled dispatch. Real local
provider-process scenarios verify the stdout/event-queue integration.
