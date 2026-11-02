# Workspace consultations

The composer offers **Work** and **Consult** for tasks with a workspace. Work
keeps the existing exclusive writer/stable reader policy. Consult is an explicit
read-only observation: it can read workspace files while another task changes
them. It does not promise a consistent snapshot across files or across reads.

The selected mode is stored in the task's existing constraints as
`ASTRA_RESOURCE_ACCESS=read_only` plus `ASTRA_WORKSPACE_CONSULTATION=live`.
Keeping the established access declaration means older builds also recognize
the read-only intent for future turns and apply their existing stable-reader
policy. The submission service freezes a shared
workspace claim with `readConsistency: live` in the durable turn request. Editing
the task later cannot change that accepted request. The mode cannot be changed
while a task is queued or running. Switch back to Work before asking the task
to implement changes; the question's wording does not silently widen access.

Live readers bypass workspace writer contention and workspace FIFO contention.
They do not bypass worker capacity, native session ownership, Git metadata,
account, browser, Docker, or remote resource conflicts. Existing shared readers
without the live marker still wait for a writer. Duplicate claims normalize to
the strongest access and consistency requested.

The launch receives the existing shared-workspace filesystem contract: workspace
roots are readable, the required host boundary is enforced, and the task's own
output directory remains writable. Docker workspaces use the existing read-only
mount path. If sandbox enforcement is Off, admission upgrades the request to a
writer and preserves serialization; consultation launch then fails closed with
an actionable diagnostic rather than granting the provider write access. Branch
operations, test validation, and template-hook injection also retain exclusive
admission and cannot launch a consultation until those settings are removed.
The consultation guidance
asks the provider to answer without making remote or connected-service changes;
this feature does not introduce a separate sandbox for those external systems.

Optional JSON consistency fields preserve old request and owner-receipt
decoding. Missing fields keep stable-reader behavior, and older builds ignore
the new fields and conservatively serialize readers with writers. Protected
owner receipts preserve the live-read marker through continuation; release and
uncertain-execution rules are unchanged.

`WorkspaceConsultationTests` covers writer overlap, read-only launch grants,
FIFO admission, sandbox Off, intrinsic writes, immutable submitted claims,
legacy JSON, resource-kind limits, normalization, and saved selection. The
existing `SharedWorkspaceExecutionBoundaryTests` exercises kernel write denial
and the task-output exception. These checks are not evidence of six-provider
native concurrency or of remote service mutation isolation.
