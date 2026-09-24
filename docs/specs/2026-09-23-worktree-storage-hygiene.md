# Worktree Storage Hygiene

Status: implemented in one PR (branch `claude/worktree-storage-hygiene-ac5a43`) · Owner: Alvaro · Date: 2026-09-23

## Problem

Every linked worktree of a SwiftPM repo builds its own `.build` scratch
directory (2.5–3.3 GB for ASTRA). Nothing ever removes it. Worktrees come from
three sources — ASTRA (`~/Documents/Astra/Worktrees/...`), Claude Code
(`<repo>/.claude/worktrees/...`) and Codex (`~/.codex/worktrees/...`) — and
they outlive the task that created them.

Observed on the owner's machine on 2026-09-23:

- The disk was at 2.5 GB free of 461 GB.
- About 27 GB of it was `.build` directories in ~10 worktrees, most idle for weeks.
- Two worktrees created on the same day (`pt-378`, `pr-379`) added 6.3 GB.
- One worktree (`zen-elbakyan-...`) was mid-build during the manual cleanup.
  Deleting its `.build` would have broken a running agent.

Manual cleanup doesn't solve it: at the current rate the disk refills in 2–3
weeks. For a product whose value is supervising coding agents, "agents silently
fill the disk" is a gap our users will hit too.

## Decision

ASTRA owns the storage lifecycle of every worktree git reports for a workspace
repository. It does two things:

1. **Reclaim build artifacts** from idle worktrees. This is automatic, on by
   default, and loses no data: artifacts regenerate on the next build.
2. **Suggest removing whole worktrees** that are merged, clean, unused and
   stale. It only suggests. Removing source is always a user action that goes
   through the existing `GitService.removeWorktree`, which already refuses
   dirty trees.

Scope comes from `git worktree list`, which `GitService.listWorktrees` already
parses. So worktrees made by Claude Code and Codex are covered with no extra
discovery code.

## Non-goals

- **Sharing one `.build` across worktrees.** SwiftPM locks the scratch directory
  while it builds, so parallel agents would serialize. That defeats the task
  fork model (see
  `docs/specs/2026-07-22-multithread-resource-and-lifecycle-architecture.md`).
- **Cleaning directories git doesn't list as worktrees** (orphaned copies,
  unregistered folders).
- **Running `git worktree prune` automatically.** It runs against whatever path
  view the process has. Leave it to explicit user action.
- **Deleting `dist/`** or anything that may hold a runnable `.app`.
- **Global caches** (`~/Library/Caches`, `~/.cache`, and so on).

## Design

Keep each piece small, with one owner per behavior (see `AGENTS.md` →
Architecture Principles). Suggested files:

```text
Astra/Services/Git/WorktreeStorage/
  WorktreeArtifactRule.swift        // what counts as a regenerable artifact
  WorktreeStorageInspector.swift    // measures; read-only
  WorktreeActivityProbe.swift       // last activity + "build in progress"
  WorktreeMergeStateResolver.swift  // merged / notMerged / unknown
  WorktreeReclaimPolicy.swift       // pure decision function
  WorktreeReclaimer.swift           // the only code that deletes artifacts
  WorktreeReclaimService.swift      // orchestrates; the trigger entry point
```

### 1. `WorktreeArtifactRule`

A regenerable artifact is a directory with a known name **whose sibling is a
known manifest**. The manifest anchor is what makes deleting it safe.

| Rule | Directory | Required sibling | v1 |
|---|---|---|---|
| SwiftPM | `.build` | `Package.swift` | ✅ |
| Cargo | `target` | `Cargo.toml` | ✅ |
| npm/pnpm/yarn | `node_modules` | `package.json` | ✅ |

- Match at any depth inside the worktree, so nested packages count, for example
  `Tests/ArchitectureFitnessTests/.build`.
- Don't descend into a matched artifact.
- Never follow symlinks. A symlinked artifact directory is never a match.
- Rules are data, so new ecosystems can be added later without touching the
  policy.

### 2. `WorktreeStorageInspector` (read-only)

- For each worktree, returns its artifacts with sizes (from
  `totalFileAllocatedSize`, no symlink traversal) and the total size. Swift
  Build puts symlinks inside `.build` (`debug -> out/Products/Debug`,
  `index-build/debug -> arm64-apple-macosx/debug`), so following links would
  double-count.
- Runs off the main actor. Results are a derived cache: store them keyed by
  worktree path (`GitWorktreeInfo.id`, the porcelain path) with a timestamp.
  Document the invalidation, as `AGENTS.md` requires.
- **Don't re-measure on every panel refresh.** `refreshRepoDetails` runs every
  30 s and after every stage, commit and push (see Verification results). At
  that point only reconcile the path set: measure new paths, drop removed ones,
  and never evict on an empty list, because a failed `listWorktrees` returns
  `[]`. Re-measure fully when the worktree sheet opens, on the header refresh
  button, after add/remove/reclaim, and when an entry is older than a TTL.
- Own the in-flight measurement (a stored `Task` with cancellation or a
  generation check). The view model has neither.

### 3. `WorktreeActivityProbe`

- **`lastActivity`** is the max of:
  - the latest `AgentTask.updatedAt` of any task whose `executionRootPath`
    canonically equals the worktree path. `updatedAt` is the existing recency
    key: every `TaskEvent`, status change and run finish bumps it, and the
    sidebar sorts by it. No schema change is needed;
  - the HEAD commit date;
  - the mtime of the worktree's git `index` file;
  - the shallow mtime (depth ≤ 3) of each artifact directory.
  - the newest activity previously observed for the worktree, kept in
    `UserDefaults` (`astra.worktreeStorage.observedActivity.v1`). Reclaiming
    deletes the artifacts that supplied a timestamp, and without this a
    worktree could look idle for longer right after its cleanup.
- **Compare canonical paths.** Git reports resolved paths (`/private/var/…`).
  `executionRootPath` is only tilde-expanded and `standardizedFileURL`-normalized,
  and imported or copied values aren't normalized at all. Resolve both sides
  with the existing canonicalizer (`ExecutionSandbox.canonicalize`; workspace
  import uses `ExecutionPathSafety.required.canonicalize`). Match only
  non-primary worktrees, because `executionRootPath` can also hold a repository
  root.
- **`isBuildInProgress`** is true when any of these holds (verified; see
  Verification results):
  1. **SwiftPM holds its workspace lock.** The lock is *not* under `.build`. It
     is an `flock` on `$TMPDIR/<name>.lock`, where `<name>` is the artifact's
     canonical path with `/` replaced by `_`, trimmed to its last 255 UTF-8
     bytes. Check both the artifact and `<artifact>/index-build`
     (sourcekit-lsp's background-index scratch path, which has its own lock).
     Use `FileManager.default.temporaryDirectory`: ASTRA isn't sandboxed and
     passes `TMPDIR` through to agents. Open the file read-only without
     `O_CREAT`, try `LOCK_EX | LOCK_NB`, and release at once. A missing file
     means not held.
  2. **`.build/.lock` names a live SwiftPM process** (`swift-build`,
     `swift-test`, `swift-run`, `swift-package`). That file is a PID
     breadcrumb, not a lock: SwiftPM never locks or deletes it, so it is often
     stale. It covers a builder whose `TMPDIR` differs from ASTRA's.
  3. **An entry at depth ≤ 3 changed in the last 15 minutes.** Walking the
     whole tree is too slow. This is a fallback, and the only signal for Cargo
     and npm in v1. It isn't enough alone: `swift test` holds `.build` for the
     whole run while nothing near its top changes.

### 4. `WorktreeMergeStateResolver`

Returns `.merged`, `.notMerged` or `.unknown`:

- `.merged` if `git merge-base --is-ancestor <head> <defaultBranch>` succeeds.
  Exit 1 is `.notMerged`; any other failure is `.unknown`. Resolve
  `<defaultBranch>` once per repository with `getDefaultBaseBranch`. It returns
  a remote-tracking ref such as `origin/main`, and a stale ref only errs toward
  `.notMerged`. A detached worktree gets only this check.
- `.merged` if the branch's GitHub PR has state `MERGED`. This is required:
  ASTRA squash-merges, so the ancestor check alone misses most merged branches
  (verified on #414: its head commit is not an ancestor of `origin/main`).
  - The existing lookup can't answer this: both `lookupOpenPullRequest`
    variants pass `--state open`.
  - Add a sibling `GitService` method that runs
    `gh pr list --head <branch> --state merged --json number,state,headRefOid,mergedAt --limit 1`
    through the same `gh` runner and `GitHubPullRequestRef` decoding. That's a
    new query, not a new GitHub client.
  - Expose it, with the other reads this feature needs, on a small
    `WorktreeStorageGitReading` protocol that `GitService` conforms to, so
    `GitRepositoryOperating` and its test fakes don't change.
- Count a merged PR only when the worktree's HEAD equals the PR's `headRefOid`
  or is an ancestor of it. `--head` matches the branch name alone, so a reused
  name, a fork, or commits added after the merge would otherwise read as
  merged. If `headRefOid` isn't in the local object store, return `.unknown`.
- `.unknown` on any lookup failure. Unknown never triggers a removal suggestion.
- Gate PR lookups with a breaker the resolver owns, keyed per repository.
  - Reuse the `GitPullRequestLookupBreaker` type, not the panel's instance. That
    instance is private to the view model and holds a single (branch, repo)
    slot.
  - The breaker trips only on auth failures, so also stop a sweep at the first
    `.unavailable`.
  - Skip the PR call when the ancestor check already says merged.
  - Cache `.merged` by (repo, branch, HEAD). Never cache `.unknown`.

### 5. `WorktreeReclaimPolicy` (pure, no I/O)

Input: worktree info, inspector result, activity, merge state, whether it's
dirty, whether a task is pinned, mode (`.automatic` / `.manual`), and
thresholds. Output: a set of actions with a human-readable reason for each.

| Condition | Result |
|---|---|
| Worktree is `isLocked` or `isPrunable` | `keep` (for prunable, the UI shows it as stale) |
| A non-terminal task is pinned to it | `keep` ("in use by task …") |
| `isBuildInProgress` | `keep` ("build in progress") |
| Primary worktree and mode is `.automatic` | `keep` (the primary is the user's main build) |
| Idle ≥ `reclaimAfter` (default **48 h**) | `reclaimArtifacts`, even if dirty: artifacts aren't source |
| Mode is `.manual` | `reclaimArtifacts` allowed on any worktree that passed the rows above |
| Non-primary, merged, clean, no pinned task, idle ≥ `suggestRemovalAfter` (default **7 days**) | also `suggestRemoval` |

Move `WorkspaceGitViewModel.hasActiveTaskPinned(to:)` into this layer (or a
small helper next to it), so removal and reclamation share a single owner for
the "in use" check. The view model calls it; it no longer implements it. Today
it is `workspace.tasks.contains { !$0.isTerminal && $0.executionRootPath == worktree.path }`,
and no test covers it. When moving it:

- Reuse `AgentTask.isTerminal` (completed, failed, cancelled, budgetExceeded),
  so draft, queued, running and pendingUser count as in use. Don't add another
  status list.
- Compare canonical paths (see §3), and check tasks in every workspace, not
  just the panel's.
- A claim anywhere inside the worktree counts (a task can be rooted in a
  subfolder), except inside another worktree nested in it (the primary
  contains `.claude/worktrees/*`).
- Also count as in use:
  - a worktree an unpinned task is running or queued in, via its workspace's
    `activeWorkingPath`;
  - while a task is queued or running, its working directory and exactly
    the set the runtime lets it write
    (`AgentRuntimeProcessRunner.runtimeWritablePaths`: additional paths, the
    workspace's primary path and the task folder);
  - an active `TaskTurnRequest`, at the path its execution-policy snapshot
    captured, plus its `.workspace` resource claims, because queuing a
    follow-up doesn't change a finished task's status and the turn runs where
    it was captured.
- Automatic mode also keeps any worktree containing a workspace's
  configured or selected path (`activeWorkingPath`), not counting worktrees
  nested inside it.
- Read task claims again immediately before deleting: a pass can spend
  minutes on git and GitHub, and a task may start meanwhile.
- Take a path string, not `GitWorktreeInfo`, and get tasks from a main-actor
  `ModelContext` fetch or a task array passed in. The view model's private
  `workspace` reference is what it reads today.

For the primary row: `isPrimary` means git's main checkout, the first porcelain
record. In automatic mode, also keep the workspace's own root, which can be a
linked worktree.

### 6. `WorktreeReclaimer` (the only deleter)

For each artifact:

1. Canonicalize with symlinks resolved. Refuse unless the artifact is strictly
   inside the canonical worktree root, is a real directory, and still matches
   its rule (the sibling manifest exists).
2. Re-check `isBuildInProgress` right before acting (TOCTOU guard). For a
   SwiftPM artifact, go further: take its §3 lock(s) with
   `LOCK_EX | LOCK_NB`, creating the file the way SwiftPM does (`O_CREAT`,
   `0666`), and hold them across the rename in step 3. A build that starts
   meanwhile waits for the lock, then sees a clean tree. If a lock is held,
   skip the artifact with the reason "build in progress".
3. Atomically rename it to `<name>.astra-reclaiming-<uuid>` in the same parent
   directory. After this, a concurrent build sees a clean tree, not a
   half-deleted one.
   The service runs the shallow build-activity scan on the file-system
   queue first. Then, in one main-actor turn, it re-reads task claims,
   workspace protection, the setting and the threshold, re-checks build
   activity at a cheap depth (one level, two for Cargo's
   `target/<profile>/deps`), and renames. The re-check is what catches an
   external Cargo or npm build started after the background scan; neither
   has a lock to hold. Every task status change also happens on
   the main actor, so no task can start between the check and the rename,
   for Cargo and npm too, which have no lock to hold.
4. Delete the renamed directory off the main actor. Delete permanently; don't
   move to Trash, because Trash doesn't free space.
5. On launch, sweep leftover `*.astra-reclaiming-*` directories inside known
   worktrees, in case the app quit mid-delete.

Return a typed result (freed bytes, skipped artifacts plus reasons, errors). The
reclaimer is idempotent. Log every action with `AppLogger` (category `"Git"`),
including path, bytes and reason.

### 7. `WorktreeReclaimService` and triggers

Evaluation is event-driven, per `AGENTS.md` ("prefer explicit event- and
service-driven workflows"):

- a task reaches a terminal state → evaluate the worktree it was pinned to;
- app launch → sweep interrupted reclaims, then evaluate all workspace repos
  once;
- the user presses "Reclaim" in the panel → manual mode.

No free-running timers in v1, and don't ride on the panel's 30 s refresh timer.
When time alone will change an automatic decision (a worktree becoming idle
enough), the pass schedules a one-shot recheck for that moment (the policy's
`recheckAt`), and a finished task schedules one at now + threshold. Without it,
"idle for 48 h reclaims without user action" would wait for the next launch.
The launch pass starts 2 minutes after launch so it doesn't compete with
startup work, and it reads the workspace list when it fires. A repository the
panel shows that no automatic pass has covered yet (a workspace added or
imported after launch) gets its own pass after the same delay.
Reclaim summaries record the worktrees they covered. A repository's sheet
shows only its own.
A "Merged · Remove" suggestion is re-validated at most once a minute while the
panel refreshes (cleanliness plus a local ancestry check; merges GitHub
confirmed stay cached), so a moved base branch withdraws it. A finished task
records its finish time as durable activity for its checkouts, so a recheck
that runs early can't reclaim a checkout that was just in use. It records that
even while automatic reclaim is off; only the recheck depends on the setting.
Each turn request posts its own event when it ends
(`TaskTurnRequestStateMachine`), carrying the root and workspace claims it
captured, since a turn runs where its snapshot says even after a re-pin. A turn
that ran records activity and rechecks at the threshold; a follow-up retracted
before it ran (no task status changes) rechecks after 15 minutes. An earlier
pending recheck is kept, since it re-derives any later one.
A recheck whose `git worktree list` fails (an empty list) tries again after
15 minutes, up to 3 attempts; a worktree git no longer lists is gone.
Likewise, an automatic pass that keeps a worktree only because task,
workspace or tracked-file state couldn't be read looks again after 15 minutes,
up to 3 times in a row, still failing closed.
The service starts listening before startup crash recovery, so the runs and
turns recovery ends are recorded as activity; the launch pass reads state when
it fires, two minutes later.
A launch pass returns the workspaces git couldn't answer for (a configured
path with a `.git` that discovery didn't return, or a failed worktree listing)
and retries only those after the launch delay, up to 3 passes.
The panel's cached decision also depends on task claims: when a task starts or
stops using a worktree, `reconcile` re-evaluates it, and a new claim withdraws
the reclaimable bytes and any removal suggestion at once.
The panel lists worktrees only for the selected repository, and only while it's
visible. So the service calls `GitService.shared.listWorktrees(at:)` for each
workspace repository itself. `GitService` is neither an actor nor `@MainActor`,
so it can make that call from the background.

### 8. UI (the existing worktree panel in `WorkspaceGitSectionView` / `WorkspaceGitSheets`)

Follow `docs/design-system/lean-ui-system.md`:

- Each worktree row shows its total size, with the artifact size in secondary
  text ("3.1 GB · 2.9 GB build").
- A panel header row: "Build artifacts: 12.4 GB reclaimable" with a
  **Reclaim** button. It runs manual mode on every eligible worktree and shows
  a skipped count with reasons on expansion.
- A removal suggestion appears as a quiet row affordance ("Merged · idle 9 d ·
  Remove"). It calls the existing `removeWorktree` flow, keeping the existing
  dirty/force confirmation.
- After an automatic reclaim, show a last-reclaimed line: "Reclaimed 6.1 GB
  from 2 idle worktrees · today 10:42".
- Reclaim asks for confirmation first: in manual mode it can include the
  primary checkout's `.build`, which costs a full rebuild.

Where these go:
- **Rows:** `WorktreeSheet.worktreeRow(_:)` in `WorkspaceGitSheets.swift`. Put
  the size in trailing secondary text.
- **Header row:** beside the sheet's "Worktrees" label, above the list. The
  sheet is a fixed 480×460 frame and the list is capped at 220 pt, so the new
  row takes height from the list.
- **Location popover:** at 280 pt it's too narrow for sizes. Leave it as is.
- **Measuring state:** track it per path. Don't reuse `isSyncing`: it hides
  the panel's refresh button.

### 9. Settings

In the existing runtime settings pattern (`Astra/Services/Settings/`,
`SettingsRuntimeTab`):

- `Automatically reclaim build artifacts from idle worktrees` — default **on**.
- `Idle threshold` — default 48 h.

Removal suggestions have no setting in v1. Changing either setting notifies
the service. Turning it off cancels scheduled rechecks, and a pass already
running re-reads the setting before it deletes. Turning it on, or changing the
threshold, schedules a fresh pass. Tests must use `InMemoryDefaults`
(enforced by `PreferenceDomainFitnessTests`).

## Safety invariants (tests must prove each one)

1. Nothing outside a matched artifact directory is ever deleted. Source files
   are byte-identical and `git status` is unchanged after a reclaim.
2. An artifact without its sibling manifest is never deleted, and neither is
   one holding any file in git's index (`git ls-files`, staged or committed):
   a tracked file is source whatever its folder is called. When git can't
   answer, the whole worktree is kept, even by the Reclaim button. Git is
   asked again right before the rename, and the rename turn keeps any
   worktree whose index changed since (`git add -N` touches nothing else).
3. Symlinks are never followed, whether measuring or deleting. An artifact
   symlink pointing outside the worktree is refused.
4. Nothing is reclaimed from a worktree with a non-terminal pinned task or a
   build in progress.
5. In automatic mode, nothing is reclaimed from the primary worktree.
6. No worktree is ever removed automatically. `suggestRemoval` requires merged
   + clean + unpinned + stale, and `.unknown` merge state never suggests.
7. Reclaiming is idempotent, and an interrupted reclaim is completed on the next
   launch.

## Tests (swift-testing, `@Suite`)

**`WorktreeReclaimPolicyTests`** (pure, table-driven), one case per row in §5,
plus these edge cases:

- idle 47 h → keep; idle 49 h → reclaim;
- dirty and idle → reclaim artifacts but no removal suggestion;
- merged and dirty → no suggestion;
- merge state `.unknown` → no suggestion;
- manual mode on the primary → reclaim allowed.

**`WorktreeArtifactRuleTests` / `WorktreeStorageInspectorTests`** (temp dirs):

- `.build` + `Package.swift` → matched;
- `.build` alone → not matched;
- nested `Tests/X/Package.swift` + `Tests/X/.build` → matched;
- symlinked `.build` → not matched and not traversed;
- `node_modules` + `package.json` → matched; `target` + `Cargo.toml` → matched;
- sizes don't double-count through symlinks.

**`WorktreeReclaimerTests`** (a real temp git repo, following the pattern of
`GitWorktreeTests` "Add, list, and remove a worktree on a new branch"):

- create a worktree with a fake `.build` next to `Package.swift`; reclaim → gone,
  source unchanged, `git status` unchanged;
- reclaim twice → the second run is a no-op with zero bytes freed;
- an artifact that escapes the worktree through a symlink → refused;
- a leftover `.build.astra-reclaiming-*` → swept on the next pass;
- an artifact touched < 15 min ago → skipped with the reason "build in progress".

**`WorktreeMergeStateResolverTests`**:

- fast-forward merged branch → `.merged`;
- squash-merged branch with PR state `MERGED` (stubbed lookup) → `.merged`;
- unmerged branch → `.notMerged`;
- lookup failure → `.unknown`.

**Regression:**

- `WorkspaceGitViewModel.removeWorktree` still refuses when a task is pinned,
  now through the moved helper;
- the existing `GitWorktreeTests` stay green.

## PR plan

Delivered as a single PR at the owner's request (2026-09-23), instead of the
two originally planned (measure and reclaim on demand, then automatic
reclamation). It covers §1–9 and every test above, plus trigger wiring and the
settings default.

For the PR:

- branch from current `main` per `AGENTS.md`;
- run `swift test --filter` on the new suites first, then `swift test` (this
  touches shared git and task behavior);
- run `./script/build_and_run.sh --verify` against **ASTRA Dev**, not
  production;
- run `git diff --check`;
- open a draft PR.

## Acceptance

- The dev app's worktree panel lists sizes for every worktree git reports,
  including `.claude/worktrees/*` and `~/.codex/worktrees/*`.
- Reclaim frees the reported amount (compare with `df`) and changes no tracked
  or untracked source file.
- A worktree being built by an agent is skipped and says why.
- With PR 2, finishing a task pinned to a worktree that is then idle for 48 h
  reclaims its artifacts without user action, and the panel says so.

## Verification results (2026-09-23)

These answer the four "verify before coding" questions. They were checked
against `main` at `a445a967` with Swift 6.4 (the Xcode default toolchain). The
sections above already reflect them.

**1. The `AgentTask` field for "last activity" is `updatedAt`.**
- `AgentTask` lives in `Astra/Models/AgentTask.swift` (schema V19). The
  `ASTRASchemaV*` files are frozen migration snapshots.
- Every `TaskEvent` initializer sets `task.updatedAt = now`
  (`TaskEvent.swift:42`). Status transitions and run finalization write it too.
- The sidebar sorts by it (`SidebarTaskIndex.swift:138`).
- Rename, pin and similar UI edits also bump it. That can only make a worktree
  look fresher, never staler.
- `executionRootPath` is a `String?` that isn't symlink-resolved, while git
  reports resolved paths. Matching needs canonical paths (§3, §5).

**2. SwiftPM's lock isn't under `.build`. It's an `flock` in `$TMPDIR`.**
This was tested on a scratch package whose only test sleeps 30 s, and on real
ASTRA worktrees.
- **During `swift build`**, `$TMPDIR/_private_tmp_…_lockprobe_.build.lock` is
  held: a non-blocking `flock` fails with `EWOULDBLOCK`.
- **During `swift test`**, while its `xctest` child runs the tests, the same
  lock is held.
- **After exit** the lock is free and the file stays.
- **Naming:** the canonical scratch path with `/` → `_`, plus `.lock`, trimmed
  to its last 255 bytes (tested with a 371-byte name).
- **`.build/.lock`** holds the lock holder's PID (`21228`, the `swift-test`
  process). It's never locked, and it outlives the process. SwiftPM writes it
  only when `.build` already exists. Two real worktrees had one naming a dead
  PID.
- **A second `swift build`** blocks on the `$TMPDIR` lock. It prints "Another
  instance of SwiftPM (PID: 21228) is already running using '…/.build',
  waiting until that process has finished execution...".
- **`index-build/`:** real ASTRA `.build` directories also contain this folder,
  sourcekit-lsp's background-index scratch path. It has its own
  `…_.build_index-build.lock`.
- **Same temp directory as agents:** ASTRA isn't sandboxed
  (`AppBundlePackagingTests.swift:236`) and passes `TMPDIR` through to agents
  (`ConnectorRuntimeProjection.swift:460`). So its temp directory is the one
  agents lock in by default.

**3. The existing PR lookup can't see merged PRs.**
- Both `lookupOpenPullRequest` variants pass `--state open`
  (`GitService.swift:1005`, `GitService+TargetedPullRequests.swift:34`).
- **#414**, squash-merged as `a445a967`:
  - `git merge-base --is-ancestor` of its head commit against `origin/main`
    exits 1;
  - `--state open` returns `[]`;
  - `--state merged` returns it as `MERGED`, with a matching `headRefOid`.
- **`GitPullRequestLookupBreaker`** is a value type held privately by the view
  model (`WorkspaceGitViewModel.swift:79`).
  - It has one (branch, repo) slot and a 15-minute cooldown.
  - Only authorization failures trip it. Any other failure, including network
    errors and rate limits, resets it.
- The default branch comes from `getDefaultBaseBranch`, as an `origin/<name>`
  ref.

**4. The panel refreshes from one place, on a 30 s timer.**
- `listWorktrees` has one caller, `refreshRepoDetails(force:)`
  (`WorkspaceGitViewModel.swift:467`). The result is stored at `:478`.
- It runs:
  - on appear;
  - every 30 s while the panel is visible (`:103`, `:171`);
  - on the refresh button;
  - after switching, adding or removing a worktree;
  - after every checkout, stage, commit and push.
- The view model is `@MainActor`. The git calls run off the main thread, and
  nothing cancels an in-flight refresh.
- `GitWorktreeInfo` carries `isPrimary` (the first porcelain record),
  `isLocked`, `isPrunable` and `isDetached`.

**Policy calls made for v1 (revisit with usage):**
- `draft` and `pendingUser` pins block artifact reclamation as well as
  removal, per the §5 table. That is the conservative choice.
- A measurement stays fresh for 10 minutes when the Worktrees sheet opens; the
  panel's refresh button re-measures anything older than a minute.
