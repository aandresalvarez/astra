# Workspace reservations and parallel tasks

Status: the owner decided the eight open questions on 2026-11-19 (see "Decisions"). Increments 1a
and 3a are open as draft PRs; the rest is not built. Each increment is its own draft PR.

Production evidence here is given by short task ID. Task titles, folder names, workspace names and
host names are left out because this repository is public.

ASTRA reserves the folders a task may write and frees them when it can show the task's tools
stopped. This document replaces the several rules that decide when a reservation ends with one
rule, gives the person an override that cannot dead-end, and says how tasks run side by side.

It supersedes the release and workspace-continuation parts of
[runtime recovery ownership](2026-10-24-runtime-recovery-ownership.md),
[cancellation resource ownership](2026-10-24-cancellation-resource-ownership.md) and the
"Writable roots" section of
[multithread resource architecture](2026-07-22-multithread-resource-and-lifecycle-architecture.md)
where they conflict. Their Retry, recovery, limits, native-session and settlement-ownership rules
stand. It keeps the guarantees listed in the
[concurrency minimum plan](2026-10-30-runtime-concurrency-minimum-plan.md).

## Problem

A new task shows "Waiting for resource … Previous execution cleanup is not yet confirmed" behind a
task that ended days ago, and "Review workspace" answers "Workspace cannot continue yet". Each
report had a different cause, and each fix added one more exit. Two production tasks are in that
state now.

Measured on a read-only copy of the production store taken 2026-11-18 14:40 (23 workspaces, 2,207
tasks, 6,003 runs on 156 days):

- 24 tasks have an execution receipt. 15 still reserve a folder, and none of the 15 has a process
  left on this Mac: every one ended before the last restart (2026-11-17 12:29).
- 13 of the 15 are `finished` with a completed run. Two are `unverified` with a failed last run
  (`capability_session_expired`, `runtime_settlement_uncertain`).
- 14 of the 15 carry `remoteWorkExcluded: false`. Traced: the launch sets it false whenever the
  workspace has an SSH connection (`AgentRuntimeWorker`, `remoteSSHRoute == nil`), whatever the
  run did. All 14 belong to the three workspaces with one, and each launched with a
  `native_shell` SSH route to the same host. Only 1 ran an `ssh` command in its last run, 4 ever
  did, and 10 never did (9 are one-line `printf` checks). One has two SSH jobs still marked
  `unverified`; the other 13 have none.
- All 15 carry `inheritedToolUncertainty: true`. A task admitted by a workspace decision inherits
  the holders' uncertainty, so it can never release its own reservation and becomes the next
  holder.
- 80 workspace decisions were recorded: 6 by a click, 74 inherited from two "remember" answers,
  one in each of two workspaces. 51 of the inherited ones covered 9 unverified holders at once.
- Since 2026-10-26: 255 requests, 219 of them follow-ups. Median wait to start
  12 s; 5 waited more than 10 minutes, the longest 11.9 hours.
- Runs that overlap a run of another task: 70% all-time, 41% from Aug 1 to Oct 25, 12% since.
- 41 commits changed the seven release-rule files between 2026-10-24 and 2026-11-13.

## Causes

1. **Release evidence is frozen when a run ends.** `stopProof` and `state` are written at exit.
   Whether anything can still act on a folder is a question about now: the process table, the boot
   time, the SSH job inventory. Today it is asked again only for a `finished` receipt with a
   completed run.
2. **The outcome of the work decides whether cleanup is believed.**
   `RuntimeWorkspaceContinuation.preview` (`hasCompletedTurn`), `RuntimeHostRestartRelease.released`
   and `RuntimeHostNoToolReceiptReconciliation.reconciled` each require `run.status == .completed`.
   A turn that failed, timed out or was stopped by ASTRA has no exit for other tasks, although a
   failed process is exactly as gone as a successful one.
3. **Each exit is its own conjunction that fails closed without saying why.** Three reconcilers of
   15 to 25 conditions each return `nil`, and the review throws a bare `.busy` from six places. A
   receipt that misses one condition of each stays reserved, and the banner cannot name which.

## A. One release rule

A reservation exists to keep two live writers out of one folder. It ends when nothing started by
its owner can still act. The rule reads facts as they are when it is evaluated, for every receipt
with `resourcesReleased != true`, whatever its `state`, its run's outcome, the task's status or
`cancellationRequested`.

For the receipt and every execution retained in its lineage, all of these must hold:

1. **No live owner.** The task's kernel lease can be taken and no run of the task is `running`.
2. **The provider process is gone.** Its recorded identity (PID and start time) is absent from the
   process table. If the launch never bound a process, the journal file was last changed before
   this boot.
3. **Nothing it started on this Mac is alive.** One of:
   - the exit record shows the process reaped and its group empty, and `stopProof.toolsStopped`
     was written true at exit (no tool ran, or the process table was clean then);
   - the process table, asked now for the launch's scope value
     (`RuntimeExecutionLocalSurvivors.observe`), is readable and shows no survivor;
   - the execution ended before this boot: its exit time, the journal file's change time and the
     ASTRA process that supervised it all predate `hostBootTime()`.
4. **ASTRA's own settlement left nothing.** `settlementInProgress`, `settlementLocalWorkStopped`
   and `settlementToolsStopped` are all closed, or the execution ended before this boot.
5. **Nothing off this Mac is open.**
   - every run of the lineage ran on the host, not in a container;
   - the lineage has no SSH job ASTRA tracks that has not ended. A job record that cannot be read
     counts as not ended, and so does a receipt that recorded jobs at its exit
     (`pendingSSHJobSetDigest`) when none can be found now.

   An SSH route alone does not hold a reservation (decision 1). The reservation protects a folder
   on this Mac. A job on another machine cannot write that folder, and a local `ssh` that is still
   running is a survivor under fact 3. So this rule does not read `stopProof.remoteWorkExcluded`;
   Retry still does.
6. **The native session is identified** (`sessionVerificationPending != true`), as today.

The rule does not read: `run.status`, `typedStopReason`, `task.status`, `state`, whether the run is
the task's latest, `cancellationRequested`, or `inheritedToolUncertainty`. Uncertainty a receipt
inherited belongs to other receipts, which the same rule judges on their own.

A release is final. An earlier execution whose reservation already ended is not asked again when
a later turn of the same task is judged; otherwise that turn's journal, written in this boot,
would send the earlier one back to "unknown" and the task would hold its folder again.

Each fact that fails is one of two kinds, and the rule returns which:

- **Running on this Mac**: the provider process is present, a survivor is alive, a live ASTRA
  process is settling, or the task is working now.
- **Unknown**: ASTRA cannot observe the answer. An SSH job that has not ended, a container, an
  unreadable process table or journal, or a run it lost track of in this boot with no scope value
  to ask about.

**When it is evaluated.**

- At startup recovery and in every `TaskQueue.refreshResourceOwnership`, where today's
  reconciliation already runs: when the queue wakes, when a lock is taken or released, on every
  pass of a task's own lock wait (250 ms), and when an SSH job changes.
- New: while the admission loop keeps a request in `waitingForResource`. That loop re-asserts the
  wait every 500 ms but never refreshes ownership today, so a holder whose process exits is
  noticed only when something else wakes the queue. It asks the rule on every tenth pass, and
  re-reads ownership only when the rule ended a reservation.
- When "Review workspace" opens, and again under the leases when the person confirms.

The rule has no timer of its own and writes only when a receipt changes from held to released.

**What a release writes.** Under the admission lease and the task lease, through
`lease.saveReconciliation(from:to:)`: `resourcesReleased` and `providerSharedStateReleased` become
true, and a release record says which fact answered (exit proof, process table, restart, or a
person's decision), when, and the boot time read. The original proof is kept as today. A
`runtime.execution_ownership` event and an audit line with the basis are saved in the same step.

`saveReconciliation` accepts today only a receipt that became replaceable (`canReplace`). It will
also accept one that carries a release record, saved as its own kind of entry that builds from
before this change do not read. That is the one change to the protected store.
Where today's rules upgrade the stop proof (`observing`, `restarted`), they keep doing so under
their existing conditions, because that upgrade is what Retry reads. A release that only this rule
or a decision grants leaves the stop proof as written at exit.

## B. An override that cannot dead-end

"Review workspace" evaluates rule A for every holder that conflicts with the waiting request and
shows what it found. It no longer asks whether the holder's turn completed.

- If every holder now passes the rule, they are released and the request starts. No decision.
- If any holder has something **running on this Mac**, the dialog names it (task, process name and
  PID) and offers to open that task or to keep waiting. It does not offer to start, and it has no
  stop button (decision 4): none of the held production receipts has anything running, and
  signalling a process matched after the fact carries the risk of a reused PID.
- Otherwise every remaining blocker is an **unknown**. The dialog names each one and offers "Start
  now" and "Keep waiting". Starting records the person's decision on each reviewed holder and
  releases it, exactly as rule A's release does, with basis "decision", the request that asked and
  the unknowns named. Retry inside that holder stays blocked by its unchanged stop proof.

A reviewed holder is resolved, so the next task is not asked about it again and the new task
inherits nothing: `inheritedToolUncertainty` is no longer set, and the admission-time exclusion of
reviewed claims is no longer needed for new decisions.

Nothing is remembered (decision 2). Today every decision without SSH jobs is remembered for the
workspace without asking. With decision 1 the only SSH question left is a tracked job that has
not ended: the dialog names that job, and the decision releases its holder, so the same job is
not asked about twice. `RuntimeWorkspaceContinuationScope` stops resolving requests in 1b. The two
answers remembered in production were given under wording that did not name SSH and are not
carried over; their saved entries are left in place and no longer read.

The decision is still made only for a request a person wrote (`isManualSource`). Per-request
decisions already saved stay readable and valid until their holders release.

## C. What does not change

- Two live writers never share a folder. A task that is working holds its claims through the
  per-task kernel lease and the queue's active locks, as today.
- A container, and an SSH job ASTRA tracks that has not ended, need a person. A restart, a clean
  process table or an exit code never answers for them. Other work on another machine does not
  hold a folder on this Mac (decision 1).
- Retry, Resume, approved plan steps, permission approvals and automatic recovery keep their full
  termination proof (`canReplace`) and remaining limits. Releasing a folder does not make an
  unfinished execution replayable.
- A new human message inside a task still continues the same owner through
  `RuntimeCompletedUserTurnContinuation.permits`. One addition, in 1a: a receipt whose reservation
  ended also accepts a new human message, so a task whose last turn left a stale settlement
  barrier, a timed-out process group or a cancellation is not stuck behind itself. It carries no
  earlier claims over, and "Check again" on such a timed-out run has nothing left to do.
- The journal is the authority. Events explain it; they never grant a release.
- Unreadable ownership never admits work.

## How today's exits map onto the rule

| Today | What it requires beyond the facts | Under this spec |
| --- | --- | --- |
| `RuntimeExecutionOwner.finish()` releases when `canReplace` | nothing | Kept. It is rule A read at exit, the fast path for a clean run. |
| Survivors check at exit (`AgentExecutionScopedProcess.stopProof(observingLocalSurvivors:)`, called from `AgentRuntimeProcessRunner`) | host placement, no SSH route | Kept as evidence capture; it records the scope value fact 3 asks about later. One change, in 1a with decision 1: the observation is also recorded for a host launch with an SSH route, so the local answer no longer depends on the remote one. There it does not set `toolsStopped`, which Retry reads. |
| `RuntimeHostNoToolReceiptReconciliation.reobserved` | `finished`, remote excluded, no inherited uncertainty, not cancelled | Subsumed by fact 3 (process table, now). Kept only as the stop-proof upgrade Retry reads. |
| `RuntimeHostRestartRelease.awaits` / `released` | `finished`, latest run completed, remote excluded, not cancelled, no registration folder | Subsumed by facts 2 to 4 (ended before this boot). Kept only as the stop-proof upgrade, with its conditions unchanged. |
| `RuntimeHostNoToolReceiptReconciliation.reconciled` | `finished`, latest run completed, host, no inherited uncertainty | Subsumed. A tool-free transcript is one way fact 3 holds; withdrawn SSH jobs are fact 5. |
| `RuntimeHostNoToolReceiptReconciliation.reconcile` (driver) | a candidate filter per exit | Replaced by one driver that evaluates every unreleased receipt. Its leases, `saveReconciliation`, event and audit are reused. |
| `ProviderSharedStateReadObservation.noRemoteRegistrations` | no `remote-jobs/<task>` folder | Replaced inside the rule by the job inventory: a registration with no job is not remote work. The settings-reader rule that owns this helper is not changed. |
| `RuntimeWorkspaceContinuation.preview` / `authorize` | holder's turn completed successfully (`hasCompletedTurn`), holder claims limited to three kinds | Replaced by the review in B. A refusal carries what is running; an unknown is named. |
| `RuntimeWorkspaceContinuation.admission`, `Admission.excludedClaims`, `inheritedToolUncertainty` | a saved decision per request, and every holder it names unchanged since | Not used by new decisions: the holder is released, so ordinary admission applies. Still honored for decisions saved before this change, with one correction that 1a needs. As `lockSources` reads, a task once admitted by a decision re-checks that decision's holders on every later message and is refused when one of them changed; 1a pins that with a test first. A holder whose reservation has ended is skipped, and when none is left the request is admitted the ordinary way. |
| `RuntimeWorkspaceContinuationScope` ("remember") | same claims, manual successor | Unchanged in 1a. Removed from admission in 1b (decision 2); saved entries are not read after that. |
| `RuntimeCompletedUserTurnContinuation.hasCompletedTurn` | success | No longer called by release or review. Removed once the saved-decision path is its last caller. |
| `RuntimeCompletedUserTurnContinuation.hasSettledTurn` / `permits` | settlement closed, exit recorded | Kept: it admits a person's next message in the same task. It also accepts a released receipt (C). |

The release decision then has one owner. An architecture fitness test pins that
`resourcesReleased = true` is assigned only in that service and in `finish()`.

## Receipts that already exist

Nothing is migrated or rewritten ahead of time. The rule reads the fields older receipts already
have, and a receipt is released the first time the rule or a decision reaches it. The validation
below is the rule run against the unreleased production receipts.

### Validation on production data

The implementation in #601, with decision 1 built in, ran in a throwaway test against read-only
copies of the production store taken on 2026-11-19: 25 receipts, 16 of them still reserving
a folder. The verdicts below use the real boot time (2026-11-17 12:29) and the real journal files'
change times. The probe is not in the repository.

| Task | Reserved | State, last run | Rule A | What decides |
| --- | --- | --- | --- | --- |
| 5C892B2E | a repository and its `.git` | unverified, failed (`capability_session_expired`) | **Release** | Host, no SSH route, ended 13 days before the boot |
| 9C8B97DB, 20F98DCD, 9DB3ECCE, A46D5C20, 104C15EA, D4652A28 | one other repository and its `.git` | finished, completed | **Release** | Ended before the boot. An SSH route was open; the registration holds no job |
| F15A1801, 84DE003D, 5A13F0D1 | the same repository | finished, completed | **Release** | Each of their 2 to 3 executions ended before the boot; no job |
| 7900335C | the same repository | unverified, failed (`runtime_settlement_uncertain`), settlement barrier still open | **Release** | All 94 executions ended before the boot. That answers the open barrier, four attempts with no exit record and one exit with a process group that was not empty. 91 registrations, no job |
| E0F780F8 | a workspace folder | finished, completed | **Release** | Ended before the boot; no job |
| 8B6BAD9C, 9875EA90 | a workspace folder and a cloud-synced folder | finished, completed | **Release** | Ended before the boot; no job. The two folders stay reserved by E027F715 |
| E027F715 | the same two folders | finished, completed | Hold, unknown | Two tracked SSH jobs are still `unverified`. Named by job ID |
| C2CF2F7A | two repositories and their `.git` | finished, completed, in this boot | Hold, running | Two earlier executions of the task left processes that are alive now: GnuPG's `keyboxd`, and Docker Desktop. Each is an orphan that started during the run and has its working directory inside the repository |

Result: 14 released, 2 held. Of the 14 receipts in a workspace with an SSH connection, 13 release
and one holds for its two jobs, which is what decision 1 expected. C2CF2F7A is new since the
first run of this validation and is not in an SSH workspace.

- **The driver on a copy.** A copy's journal files are new, so the driver was given the present as
  the boot time. It released 15 receipts, each with basis `host_restart`, the stop proof unchanged
  and the execution not replaceable; a second pass changed nothing; Retry on a released SSH holder
  stays refused. The folders of 13 released receipts are then free for another task, the other two
  are the ones E027F715 still reserves, and the saved claims drop from 110 to 9. The fifteenth
  release is C2CF2F7A, and it is an artifact of that simulated boot time: with the real one it is
  held, as the table says.
- **Cost of one pass of the rule** on that store, median of ten: 23 ms once only E027F715 holds,
  and 126 ms in the worst case where all 16 hold. No receipt is answered from its own fields
  any more, so every held one costs a lease, a task fetch, its lineage and its job records.
- **Something is running, for the first time in this data.** A signed commit starts `keyboxd`, and
  a `docker` command can start Docker Desktop; both outlive the task for hours or days with their
  working directory in the repository. The rule calls that running, which is what it was asked to
  do. See the open question at the end.
- **Under the first version of the rule**, which held an SSH route for a decision, the same data
  gave 1 release and 14 holds on 2026-11-18.
- **A limit of the rehearsal.** An SSH registration stores the absolute production path of its job
  records, so the job loader refuses a copy. The copies' registrations were pointed at the copy
  before the run. Every other check of the loader ran against the real workspace files.

Fields these receipts lack: the 15 that predate the boot carry no scope value (13 are older than
it, and two had an SSH route, where it was not recorded before #601), so the process table cannot
be asked about them and the boot answers for all of them. `providerLaunchCount` is absent on the
ten oldest and is not read. All 16 have captured claims.

## D. Parallel work, by folder type

The release rule only stops finished tasks from blocking. Tasks run at the same time when they do
not write the same folder, so the rule for a folder depends on what the folder is.

Where the owner's agents write today (2,697 file-edit tool calls in the production copy): 86% a
task folder, 5% a worktree under `~/Documents/Astra/Worktrees`, 5% temp, 1% a repository directly,
1% provider memory or config. None wrote a workspace folder outside its task folder and none wrote
a cloud folder. Writes made by shell commands are not in that count.

**How a folder's type is determined.** Checked in this order, on the symlink-resolved path:

| Type | Test | Exists today |
| --- | --- | --- |
| Task folder | `WorkspaceFileLayout.taskFolder`: `<workspace>/.astra/tasks/<id8>` | yes |
| Cloud-synced or not local | inside `~/Library/CloudStorage/` or `~/Library/Mobile Documents/`, `URLResourceValues.isUbiquitousItem`, or `statfs` without `MNT_LOCAL` | no; new, one function |
| Git checkout | `GitCheckoutLayout.worktreeRoot(containing:)`; a `.git` file starting `gitdir:` is a linked worktree; shared metadata from `commonDirectory(for:)` | yes |
| Plain local folder | none of the above | yes |
| Remote | not a local path: the workspace's SSH connections | yes |

A repository inside a cloud folder is a cloud folder. The type is derived when claims are resolved
and when a launch is planned; it is not stored.

**Rules.**

1. **Task folder: parallel, no claim.** It belongs to one task. In a workspace whose code root is
   the workspace folder itself and not a repository, a task's policy is its task folder plus the
   extra folders it was given. The workspace folder stays its launch directory and readable, is
   not in its policy, and is not claimed. Today that folder is the first exclusive claim of every
   task there, which is what serializes the analysis workspaces. The files ASTRA itself keeps in
   a workspace (`.astra-workspace.json`, `.astra/`, memory, SSH connections) are written by
   ASTRA's services, one at a time, as today. With enforcement Off this is a rule the agent is
   told and ASTRA reports on, not a wall (E). The owner relies on nothing that agents write
   directly in the workspace folder (decision 7).
   A fork has its own folder too (`AgentTaskForkService` derives it from the fork's new ID), but
   its history keeps the parent's paths, and in a workspace with a repository "shared files" is
   the only fork mode: fork A63A109D made 745 of its 751 file edits inside its parent's folder. A
   fork will start from a copy of the parent's task-folder files with its paths rewritten
   (`TaskForkPathRewriter`, used today only by the "with file copies" mode); repository files are
   never copied, as today. A fork that keeps the parent's folder instead claims it exclusively, so
   the two do not run at once.
2. **Git checkout: parallel through one worktree per task.** A task in its own worktree holds the
   worktree exclusively and the repository's Git directory shared, as it does today with
   enforcement on. A task that writes the checkout itself still excludes every other writer of
   that checkout and its Git directory. Sibling worktrees no longer serialize when enforcement is
   Off (E).
   There is no global default that puts every task in a worktree (decision 5). A workspace has a
   setting, off by default, that pre-checks the existing "Start in a new worktree" choice in the
   new-task composer. That choice is per task and not persisted today
   (`NewTaskWorktreeIntentStore`); the setting only changes its starting value, and the person can
   still clear it for one task.
3. **Plain local folder given as an extra path: one writer at a time.** Unchanged. There is no
   undo and no cheap way to see what a shell command changed.
4. **Cloud-synced or non-local folder: one writer at a time.** A stray write leaves this Mac
   within seconds, so it never has two writers, and readers of it are treated as writers unless a
   fence is on. With enforcement Off the guard follows the task's permission level instead of a
   new kind of prompt (decision 6, the owner's standing rule "Ask asks, Auto never asks"): at the
   Ask level a task that may write such a folder asks once, for that task; at the Auto level
   nothing is asked and what changed there is recorded on the task where the person can see it.
5. **Remote host: unchanged.** ASTRA does not reserve a remote directory and cannot observe one.
   Managed SSH jobs stay tracked per task, and one that has not ended is a person's decision
   (A5, B). Anything else on another machine does not hold a folder on this one.
6. **Unattended launches (schedules, chains): prevention required.** They start only where every
   writable root is fenced, never receive a remembered decision, and never resolve a holder.
   Specification only; production has no schedule.

## E. What "sandbox Off" means

ASTRA owns the policy and not the enforcement. The policy is the set of folders a task may write:
`TaskWorkspaceAccess.runtimeWritableCodeRoot`, `runtimeWritablePaths` and the task folder. Claims,
the launch plan, the prompt and any fence all read that one derivation, with enforcement on or off.

Enforcement is optional and comes from what already exists: the provider's own sandbox where it is
real and on (Codex and Cursor outside Auto), or ASTRA's Seatbelt profile at its write-only level
(`best_effort` or `strict` with read scope `open`). This spec adds no sandbox. In Auto every
provider drops its own confinement, so with enforcement Off nothing prevents a write anywhere the
user can write. Production runs that way.

Today Off changes admission in three places (`TaskExecutionResourceAdmissionPolicy`): every shared
claim becomes exclusive (`effectiveClaims`), a worktree task claims its source checkout again
(`unenforcedReadOnlyClaims`), and every exclusive root also claims its Git directory exclusively
(`unenforcedGitMetadataClaims`). Together they make sibling worktrees and read-only turns wait
for each other.

Under this spec, with enforcement Off:

- **Git checkouts are watched instead of serialized.** A worktree task keeps the claims it has with
  enforcement on. Before and after each turn ASTRA compares the source checkout
  (`git status --porcelain` and `HEAD`, the snapshot `AgentFileChangeDetector` already takes for
  the task's own path). A difference is recorded on the task as an event naming the files, shown
  on the task, and shown to the next task that needs that checkout. Nothing is reverted; Git is
  the undo. A read-only turn on a checkout stays shared for the same reason.
- **Folders without an undo keep the prevention they have.** For a plain or cloud-synced folder a
  shared claim still becomes exclusive when nothing enforces it, and a cloud-synced folder is
  also guarded by permission level as in D4.
- **Writes outside a task's folders are reported, not blocked.** File-tool writes outside the
  policy are named on the task after the turn. Writes made by a shell command in a folder that is
  not a repository are not seen; that is the stated limit of running with enforcement Off.

## Wording

The banner names the task, the folder and the one fact that holds it. The dialog repeats that
fact and says what each button does. No "cleanup", "receipt", "reservation" or "verified" in
anything a person reads.

| Case | Banner on the waiting task | "Review workspace" dialog |
| --- | --- | --- |
| Holder is working | Waiting for "Export report" to finish in `reports`. | No dialog. The action is "Open task". |
| Holder ended, a process it started is alive | "Export report" ended but left `python3` (process 4821) running in `reports`. This starts when that stops. | **Something is still running in `reports`.** `python3` (process 4821), started by "Export report". Buttons: Open task, Keep waiting. No button stops the process (decision 4). |
| Holder ended, an SSH job has not ended | Waiting for you: "Export report" has an SSH job on `build-host` that has not ended: "Nightly export". | **Start in `reports` now?** Nothing from "Export report" is running on this Mac. Its SSH job "Nightly export" on `build-host` is still running (or: could not be confirmed stopped). Starting now does not stop it. Buttons: Start now, Open task, Keep waiting. Nothing is remembered. |
| Holder ran in a container | Waiting for you: "…" ran in a container ASTRA cannot inspect. | Same shape; names the container. |
| ASTRA lost track of the run (quit or crash, same boot) | Waiting for you: ASTRA lost track of "…" when it quit and cannot confirm its commands ended. | **Start in `reports` now?** ASTRA sees no process from "…", but it lost its record of that run. Buttons: Start now, Keep waiting. When the run did leave an exit record, the dialog adds: Restarting the Mac settles this without a decision. |
| Ownership unreadable | ASTRA cannot read its record of who is using `reports`. Nothing was started. | No dialog. |

A holder that could reach another machine over SSH and has no tracked job open has no row: it does
not wait for anyone (decision 1).

After "Start now" the holder's task shows one line in its history: "You let other tasks use
`reports` on Nov 18. Retry here stays unavailable until ASTRA can confirm this run's work ended."

## Increments

Each is one draft PR from `main`. Narrow tests first, then `script/test_architecture.sh`, then
`script/swift_test.sh --no-parallel` because every one touches shared runtime or persistence.

**1a. The release rule (A).** Draft PR #601. One typed service evaluates the six facts and returns
release, running or unknown with the named fact. `refreshResourceOwnership` calls its driver in
place of `RuntimeHostNoToolReceiptReconciliation.reconcile`, the admission loop asks it while a
request waits, a saved decision whose holders have all released needs no exception, and a receipt
whose reservation ended accepts its task's next message. With decision 1 an SSH route alone does
not hold, the survivors check at exit is recorded for a host launch with an SSH route too, and a
tracked SSH job that has not ended holds and is named. No wording or dialog change.
Tests: one table over the verdict, each fact failing alone and all passing, for every `state` and
run outcome; a failed, timed-out and cancelled run that ended before the boot is released; a live
child process holds (running); a live survivor holds and is named; a tool run with an SSH route
open is judged by this Mac alone; an open SSH job, a container and a same-boot lost run are
unknown; a registration folder with no job does not hold; inherited uncertainty is ignored; the
release keeps the original proof, writes the event and the audit line, is idempotent, and skips a
busy lease; the stop proof is upgraded only where it is today; Retry of a failed holder stays
blocked; a task admitted by an earlier decision accepts its next message after its holders
released. Rehearsal on a production copy: see "Validation on production data".

**1b. The override (B).** `preview` returns the review (holders, kind, named facts) instead of
throwing `.busy`; confirming releases the reviewed holders with basis "decision". Nothing is
remembered and there is no stop button (decisions 2 and 4). Banner and dialog wording as above.
It starts after #600 and #601 are merged, because it rewrites the code both change.
Tests: preview never refuses a holder whose processes are gone; a running holder refuses and
carries what runs; confirming releases every reviewed holder, records the event on each holder and
on the waiter, and the waiter is admitted by ordinary admission with no inherited uncertainty; a
second waiter is not asked; a remembered answer saved before the change resolves nothing; a
per-request decision saved before the change is still honored; a holder changing while the dialog
is open invalidates the confirmation; Retry in a resolved holder stays blocked. Development app:
hold a synthetic workspace with an open SSH job, review it from a second task, and repeat with a
live `sleep` survivor to see the refusal.

**2. Task folders (D1) and fork folders.** In a workspace whose folder is not a repository, the
claim that replaces the workspace folder is the task folder itself, held exclusively: two tasks
never conflict on it, an older request that still claims the whole workspace folder contains it
and so still excludes them, and a fork that shares its parent's folder conflicts with the parent.
Staged as decision 8 says:

- **2a. Test setup, no behavior change.** The runtime tests that rely on two tasks in one plain
  workspace folder conflicting say so in their setup (a repository, or a shared extra folder), so
  the rule change that follows does not rewrite their meaning. Its own PR.
- **2b. The rule, with enforcement Off.** Only what is claimed changes, and only when nothing
  enforces the policy, which is how production runs. The workspace folder stays the launch
  directory and stays writable; a change there that is not in the task's folder is reported on
  the task, not blocked (decision 7). A fork starts from copies in its own folder. Its own PR.
- **2c. The enforced case.** With a sandbox on, taking the workspace folder out of the policy
  makes the provider's launch directory read-only, and providers write there themselves (Claude
  Code keeps `.claude/settings.local.json` in it). This waits for a run with real providers in the
  development app.

Tests for 2b: two tasks in a non-code workspace hold no conflicting claim and run together; a task
with a non-git additional folder still excludes another with the same folder; a task that claims
the whole workspace folder still excludes them; a fork's writable folder is its own, its inherited
files are readable, and a fork that keeps its parent's folder waits for the parent; the notice
fires for a change in the workspace folder outside the task's folder. Development app: two
analysis tasks in one synthetic workspace overlap; a fork writes only its own folder.

**3. Worktrees with detection (D2, E) and the folders without an undo (D3, D4).** In two parts.
3a, draft PR #603: with enforcement Off, a worktree task holds its source checkout and the
repository's Git directory as a reader instead of a writer, so sibling worktrees run together and
a task that writes the checkout itself still excludes them; the source checkout is compared before
and after the turn and a change is recorded on the task. 3b, lowest priority: a cloud-synced or
non-local folder is classified and stays one writer at a time, guarded by permission level
(decision 6).
Tests: two worktree tasks of one repository run together with enforcement Off; a same-directory
task still excludes them; a planted change in the source checkout is detected and named; a folder
under `~/Library/CloudStorage` and a ubiquitous folder classify as cloud-synced, a plain folder
does not; a read-only turn on a cloud folder with enforcement Off is still exclusive; at the Ask
level the task asks once, at the Auto level it does not ask and the change is recorded.

**4. Automations.** Specification only: an unattended launch requires prevention for every
writable root it is given and never resolves a holder. No code until the owner uses schedules
(production has none).

**5. Worktree setting per workspace (decision 5).** A workspace setting, off by default, that
pre-checks "Start in a new worktree" in the new-task composer. Small, independent of the others.
Where the setting is stored is part of that PR: a new field on the `Workspace` model needs a new
schema version and never an edit to a shipped one, so a lighter durable owner is preferred if one
fits the architecture rules.
Tests: a new draft in a workspace with the setting on starts with the choice checked, one in a
workspace without it does not; clearing it for one task does not change the setting; the setting
survives a relaunch.

## Risks

- **A restart is trusted for local work.** A tool that registered a launchd job, a cron entry or a
  container that restarts by itself survives it. This limit exists today in
  `RuntimeHostRestartRelease`; the rule now applies it to failed and cancelled runs too.
- **The process table has blind spots.** A system binary hides its environment, and an orphan that
  left the folder is not tied to its launch. Unchanged from today, and now reached by more
  receipts.
- **Work on another machine no longer holds a folder here.** A command an agent started over SSH
  without ASTRA's job helper can still be running there when the next task starts. It cannot write
  this Mac's folder, and ASTRA never reserved the remote directory; a person who needs the remote
  work to finish first has to wait for it themselves.
- **A decision frees the folder for everyone, not for one request.** That is the point of
  resolving the holder, and it makes a wrong click wider. The dialog refuses while something runs
  and names what is unknown.
- **The admission loop does more work while something waits.** The re-ask reads the held
  receipts' journals, their job records and, for a holder with recorded survivors, the process
  table. It runs on a counted pass; one pass costs 23 ms on the production store with one receipt
  held and 126 ms with sixteen. The 2 Hz re-render that fed the
  October menu live-lock is the reason it must not write unless a receipt changes.
- **Two kinds of reconciliation entry, and rollback.** A build from before this change refuses a
  reconciliation entry that is released but not replaceable (`reconciledRecord` requires
  `canReplace`) and then admits nothing. So 1a saves such a release under its own entry name, which
  older builds never look up. After a rollback an older build still reads the receipt as released;
  what it cannot do is accept a new message in that one task if a decision had archived the
  receipt before its release. That is rehearsed with the current production build on a copy
  before 1a leaves draft.
- **One new evaluator can become a second owner.** It must replace the conjunctions in the same
  PR that adds it, and the fitness test pins the single assignment. If review starts adding
  per-case conditions back, stop at round two and return to this document.
- **Parallel tasks in one non-code workspace can still touch the same file** when an agent writes
  outside its folder with enforcement Off. The policy and the prompt say where to write, and the
  notice says when it did not. Nothing prevents it.
- **Detection is after the fact.** For a repository the undo is Git. For a cloud-synced folder
  there is none, which is why that type keeps one writer and asks.

## Decisions

The owner answered the eight questions this document left open on 2026-11-19, accepting the
recommendations relayed to them as a set. Decisions 2, 4, 5 and 6 differ from what this document
first proposed. One question came up afterwards and is at the end.

1. **An SSH workspace with nothing open releases from local facts.** The decision is kept only for
   a tracked SSH job that has not ended. The reservation protects a folder on this Mac, a job on
   another machine cannot write it, and a local `ssh` still running is caught by the process
   check. Built in 1a.
2. **The two remembered answers are not carried over.** With decision 1 the only thing left to ask
   about is an open SSH job, and those answers were given under wording that did not name SSH.
   The dialog asks once, naming the job, the first time it comes up.
3. **Retry stays refused after a release.** A new message in the same task is admitted, so the
   person is not stuck.
4. **No stop button in 1b.** The dialog names what is running (process, PID, task) and offers to
   open that task or keep waiting. None of the held receipts has anything running, and signalling
   processes matched after the fact carries PID-reuse risk. Revisit only if logs show the case.
5. **No global worktree default.** A setting per workspace, off by default, pre-checks the
   existing "Start in a new worktree" choice in the new-task composer.
6. **Cloud-synced folders follow the permission level** when enforcement is Off: Ask asks once per
   task that may write one; Auto does not ask and leaves a visible record of what changed. One
   writer at a time in both.
7. **The workspace folder is not relied on for agent writes.** With enforcement Off a stray write
   there is reported, not blocked.
8. **Increment 2 is staged**: enforcement Off first, the enforced case after a real-provider
   check, and the test-setup change in its own PR with no behavior change before the rule.

Merge order: #600 first, then #601 rebased on it. Merging is the owner's action.

## Open after the decisions

One question, raised by the validation above and not by the eight decisions.

9. **A helper process that outlives the task.** A finished production task left `keyboxd` and
   Docker Desktop alive with their working directory in its repositories. Rule A holds those
   repositories as "running" until the processes exit or the Mac restarts. Until 1b a person can
   still continue past it with "Review workspace", as today. Under B as written, 1b would refuse
   to start while they run, and decision 4 gives no button to stop them, so the person would have
   to quit Docker or run `gpgconf --kill keyboxd` first. Three ways out: let a person start past a
   survivor after it is named, as for an unknown (proposed); keep the refusal and add the stop
   button after all; or keep the refusal and leave stopping to the person. This is needed before
   1b, not before 1a.
