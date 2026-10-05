# Accepted execution resource scope

`TaskTurnRequest.executionPolicySnapshot.resourceScope` owns the versioned
filesystem authority accepted for a turn. `resourceClaimsJSON` remains a
compatibility projection; requests with a scope derive their claims from the
scope, not that independently decodable column. `AgentTask.acceptedResourceScope`
is transient and populated only on detached launch views. Editing the live task
does not edit an accepted scope.

Run-bound validation, inferred discovery, plan settlement and session persistence
require an immutable `TaskExecutionContext` derived from that authority. Durable
settlement checks checkpoint/task/request ownership and scope equality before
filesystem effects. A missing or malformed scope cannot select legacy execution.
Compatibility overloads for historical unit fixtures live in tests, not production.

Version 3 records original paths, canonical identities, access and provenance:
execution root, additional folder, task storage, input, Git metadata, environment
mount, and copy-isolation source. Admission, native directory arguments, runtime
grants, Docker mounts and folder guidance consume these projections. Launch
rejects changed canonical identities, a changed execution root, or unadmitted
task-data reads or writes. Final native writable paths no longer append a
separately resolved task folder. Credential visibility is still owned by the existing
credential projection services: claiming a container credential mount does not
make it a native provider directory.

The same request also captures typed prompt inputs and the fully resolved
execution environment, including inherited settings. Prompt construction,
provider placement, and mount planning do not reread live task inputs or the
workspace's current environment. Unknown mounts are filtered from projections
and reported as launch errors, not silently accepted as read-only. Supplied
mount bindings must match accepted or deterministically generated bindings.
ASTRA-owned workspace and task-folder mounts are rebound to the selected
execution root and canonical storage destination before acceptance; custom
additional-folder mounts retain their declared paths.
Native Git configuration/credential reads remain an explicit contract of the
credential projection service, separate from task-data input embedding.

Explicit submission settles a missing environment snapshot from the workspace's
active environment before freezing the scope, including queued/imported tasks and
historical retries. Existing explicit snapshots and permission-continuation scopes
remain authoritative. The legacy direct worker path uses the same settlement rule;
the display-time Host fallback for historical tasks is not an admission decision.

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

The captured storage path is always the canonical destination, even when only
the legacy folder exists. Queue preparation checks migration success before
creating the destination, preventing an unsuccessful migration from being hidden
by an empty replacement folder.
Admission revalidates the accepted workspace and storage destination after resource
waits and before folder preparation. Workspace drift fails the retained request
with resubmission guidance, without exporting task state into the unaccepted
workspace or acquiring its resources.

The first accepted request records `task.storage.bound` alongside its request.
`TaskWorkspaceAccess` derives every task-owned folder from this durable binding;
subsequent workspace edits do not move context state, evidence, session history,
handoffs or output. Once execution starts, it remains on the accepted folders
through validation and restart recovery. Future submissions may select the edited
execution workspace while retaining the existing task-storage binding. Invalid
bindings fail explicitly; they never fall back to a live workspace path.
Settlement saves database events separately from whole-workspace mirror exports.
Conversation forks do not inherit the source's storage authority. File imports
quarantine bindings alongside runtime authority; trusted local recovery retains
them. Moving task files is an explicit import/migration operation, not a side
effect of editing the workspace path.

Copilot's native directory arguments include accepted read-only additional
folders, while the outer boundary still denies writes. Single-file inputs are
never widened to their parent directories, and replaced source checkouts remain
excluded.

Ephemeral composer inputs are materialized through the existing task-owned
storage service before submission freezes their paths. Later queue preparation
does not materialize edited live inputs into an already accepted request.
Prompt inputs distinguish prose, accepted filesystem paths, and paths unavailable
at acceptance. A missing path becoming available later does not authorize a new
read. Ordinary accepted files are read at their accepted identities, not stored
as immutable content snapshots.
Attachment arguments and the typed attachment ledger establish explicit path
identity. Ambiguous nonexistent strings such as `/health` and `~5 minutes` stay
verbatim text. Existing files in legacy string inputs retain compatibility, but
captured text is never promoted to a file on a later launch.

## Git and hooks

Git metadata includes both the common directory and each selected worktree's
`.git` entry. Linked-worktree pointer files receive the same accepted access as
their common directory, including native write denial and read-only Docker
overlays for inspection. Copy-isolated linked pointers remain read-only alongside
their external metadata.
Copy isolation from a linked worktree cannot admit Git writes: a typed requirement,
an explicit write declaration, or a workflow requiring writes is rejected at
submission with guidance to use a regular checkout or a non-copy worktree.
Scope validation also rejects older inconsistent values that advertise Git
writes while retaining read-only Git metadata.

Git metadata is read-only by default, including when Git inspection is discovered
only in runtime context. Inspection uses `GIT_OPTIONAL_LOCKS=0`; the host boundary
protects metadata from writes and Docker overlays metadata read-only under a
writable checkout mount. Native credential routing remains separate: GitHub
host-control routing does not implicitly expose native network credentials.

Explicit Git write requirements, branch preparation and test validation conservatively
claim shared metadata exclusively. This is not authorization to run a command:
the existing permission policy still applies. Arbitrary provider Git mutations
are **not** operation-leased yet. They retain their turn-long exclusive lease;
do not relax it without a service boundary that also prevents uncoordinated
provider writes. Runtime context cannot upgrade a metadata reader into a writer;
submit a new turn with the required operation.

Approved-plan requests derive Git requirements from the selected executable step in
next-step mode, or the full approved plan in full-plan mode. Later steps do not
upgrade a next-step reader. Scoped execution uses that accepted plan payload,
not a subsequently edited live plan, including final proof and required outputs.
Only progress status is projected onto the accepted plan during settlement.
Steps carry a Codable `gitAccessRequirement` (`readOnly` or `readWrite`), displayed
as **Git writes** in the plan's permission summary and editable in its Permissions
menu before approval. A read-only constraint conflicting with a write-requiring
plan is rejected rather than silently weakening either requirement.

`ASTRA_GIT_ACCESS=read_only` or `ASTRA_GIT_ACCESS=read_write` explicitly selects
the captured Git requirement. Invalid, conflicting, or workflow-incompatible
declarations are rejected. A write declaration requires write-capable execution;
branch preparation and test validation retain their conservative mutation
requirement.

Prose and regex hints no longer grant Git writes. For an unstructured turn that
needs mutations, set `ASTRA_GIT_ACCESS=read_write`, or approve a plan with the
typed Git write requirement. Wording such as "Without delay, git commit" and
"Do not git commit" cannot change the permission decision. Existing accepted
requests retain their already captured requirement; new operations require a
new admission, not an in-place lease upgrade.

Claude receives template hooks and subagent permissions through its launch
`--settings` JSON, on both initial and continuation launches. ASTRA no longer
injects/restores workspace `.claude/settings.local.json`. Invalid hook
configuration blocks launch. Other providers do not inject Claude hooks.

## Validation execution

Test commands and validation-contract commands receive the accepted scope,
including during approved-plan settlement and replay of a durable runtime
checkpoint. Writable task-data paths are projected from that scope, not from live
task settings. The command sandbox uses the same read-only denial rules as the
provider sandbox, protecting copy sources and Git metadata even beneath ambient
temporary-directory grants. Invalid scopes, mismatched roots, unadmitted writable
paths, and unavailable boundaries fail closed for scoped commands, including
best-effort sandbox mode.

Scoped Swift/Xcode commands, and Make commands detected as delegating to those
toolchains, are blocked when sandboxing is enabled: their existing outer-sandbox
exclusions cannot enforce the accepted scope. Scoped container validation is also
blocked rather than silently running its command on the host. These are explicit
unsupported paths, not passing validation or automatic permissions upgrades.
Use a supported host validation command or a compatible new execution setup.
Unscoped legacy behavior and an explicitly admitted sandbox Off remain unchanged.
Static artifact, text-content, and browser-evidence assertions share an accepted
storage projection: captured task storage first, then the accepted execution
root. Live workspace edits cannot redirect their reads or evidence writes.
Symlink escapes are rejected, and browser evidence read/write failures are
reported rather than converted to passing assertions. Inferred validation uses
the same context for discovery and evaluation, and only the contract owns its
final refresh. Invalid authority is a failed evaluation, never `notRequired`.

Scoped verifier assertions and AI utility checks currently fail before launching
a child provider: the utility adapters cannot enforce inherited filesystem read
authority. A Read/Glob/Grep allowlist or an audit-only read sandbox is not adequate
confinement. Automatic objective-assessment utility launches are likewise deferred
with a warning for scoped runs. Use deterministic assertions or supplied evidence.
Legacy unscoped utility behavior is unchanged. Main-provider read sandbox settings
are not redefined here; this is not a new whole-host confidentiality or
browser/provider-state isolation guarantee.

## Continuation, drift and compatibility

Initial turns, follow-ups, retries, schedules and plan requests capture the scope
at the durable submission boundary. Permission continuations preserve the
originating scope and add explicitly approved sandbox input paths to their new
request. They enter admission with their new sequence and submission time rather
than acquiring extra resources while retaining the old lease.
Read approvals do not automatically add file contents to the prompt; accepted
prompt inputs, environment, and Git requirement remain unchanged.
For legacy direct runs with no durable originating request at all, an explicit
permission approval creates the first scoped request through normal admission,
with a `legacy_permission_request_scope_captured` audit event. An existing request
with an absent or invalid scope is never reconstructed this way.

Live additional-folder edits do not alter the frozen scope. Moving the owning
workspace while waiting for admission, retargeting a selected symlink, or launching
at a different execution root requires resubmission. Editing a workspace during an
active run does not redirect that run's accepted folders. A missing pinned root never falls back to the source
checkout for an accepted request. Copy isolation claims its source and
deterministically selected destination before copying. Every shared resource
participates in read-only boundary selection and denial generation, including
copy sources beneath ambient writable temporary directories.
Follow-up prompts render accepted-folder guidance once, through the shared
execution-environment section, rather than duplicating it in conversation context.

Queued requests written before scopes existed, version-1 scopes lacking the
frozen input/environment contract, version-2 scopes lacking guaranteed Git pointer
protection, and malformed or unsupported
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
