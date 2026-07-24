# External Operation Control Policy

Status: policy contracts implemented; backend adapters and UI wiring remain in
the broker migration and rollout PRs.

## Root cause

An operation being visible does not prove that ASTRA can safely stop it. A
status endpoint, imported job identifier, SSH process ID, or same-user process
can support observation while providing no authenticated, execution-scoped
authority for destructive control. Treating a generic `cancel` declaration as
authority would let an imported, stale, or future backend opt itself into a
destructive operation.

Authentication also cannot be represented by a Codable ownership enum. Any
field that crosses IPC or durable storage is caller-controlled after decode. A
matching descriptor is therefore necessary for targeting but insufficient for
authorization.

The existing execution reducer correctly separates observed state from desired
state, but it accepts an already-resolved capability set. A provider-neutral
admission policy is therefore required before any adapter sends a cancellation
effect.

## First principles

1. Observation and cancellation are independent capabilities. Neither implies
   the other.
2. Cancellation requires exact execution ID, fenced authority, and backend
   identity. There is no search, adoption, or local fallback.
3. Destructive control additionally requires non-Codable evidence minted by the
   package-trusted verifier after it authenticates the execution-scoped handle.
   A decoded descriptor can never self-attest this provenance.
4. PIDs and peer user IDs are diagnostic evidence only. They are reusable and
   are not part of the control contract.
5. Unknown schema fields, versions, capability bits, backend kinds, stale
   identities, and capability overclaims fail closed with typed reasons.
6. Graceful cancellation and immediate termination are different capabilities.
   Immediate support never escalates or substitutes for unsupported graceful
   cancellation, and every admitted immediate action requires an audit record.
7. A cancellation request records intent; only authenticated backend evidence
   may confirm cancellation.

## Initial backend matrix

| Backend | Observe | Cancel | Why |
| --- | --- | --- | --- |
| Local RunSupervisor | Declared independently | Immediate is first class; graceful only when explicitly verified | The verifier authenticates the capability and full installation/store/execution/authority identity |
| ASTRA-managed Docker job | Monitoring only | Not released | Current receipts are deterministic and not MACed, identity is mutable-name scoped, and cancellation does not yet prove command or terminal outcome |
| SSH / remote operation | Monitoring only | Not released | A reviewed remote helper, scoped credential, and permission contract do not exist yet |
| Imported operation | Monitoring only | Not released | Imported identity is not ownership authority |
| Opaque operation | Monitoring only | Not released | The backend cannot prove a safe destructive target |
| Unknown future backend | Declared observation may be used | Blocked | Cancellation needs an explicit policy and adapter review |

For a monitoring-only backend, advertising graceful or immediate control is a
capability overclaim and is blocked rather than silently downgraded. Docker can
be promoted only after it has an authenticated receipt, immutable engine and
container identity, checked cancellation command result, and authoritative
terminal confirmation. For the local supervisor, missing verifier evidence or
the exact requested capability is blocked. This makes integration mistakes
visible instead of selecting a different control path.

## Contract boundary

`ExternalOperationControlBinding` is an untrusted capability descriptor, and
`ExternalOperationControlTarget` is the caller's exact expected target. Both are
strict, versioned wire contracts. A local supervisor descriptor carries the
complete typed installation, store, execution, and fenced-authority identity;
an alias cannot enter that wire shape. The pure
`ExternalOperationControlPolicy` returns separate observation and cancellation
decisions with `allowed`, `monitoring_only`, or `blocked` kinds and deterministic
reasons.

The binding carries only stable identities and declared capability bits. It
deliberately carries no ownership assertion, PID, raw credential, socket
capability, command, host path, or secret. Only
`ExternalOperationControlProvenanceVerifier` can mint
`ExternalOperationVerifiedEvidence`; that evidence is in-memory, non-Codable,
bound to the exact target and binding, and has no public initializer.

## Remaining wiring

- The broker integration must implement the package-trusted authenticator for
  the local supervisor capability, mint verified evidence, apply this policy,
  and durably record the required immediate-termination audit before enqueueing
  the effect. The app must never supply a verifier or verified evidence.
- Managed Docker stays monitoring-only until its receipt, immutable identity,
  cancellation result, and terminal evidence satisfy the release criteria.
- Monitoring adapters must map SSH/imported/opaque observations without
  manufacturing verified cancellation provenance.
- Rollout UI and diagnostics must surface the typed reason and present
  monitoring-only state without a destructive control.
- A future SSH cancellation release needs a separate reviewed remote-helper,
  credential-scope, permission, idempotency, and terminal-evidence contract.
