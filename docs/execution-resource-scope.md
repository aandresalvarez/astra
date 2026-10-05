# Accepted execution resource scope

`TaskTurnRequest.executionPolicySnapshot.resourceScope` owns the versioned
filesystem authority accepted for a turn. `resourceClaimsJSON` remains a
compatibility projection; requests with a scope derive their claims from the
scope, not that independently decodable column. `AgentTask.acceptedResourceScope`
is transient and populated only on detached launch views. Editing the live task
does not edit an accepted scope.

The scope records original paths, canonical identities, access and provenance:
execution root, additional folder, task storage, input, Git metadata, environment
mount, and copy-isolation source. Admission, native directory arguments, runtime
grants, Docker mounts and folder guidance consume these projections. Launch
rejects changed canonical identities, a changed execution root, or unadmitted
task-data write grants. Credential visibility is still owned by the existing
credential projection services: claiming a container credential mount does not
make it a native provider directory.

## Worktrees and folders

A pinned linked worktree replaces an inherited additional **repository root**
only when both resolve to the same Git common directory. Other repositories,
subdirectories and ordinary shared folders retain their access and claims.
An explicitly required shared source write can be retained with the task
constraint `ASTRA_RESOURCE_WRITE_PATH=/absolute/source/path`; it intentionally
restores contention. The primary workspace is not implicitly granted writable
merely because it stores ASTRA tasks.

Task storage has a separate filesystem claim. Its writes remain task-owned even
for read-only execution. A broad workspace reader does not lease sibling runtime
ledgers; a reader explicitly targeting a ledger and any overlapping writer still
conflict. This exception does not apply to arbitrary additional folders or Git
metadata. Execution folders do not become writable merely because their task's
output folder is writable.

## Git and hooks

Git metadata is read-only by default, including when Git inspection is discovered
only in runtime context. Inspection uses `GIT_OPTIONAL_LOCKS=0`; the host boundary
protects metadata from writes and Docker overlays metadata read-only under a
writable checkout mount. Native credential routing remains separate: GitHub
host-control routing does not implicitly expose native network credentials.

Accepted Git mutation intent, branch preparation and test validation conservatively
claim shared metadata exclusively. This is not authorization to run a command:
the existing permission policy still applies. Arbitrary provider Git mutations
are **not** operation-leased yet. They retain their turn-long exclusive lease;
do not relax it without a service boundary that also prevents uncoordinated
provider writes. Runtime context cannot upgrade a metadata reader into a writer;
submit a new turn with the required operation.

Claude receives template hooks and subagent permissions through its launch
`--settings` JSON, on both initial and continuation launches. ASTRA no longer
injects/restores workspace `.claude/settings.local.json`. Invalid hook
configuration blocks launch. Other providers do not inject Claude hooks.

## Continuation, drift and compatibility

Initial turns, follow-ups, retries, schedules and plan requests capture the scope
at the durable submission boundary. Permission continuations preserve the
originating scope and add explicitly approved sandbox input paths to their new
request. They enter admission with their new sequence and submission time rather
than acquiring extra resources while retaining the old lease.

Live additional-folder edits do not alter the frozen scope. Moving the owning
workspace, retargeting a selected symlink, or launching at a different execution
root requires resubmission. A missing pinned root never falls back to the source
checkout for an accepted request. Copy isolation claims its source and
deterministically selected destination before copying.

Queued requests written before scopes existed, and malformed or unsupported
scopes, fail with `execution_resource_scope_requires_resubmission`. Their source
events and request records are retained; the user can submit a new turn. They
are not silently rebuilt from today's mutable folder settings. Existing recovery
and per-resource FIFO ordering are unchanged. Explicit sandbox Off retains the
existing exclusive-reader fallback and does not secretly enable confinement.

## Remaining resource contracts

Concrete Docker mounts, including writable credential mounts, participate in
filesystem admission rather than an environment-wide Docker lock. Container
instances and Docker client configuration remain task/run scoped.

Browser bridge binding, remote directory/SSH state and provider-owned account
state still require explicit isolation/coordination decisions tracked in
[issue #480](https://github.com/aandresalvarez/astra/issues/480). The coverage
ratchet retains those gaps rather than assuming that provider-wide locks are
necessary or that production collisions have occurred. Provider caches and OS
temporary directories remain runtime support resources, not a promise that
arbitrary task data placed there is isolated.
