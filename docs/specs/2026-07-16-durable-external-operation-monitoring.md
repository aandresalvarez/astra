# Durable External-Operation Monitoring

## Decision

ASTRA treats a long-running executor job as a task-owned control-plane
registration. The provider session and its `TaskRun` are provenance only. The
execution backend remains authoritative for the command, process identity,
logs, heartbeat, result, and cancellation mechanics.

The first vertical slice supports ASTRA-managed Docker workspace jobs. It does
not add generic remote-command execution. A future SSH backend must be
alias-scoped, separately permissioned, and expose the same typed observe/cancel
interface without persisting commands or credentials in the control plane.

## Ownership and state

`TaskExternalOperation` stores only:

- full task and originating-run identity;
- an opaque backend kind, stable external identity, and validated job ID;
- originating Context Capsule revision as provenance;
- derived execution state and independent observation health;
- durable scheduling generation, expiring lease, next-check time, and
  notification/wake deduplication keys.

It never stores a command, PID, log path, status-file path, output, or secret.
The originating `TaskRun` completes with `externalOutcomePending`; the task
enters `waitingExternal` while deterministic monitoring continues.

Execution state and observation health are independent. A missing Docker
daemon, sleeping/offline Mac, or unreachable backend changes health to
`unreachable`; it does not manufacture a failed execution. A local Docker job
is never claimed to have continued while the Mac was powered off.

## Registration and crash recovery

Provider tool-use ids and inner MCP JSON-RPC request ids are intentionally
treated as different identifier domains. The provider event recorder binds a
result to the exact observed `workspace_job_start` tool-use/result pair. The
strict structured payload then carries the inner MCP request id, and ASTRA
requires that full receipt to match the trusted backend record before creating
control-plane state. No equality assumption is made between the two protocol
ids.

`workspace_job_start` writes full task/run/invocation ownership into its
authoritative backend record before detached launch and returns a strict typed
result. Live registration requires an exact trusted tool invocation match.
Startup reconciliation scans only the task-derived trusted job root, validates
the full owner receipt, and adopts by stable external identity. This closes the
crash window between backend launch and SwiftData registration without
relaunching or duplicating the job.

Loose result text, model-provided paths, generic status/cancel commands, and
truncated task/run prefixes are never registration authority.

## Monitoring

The dedicated monitor owns polling; `TaskSchedule` and routines do not. It uses
an injected clock, backoff policy, backend observer/canceller, and wake sink.
Manual and scheduled polls share one in-flight operation. A persisted
generation and expiring lease reject stale results, and terminal execution
observations are monotonic.

Most observations are handled without an LLM. ASTRA wakes a fresh provider
session only for an ambiguous observation, process-completion validation, or
user-facing reasoning. The wake contains a bounded typed observation and
operation-specific intent. Prompt construction refreshes the latest Context
Capsule; the originating revision remains provenance and never selects stale
context.

Process exit code zero means the external process completed. It does not mark
the task successful until the validation wake succeeds.

## Lifecycle and sharing

For the local Docker backend, provider-process EOF preserves a container while
any trusted owned job is nonterminal. After an authoritative terminal record is
observed, the monitor performs a separate fail-closed idle check and stops the
task/run-scoped container only when no trusted nonterminal job remains.

Stopping monitoring changes only the control-plane registration. Cancelling
external work is a separate explicit backend action. Deleting a task or
workspace never invokes backend cancellation.

Workspace export contains only the bounded safe control-plane projection.
Every imported registration is quarantined unconditionally and cannot contact
an executor until a future explicit reactivation flow validates local
ownership.

## Follow-up phases

1. Add an alias-scoped, separately permissioned SSH observer/canceller. Do not
   add a generic SSH command API.
2. Add task UI for operation history, manual poll, stop monitoring, explicit
   cancellation confirmation, and quarantine reactivation.
3. Add OS notifications using the same durable semantic transition key; task
   events remain the in-app audit trail.
4. Add executor-specific completion validators where deterministic validation
   can replace a provider wake.
