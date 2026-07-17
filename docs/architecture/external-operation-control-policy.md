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

The existing execution reducer correctly separates observed state from desired
state, but it accepts an already-resolved capability set. A provider-neutral
admission policy is therefore required before any adapter sends a cancellation
effect.

## First principles

1. Observation and cancellation are independent capabilities. Neither implies
   the other.
2. Cancellation requires exact execution ID, fenced authority, and backend
   identity. There is no search, adoption, or local fallback.
3. Destructive control additionally requires a trusted adapter to have verified
   an ASTRA-owned, authenticated, execution-scoped handle.
4. PIDs and peer user IDs are diagnostic evidence only. They are reusable and
   are not part of the control contract.
5. Unknown schema fields, versions, capability bits, backend kinds, stale
   identities, and capability overclaims fail closed with typed reasons.
6. A cancellation request records intent; only authenticated backend evidence
   may confirm cancellation.

## Initial backend matrix

| Backend | Observe | Cancel | Why |
| --- | --- | --- | --- |
| Local RunSupervisor | Declared independently | First class | ASTRA owns the capability-authenticated execution supervisor |
| ASTRA-managed Docker job | Declared independently | First class | The managed-job receipt and scoped adapter bind the exact job to the execution |
| SSH / remote operation | Monitoring only | Not released | A reviewed remote helper, scoped credential, and permission contract do not exist yet |
| Imported operation | Monitoring only | Not released | Imported identity is not ownership authority |
| Opaque operation | Monitoring only | Not released | The backend cannot prove a safe destructive target |
| Unknown future backend | Declared observation may be used | Blocked | Cancellation needs an explicit policy and adapter review |

For a monitoring-only backend, advertising cancellation is a capability
overclaim and is blocked rather than silently downgraded. For a first-class
backend, a missing authenticated ownership proof or missing cancellation bit is
also blocked. This makes integration mistakes visible instead of selecting a
different control path.

## Contract boundary

`ExternalOperationControlBinding` is durable evidence produced by a trusted
adapter. `ExternalOperationControlTarget` is the caller's exact expected target.
Both are strict, versioned wire contracts. The pure
`ExternalOperationControlPolicy` returns separate observation and cancellation
decisions with `allowed`, `monitoring_only`, or `blocked` kinds and deterministic
reasons.

The binding carries only stable execution, authority, backend identity,
ownership evidence, and declared capability bits. It deliberately carries no
PID, raw credential, socket capability, command, host path, or secret.

## Remaining wiring

- The broker integration must mint bindings only after authenticating the local
  supervisor capability or the managed Docker start receipt, and it must apply
  the policy before enqueueing a cancellation effect.
- Monitoring adapters must map SSH/imported/opaque observations without
  manufacturing cancellation ownership.
- Rollout UI and diagnostics must surface the typed reason and present
  monitoring-only state without a destructive control.
- A future SSH cancellation release needs a separate reviewed remote-helper,
  credential-scope, permission, idempotency, and terminal-evidence contract.
