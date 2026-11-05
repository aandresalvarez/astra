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

Quick tasks and tasks created from a specification re-read the current composer's
mode before checkout preparation and again after it finishes. The final read and
initial request submission happen in one synchronous MainActor segment. A saved
draft supplies the mode across windows; a new unsaved composer supplies its local
selection. Work preparation already admitted may finish, and the new request uses
the mode current at submission. Accepted requests keep their frozen mode.

Template execution requires **Work**, including templates with before or after
phases. Consult reports "Choose Work" before preparing a checkout or creating
phase tasks. The queued action checks again before preparation, and the template
service checks the fresh composer selection afterward, before allocating tasks or
submitting work. Composer intent is separate from checkout inheritance: a new
explicit Work action can reuse an existing Consult task's checkout.

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
operations, test validation, template-hook injection, and approved-plan command
assertions also retain exclusive admission. A gate checks the frozen Consult
intent before hooks, branch preparation, or plan artifact preparation run.
Command-bearing plans are rejected in Consult, including final-only validation
after their last step is done; switch to Work to execute them. The resource
resolver retains a second check at provider launch. Final validation checks the
originating request again if a plan update adds a command during the turn.
The consultation guidance
asks the provider to answer without making remote or connected-service changes;
this feature does not introduce a separate sandbox for those external systems.
That guidance remains in both native-resume and fresh fallback prompts.

Consult does not infer file ownership from workspace-wide before/after changes
or modification-time scans: those changes may belong to a concurrent writer.
Later output discovery resolves the same durable request, including its source
event when recovery has cleared the current attempt fields. Its own task-folder
snapshots still record outputs created during the answer.

Optional JSON consistency fields preserve old request and owner-receipt
decoding. Missing fields keep stable-reader behavior, and older builds ignore
the new fields and conservatively serialize readers with writers. Protected
owner receipts preserve the live-read marker through continuation; release and
uncertain-execution rules are unchanged.

`WorkspaceConsultationTests` covers writer overlap, read-only launch grants,
FIFO admission, sandbox Off, intrinsic writes, immutable submitted claims,
legacy JSON, resource-kind limits, normalization, and saved selection. The
`WorkspaceConsultationRuntimeTests` suite uses fake providers and temporary Git
repositories to exercise rejection before preparation, command-plan admission
and final validation, concurrent writer attribution, task outputs, and native
resume prompts. `WorkspaceConsultationSubmissionTests` covers template rejection
before task/request allocation, Work reuse of a Consult checkout, and queued or
preparation-time mode changes in quick/spec creation. Worktree tests also check
that completed Work preparation can feed a new Consult request. The
existing `SharedWorkspaceExecutionBoundaryTests` exercises kernel write denial
and the task-output exception. These checks are not evidence of six-provider
native concurrency or of remote service mutation isolation.
