# The Run Boundary

This note documents the filesystem authority of a single agent run: who derives
it, which enforcement tier reads it, and the invariants that keep the tiers from
disagreeing. The owning type is `RunBoundary`
(`Astra/Services/Runtime/RunBoundary.swift`).

## The failure this exists to prevent

An Auto-mode task with the OS sandbox switched off was stopped on its very first
tool call. The call was a `Read` of
`~/.claude/projects/<slug>/memory/MEMORY.md` — the provider CLI's own memory
index, which it opens before doing anything else.

Three defects stacked to produce that outcome:

1. `AgentRuntimeHomeStateAccess` declares `~/.claude` provider-owned state and
   `ExecutionSandbox.providerStateRoots` grants it. `AgentRuntimePolicyGuard`
   had never heard of it. Those two tiers are **inversely activated** — the
   brokered guard is what remains when the sandbox is turned off — so a root
   declared in only one tier becomes invisible exactly when it is the only tier
   running.
2. The out-of-boundary read was a *terminal* violation. Nothing at the provider
   tier had told the agent a read boundary existed (ASTRA renders read
   permission unqualified, because no provider CLI scopes reads the way it
   scopes writes), and by the time the violation was parsed out of the stream
   the read had already completed. The run was killed for a rule it was never
   given, to prevent something that had already happened.
3. The user had approved a credential prompt earlier in the task. That approval
   carried `permissionPolicyOverride: .restricted`, which demoted the run from
   Auto to `review` — switching the brokered tier back on for a task whose
   picker still read "Auto", with nothing anywhere saying so.

Each defect alone is survivable. Together they turn a routine read into a dead
session with a misleading explanation.

## Invariants

**1. One boundary, derived once, read by every tier.**
`RunBoundary` is the only place a run's readable and writable roots are
computed. `RunBoundary(manifest:plan:)` takes its provider-state contract from
`plan.sandboxHomeStateAccess` — the same artifact `ExecutionSandbox` consumes —
so a runtime cannot declare state to one tier and stay invisible to the other.
Adding a root reaches every tier at once. `RunBoundaryFirstPrinciplesTests`
asserts this per registered runtime.

**2. Provider-private state is not task data.**
The CLI's own memory, session, auth, and config bookkeeping under the run's HOME
(`~/.claude`, `~/.codex`, `~/.cursor`, …) is readable *and* writable. The
provider wrote it and the provider owns it. Treating it as "outside the
workspace" makes ASTRA punish a provider for using itself. Only the
*inherited* relative paths count: the `explicit` set additionally covers generic
caches ASTRA provisions inside a managed HOME, which are not
provider-identifying and must not widen an unsandboxed run.

**3. A denial is a tool result, not a process death.**
An out-of-boundary **read** is `requiresApproval` with category
`out_of_boundary_read` and a `.sandboxPath(access: "read")` request. With a live
control channel the provider is told "no" as a tool result and keeps working;
without one the user gets an approval card whose grant widens
`additionalReadOnlyPaths` on the retry, so the retry can actually succeed. An
out-of-boundary **write** stays terminal — those are integrity events, and the
write boundary *is* declared to the provider.

**4. An approval adds authority; it never subtracts it.**
`AgentRuntimeExecutionPolicy.approvedRuntimePermission` passes
`permissionPolicyOverride: nil`, and `AgentPolicyManifestService` unions the
approval's tools onto the run's resolved tool set instead of substituting them.
Saying yes to one prompt cannot narrow the run, change its enforcement tier, or
re-enter a stricter policy. The `TaskPolicyStore.resolve` execution cap now only
catches an *explicit* restrictive override — a launch that deliberately asked
for less.

**5. Effective authority is visible wherever it differs from what was selected.**
When a run resolves to a level other than the task's selection, the manifest
carries a `policy.effective-level-differs` diagnostic and the launch audit
records `selected_policy_level` alongside `policy_level`. Diagnosing the
original incident required reading the SQLite store; it should have required
looking at the run.

**6. Live and post-hoc evaluation see the same input.**
`AgentRuntimePolicyGuard.disposition(toolName:command:path:)` routes through the
same `validateObservedAction` the stream guard uses, and the Claude control
request's `file_path` is threaded through
`AgentInteractiveAskRequest.pathText` into the classifier. Before this, a live
ask carried only the tool name, so a file tool could be waved through live and
flagged out-of-boundary from the stream a moment later — two verdicts on what
was supposed to be one decision.

## Shape

```
RunBoundary
├── workspaceRoots        read + write   workspace anchor + additionalPaths
├── readOnlyInputRoots    read           attachments, task inputs, approved reads
├── providerStateRoots    read + write   the CLI's own HOME state
└── taskOutputRoots       ASTRA-owned    derived from workspaceRoots only
```

`taskOutputRoots` derives from `workspaceRoots` alone. Deriving it from every
root would invent an ASTRA task folder inside the provider's private state.

Path questions go through `standardizedRunPath`, which translates container
paths through the plan's `ExecutionEnvironmentPathMapper`, resolves relative
paths against the workspace, and resolves symlinks through the deepest existing
ancestor so a path that does not exist yet standardizes the same way as one that
does.

## Owners

- `RunBoundary` — derivation and every containment question.
- `AgentRuntimePolicyGuard` — brokered (post-hoc stream) enforcement; holds a
  `RunBoundary` and owns no path logic of its own.
- `ExecutionSandbox` — OS (Seatbelt) enforcement; consumes the same
  `sandboxHomeStateAccess` contract from the launch plan.
- `AgentRuntimeHomeStateAccess` — each adapter's declaration of its own
  provider-owned HOME state.
- `AgentPolicyManifestService` / `TaskPolicyStore` — level resolution, tool
  union, and the effective-vs-selected diagnostic.

## Adding a runtime

Declare the CLI's HOME state in the adapter's `AgentRuntimeHomeStateAccess`.
Both tiers pick it up from there; `RunBoundaryFirstPrinciplesTests` fails if a
declared path is not reachable through the brokered boundary.
