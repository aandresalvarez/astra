# Runtime Selection and Active-Run Switching

## Root cause

A runtime picker is preference for a future execution. An active execution is
owned by an immutable launch manifest, a broker-issued execution ID, fenced
authority, and a durable ledger. Treating both concepts as one mutable
"selected runtime" value creates three failures:

1. A harmless preference edit can become process control.
2. App or client observations can be mistaken for execution authority.
3. A crash between cancellation and relaunch can duplicate effects or launch a
   replacement while the old execution is still alive.

ASTRA therefore keeps the PR3 `ExecutionRuntimeIntentState` as the only picker
owner. Selecting a runtime changes only its `nextRuntimeID`; active truth stays
ledger-derived. Runtime switching is a separate broker workflow. This PR does
not add a second picker state or activate switching in production.

## Trust boundary

The public request is strict, versioned, and untrusted. It carries:

- a stable request ID and explicit `graceful` or `immediate` mode;
- the expected installation, store, execution, task, authority, source
  manifest digest, and source configuration revision;
- a fully resolved immutable replacement manifest and its digest; and
- a bounded timestamp plus typed force audit fields when applicable.

It carries no PID, generic support flag, checkpoint claim, cancellation
receipt, force token, or fallback runtime.

The replacement manifest is revalidated at this boundary rather than trusting
the more permissive shared launch decoder. Manifest, configuration, authority,
argument-summary, effect-claim, and effect-scope shapes reject unknown fields;
configuration normalization must round-trip identically. Runtime/configuration
strings and every effect-scope identifier/path are bounded, unknown or malformed
effect scopes are rejected, and the canonical encoded manifest is capped at one
MiB.

`VerifiedRuntimeSwitch*` values and the reducer live in the separate
`RunBrokerPolicy` target. They are non-Codable and have package-only
initializers, but package access alone is not treated as a trust boundary:
application, UI, model, persistence, and executable/tool targets have no
dependency on this module and therefore cannot name or construct its evidence.
Architecture fitness parses SwiftPM target dependencies and source-aware import
forms to preserve that boundary. Only `RunBrokerService` and dedicated policy
or service tests may depend on the target; a broker executable must compose
through the service. The service must build attestations from canonical ledger
state, authenticated supervisor IPC, and the verified external-operation
capability boundary. Decoding a client payload can never create verified
evidence.

Safe-checkpoint proof is pair-specific. It binds installation, store,
execution, authority, source and target manifest digests, checkpoint generation,
ledger sequence, effect and tool watermarks, provider continuation adapter
version, and the supervisor's full identity, protocol version, and cohort. Both
in-flight counts must be zero. A generic `supported` bit is insufficient.

Admission also carries a durable target-reservation witness. It binds the
request and digest, installation, store, task, replacement execution ID, target
manifest digest, and its ledger sequence. The reservation must causally follow
the source observation and is preserved unchanged through replacement dispatch,
acceptance, running evidence, and completion archival.

## Durable state machine

```text
graceful request --> waiting_for_checkpoint --trusted checkpoint/CAS--+
                                                               |
force request ----> confirmation_required --verified challenge-+
                                                               v
                                                   control_dispatch_pending
                                                               |
                                                 authenticated backend accept
                                                               v
                                                   awaiting_source_terminal
                                                               |
                                           exact authoritative terminal event
                                                               v
                                                replacement_dispatch_pending
                                                               |
                                                target launch accepted
                                                               v
                                             awaiting_replacement_running
                                                               |
                                                target running evidence
                                                               v
                                                          completed
                                                               |
                                                   exact archival CAS
                                                               v
                                                           archived
                                                               |
                                                       next request
```

An offline or indeterminate source moves to `in_doubt`; it never advances to a
replacement launch. Cancellation pending or terminating is a concurrent owner
and blocks new control intent.

The request reducer never returns a process command. An exact client replay is
observation-only: it returns the same durable state and no new effect. Same ID
with changed content is a conflict, and another request cannot steal the one
pending slot for an execution. Completion archival preserves the full immutable
request and digest, so those exact replay rules continue after the active slot
is cleared. A later switch requires a distinct reservation whose ledger
sequence is newer than the prior archive.

At a trusted checkpoint or verified force confirmation, one ledger CAS records
both the transition and an outbox effect with a stable effect ID. The outbox is
the only dispatcher. Immediately before each send it rechecks the exact current
execution, authority, manifest, lifecycle, cancellation state, backend
capability, and (for graceful handoff) checkpoint generation and watermarks.
The supervisor must atomically apply `handoffIf(exactFence, effectID)` and
deduplicate the effect ID. A crash before send or after send-before-ack safely
retries the same directive; client replay never drives that retry.

Immediate termination is a distinct action. Its ledger-stored challenge is
bound to the canonical full request digest, authenticated actor and session,
typed audit ID/source/reason, source fence, target manifest, issue time, and a
maximum five-minute expiry. Broker verification produces a single-use,
non-Codable confirmation. The resulting control effect always carries
`ExecutionCancellationIntent.immediate` and requires separately verified
immediate backend authority. Graceful authority cannot satisfy it, and a
graceful request never escalates itself.

## Terminal and launch rule

Cancellation request or backend acceptance is not terminal evidence. The
replacement outbox entry can be created only after an authoritative
`completed`, `failed`, or `cancelled` observation for the exact old source
fence that causally follows authenticated acceptance of this switch's control
effect. A natural terminal event seen before control acceptance does not resume
or replace the run. Offline, stale, or `in_doubt` evidence cannot launch
anything.

The replacement uses the already resolved manifest with a new immutable
execution ID. Dispatch is idempotent by its own stable effect ID. The switch is
reported `completed` only after authenticated running evidence for that exact
new execution, reservation, and target manifest digest. Durable decoding
enforces the ledger order `source < reservation < checkpoint` (for graceful
handoff) `< control acceptance < source terminal < replacement acceptance <
target running < archive`; skipped or reordered phases fail closed. A completed
record releases the active slot only after the broker archives that exact
completion with a later CAS witness.

## Integration requirements

The RunBroker wiring PR must make each state/effect transition one ledger CAS
transaction, store challenges and single-use consumption durably, route effects
through its outbox, and obtain terminal/running evidence from the canonical
supervisor event stream. `RunBrokerService` will be the only production target
that imports `RunBrokerPolicy`; broker tools call the service rather than the
policy. There must be no temporary "try broker, then launch locally" path and no
automatic production migration in this policy PR.
