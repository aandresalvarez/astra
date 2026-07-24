# RunBroker application control plane

## Root cause

Long-running execution ownership previously ended at the ASTRA process
boundary. Closing or replacing the app could leave useful provider work alive,
but the app-local owner, completion path, cancellation authority, and UI
projection cursor disappeared together. Reconstructing that state from a PID,
an app callback, or an endpoint response cache would create a second source of
truth and would be unsafe across app updates and runtime changes.

The fix is a durable process boundary:

```text
ASTRA client -> authenticated bounded IPC -> RunBroker -> RunLedger
                                             |             |
                                             v             v
                                       RunSupervisor   pull/ack outbox
```

RunBroker is the sole composition root. One `RunLedger` instance owns
admission, execution status, monitoring schedules, cancellation audit, and the
projection outbox. The app does not import `RunBrokerService` or
`ASTRARunLedger`, and the broker does not import SwiftData or UI code.

## Application protocol

Protocol v2 adds strict authenticated commands for:

- durable start;
- reconciliation and status;
- pull-next projection and exact acknowledgement;
- external-operation observation assessment and control.

Starts and control effects use the request idempotency key at a durable ledger
boundary. Projection acknowledgement uses its exact durable `(sequence,
messageID)` cursor identity. The endpoint response cache is limited to safe
read commands and never decides whether a launch, acknowledgement, or
cancellation effect is replayed.
Unknown JSON fields fail closed. Per-field bounds are checked after MAC
authentication and before service dispatch. A protocol mismatch returns the
typed `update_required` error; there is no local execution fallback and no
automatic install.

`RunBrokerExecutionID.rawValue` must exactly equal the app's `TaskRun.id` at
the start contract. This prevents an app projection from inventing a second
identifier for the same execution.

Raw launch arguments and environment values exist only in the authenticated
request and the in-memory supervisor bootstrap. They are never returned,
logged, projected, or persisted. The capability vault stores only a keyed
authenticator over the complete launch material. A retry with changed secret
values therefore conflicts before spawn without exposing those values.

An exact start replay first authenticates supervisor presence. Existing live
or offline evidence is reconciled without respawn. Spawn is resumed only when
the trusted execution directory is absent, which proves spawn did not begin.
An existing but unauthenticated directory becomes `in_doubt`; PID discovery is
never a recovery authority.

## Projection delivery

The broker never calls an app projector. The app pulls exactly the next outbox
message, commits its SwiftData transaction and durable message-ID dedupe, then
sends a separate exact `(sequence, messageID)` acknowledgement. A crash before
acknowledgement replays the same message after either process restarts. A wrong
or skipping acknowledgement fails closed.

## External operations

Only broker-owned `RunBrokerService` code can invoke the provenance verifier;
the verifier protocol and the verified-decision builder are internal to that
module. `ASTRACore` accepts only untrusted descriptors and therefore cannot
mint an allowed observation or destructive-control decision. The initial
control matrix is:

| Backend | Observe | Graceful cancel | Immediate termination |
| --- | --- | --- | --- |
| Exact local RunSupervisor | yes | not advertised | yes, authenticated and audited |
| Managed Docker | descriptor only; unverified | no | no |
| SSH remote | descriptor only; unverified | no | no |
| Imported or opaque | descriptor only; unverified | no | no |

Immediate termination appends the durable cancellation audit before the
supervisor effect. A response-lost retry ignores its later wall clock,
reconciles the supervisor's pre-effect durable `cancellation_requested` event,
and does not issue termination twice. A crash after audit but before the
supervisor request safely resumes the effect. Graceful cancellation remains
false in capabilities until a real safe-checkpoint continuation is wired; it
is never silently escalated to immediate termination. Capability flags come
from the composed effect owner, so merely installing an application handler
cannot over-advertise destructive control.

## Pure application-client target

The current PR deliberately keeps ASTRA from importing `RunBrokerKit`, because
that target also owns broker endpoint, scheduler, installation, and ledger
adapters. Before ASTRA activation, extract a `RunBrokerClient` target containing
only the authenticated application wire contracts, strict codec, response
validation, socket connector, and a read-only capability-credential loader. Its
dependency graph must be `ASTRA -> RunBrokerClient -> ASTRACore`; it must not
depend on `RunBrokerKit`, `RunBrokerService`, `ASTRARunLedger`, installer code,
or broker mutation services. `RunBrokerKit` and `RunBrokerService` may depend on
the client contracts, never the reverse. Architecture fitness tests must parse
the package target graph and app imports so comments, import modifiers, module
aliases, or indirect target dependencies cannot bypass this boundary.

## Rollout and runtime-switch seam

This change composes the real broker process but does not install, reload, or
activate a LaunchAgent and does not change ASTRA startup. The rollout remains
dormant.

PR9's runtime-switch contract plugs into the single
`RunBrokerApplicationCommand` / `RunBrokerApplicationCommandHandling` seam.
Its command must carry the exact execution, authority, configuration revision,
request ID, and checkpoint fence. The service must durably commit that intent
before dispatch, re-check the fence at effect time, and return a typed blocked
result when continuation is unsupported. Adding this command changes the wire
contract and must be composed before final protocol publication (or use the
next protocol version); it must not be added as an app-local side channel.
