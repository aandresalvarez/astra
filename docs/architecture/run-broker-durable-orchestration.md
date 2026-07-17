# Durable RunBroker orchestration

Status: dormant implementation (PR7); production authority migration is deferred to PR9.

## Root cause

Long executions were owned by `AgentRuntimeProcessRunner` and app-memory worker state. Closing or updating ASTRA destroyed the process owner, output pump, watchdogs, completion callback, and the only path that could update SwiftData. A detached provider could survive, but ASTRA could no longer authenticate, reconcile, or deliver its terminal truth. Runtime switching had the same ownership ambiguity.

The failure is architectural: UI-process lifetime, execution-control authority, and durable presentation state were the same thing.

## Authority and durable truth

The intended authority chain is:

```text
planner/UI -> authenticated broker IPC -> RunBrokerService -> RunSupervisor -> provider
                                      |
                                      +-> canonical RunLedger/outbox -> durable app projection -> UI
```

`RunBrokerService` depends only on `ASTRACore`, `ASTRARunLedger`, `RunSupervisorSupport`, and `RunBrokerKit`. It does not import SwiftData, models, or UI. The canonical ledger owns immutable admission, supervision policy, authenticated supervisor observations, control transitions, and the app outbox. SwiftData remains the durable app/domain projection, but is not execution-control authority.

Capability files are a separate 0600 vault only because authentication secrets must not enter the journal or app projection. They contain no lifecycle truth. Publication uses no-replace atomic rename plus file and directory synchronization.

## Atomic start and recovery

A start validates the immutable manifest, effect claims, exact store/installation/authority, argument digest, environment-name declaration, and watchdog/output policy. It then:

1. mints and synchronizes the execution capability;
2. atomically admits the manifest and primary effect claim to RunLedger;
3. spawns only the installed supervisor sibling of the running broker;
4. persists authenticated `supervisor_ready` and `provider_started` evidence;
5. derives `executionStarted`; and
6. acknowledges the supervisor only after all ledger facts are durable.

An empty replay remains `admitted`; it is never presented as running. Every crash boundary is idempotent. Reconciliation repairs a missing derived control transition from the already-durable observation before acknowledgement. Recovery uses the exact capability and either mutually authenticated live IPC or the authenticated offline spool. It never uses a PID. Missing or mismatched installation, store, execution, authority, capability, or supervisor identity becomes typed `in_doubt` state.

Hard timeout, idle/progress timeout, per-event output, and total persisted-output limits are immutable in the launch manifest. Output beyond those limits remains unacknowledged so supervisor backpressure is preserved. Logs contain execution IDs, authority epochs, event kinds, and sequence numbers only; capabilities and provider output are excluded.

## App and cancellation boundaries

The app projector acknowledges one ledger outbox message only after its SwiftData transaction and message-ID dedupe are durable. Startup reconciliation is coalesced and, when enabled, completes before legacy orphan repair and task-queue drain. PR7 leaves broker rollout dormant; dormant mode skips only broker reconciliation and preserves current legacy startup behavior. Tests and UI startup cannot install or reload a LaunchAgent.

Immediate termination accepts only an untrusted execution ID and intent from the app. A service-internal authorizer must mint the authorization. The cancellation-intent audit is committed before authenticated supervisor control. Production verifier composition will be added with PR8; no public self-approving injection point exists in this target.

There is no try-broker/local fallback. PR9 must make authority selection explicit and migrate runtime sessions only after the broker, ledger, supervisor, installer cohort, and projection gates pass.
