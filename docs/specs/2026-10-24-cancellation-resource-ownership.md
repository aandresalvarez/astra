# Cancellation and shared resource ownership

Cancel stops the task and its scoped processes. It does not prove that escaped tools, remote jobs, or a lost transport stopped. The execution owner's protected journal remains the authority for releasing the resources admitted to that execution.

## Admission and release

Each admission records its exact workspace and Git claims, with a unique lease generation. A short store-wide kernel lock covers conflict inspection and journal publication; the per-task kernel lock remains held through execution and settlement. The queue derives its resource view from these journals after startup and before admission.

Every execution release requires full termination proof: matching execution/process identity, reaped child, empty process group, recognized tool-free terminal stream, complete stdout EOF, and no uncertain remote work or unfinished validation. This applies to normal completion, limits, cancellation, Retry and explicit follow-ups. A visible result does not release uncertain tool ownership. OpenCode additionally requires a last stop step followed by a natural zero exit; a stop request cannot promote its provisional step to completion.

A cancellation inspection runs after 30 seconds. If the exact owner already has full proof, it may retire a provider wait that has not returned. The worker then performs normal cleanup, restores template hooks and saves resource release before the queue admits another writer. That worker and runner are replaced. Late output, permission callbacks and supervisor reports cannot mutate the task or release a successor's lease.

Without proof, the inspection records that cleanup remains unconfirmed. Workspace claims stay reserved after a normal callback return, Stop Queue, or app restart. Other tasks see the holding task's name and the reason for waiting. Stop Queue still cancels parked admissions; it does not clear unresolved ownership.

## Provider settings

Provider settings have an additional kernel lock keyed to the actual settings path. It serializes live writers across separate ASTRA instances. Under that lock, owned task and validation launches read a protected reference to the previous execution journal, verify its release or admitted same-task handoff, bind the new owner's key, and persist the reference before changing settings.

References live in `~/Library/Application Support/ASTRA Runtime Coordination/provider-state`. They contain journal locations and owner identifiers, not independent stop proofs. Missing, corrupt or unresolved referenced authority blocks acquisition. A current same-task successor can replace the reference only after the task's normal durable admission has verified its predecessor. Cancellation while waiting does not claim settings that the waiter never acquired.

Validation utilities inherit the settlement owner. Utilities outside a task settlement share live kernel serialization but do not gain task-level crash recovery ownership from this change.

## Settlement and observability

Cancellation closes the settlement scope, terminates registered children and rejects later launches. Validation results returning after cancellation do not become test failures, corrective steps, or completion events. Cancellation wins again when committing the durable run/request outcome.

A missing legacy journal with an ownership audit but no reconstructable resource claims blocks admission conservatively. There is no timer-based override or model-authorized release. Detached or remote work without a reliable termination attestation remains blocked; this change does not claim to solve universal remote cleanup.

## Acceptance

Regression coverage exercises verified retirement, late returns, uncertain tools, Stop Queue, disk reopen, missing and legacy receipts, failed release persistence, provider-gate handoffs, cancellation while waiting, cross-store journal references, permission callbacks and cancellation during plan and ordinary validation. Native acceptance uses a fresh development bundle/store and synthetic workspaces with a real provider. The PR records the final checks and observed outcomes.
