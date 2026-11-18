# Workspace reservations and parallel tasks

Status: proposal. Nothing here is built. Each increment below is its own draft PR.

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
  run did. All 14 belong to the three workspaces with one, and each launched with
  `ssh=native_shell|alvaro-pcornet-backup`. Only 1 ran an `ssh` command in its last run, 4 ever
  did, and 10 never did (9 are one-line `printf` checks). One has two SSH jobs still marked
  `unverified`; the other 13 have none.
- All 15 carry `inheritedToolUncertainty: true`. A task admitted by a workspace decision inherits
  the holders' uncertainty, so it can never release its own reservation and becomes the next
  holder.
- 80 workspace decisions were recorded: 6 by a click, 74 inherited from two "remember" answers
  (Data Services Investigations, Pcornet PAQS). 51 of the inherited ones covered 9 unverified
  holders at once.
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
   - no tool ran while an SSH route was open (`stopProof.remoteWorkExcluded`), see open question 1;
   - the lineage has no SSH job that is not terminal, and no saved job inventory
     (`pendingSSHJobSetDigest`) left to confirm.
6. **The native session is identified** (`sessionVerificationPending != true`), as today.

The rule does not read: `run.status`, `typedStopReason`, `task.status`, `state`, whether the run is
the task's latest, `cancellationRequested`, or `inheritedToolUncertainty`. Uncertainty a receipt
inherited belongs to other receipts, which the same rule judges on their own.

Each fact that fails is one of two kinds, and the rule returns which:

- **Running on this Mac**: the provider process is present, a survivor is alive, a live ASTRA
  process is settling, or the task is working now.
- **Unknown**: ASTRA cannot observe the answer. An SSH route, an SSH job that has not ended, a
  container, an unreadable process table or journal, or a run it lost track of in this boot with
  no scope value to ask about.

**When it is evaluated.**

- At startup recovery and in every `TaskQueue.refreshResourceOwnership`, where today's
  reconciliation already runs: when the queue wakes, when a lock is taken or released, on every
  pass of a task's own lock wait (250 ms), and when an SSH job changes.
- New: while the admission loop keeps a request in `waitingForResource` behind a saved holder. That
  loop re-asserts the wait every 500 ms but never refreshes ownership today, so a holder whose
  process exits is noticed only when something else wakes the queue. It will re-ask the rule for
  the holders that waiting requests name, on a counted pass, not on every pass.
- When "Review workspace" opens, and again under the leases when the person confirms.

The rule has no timer of its own and writes only when a receipt changes from held to released.

**What a release writes.** Under the admission lease and the task lease, through
`lease.saveReconciliation(from:to:)`: `resourcesReleased` and `providerSharedStateReleased` become
true, and a release record says which fact answered (exit proof, process table, restart, or a
person's decision), when, and the boot time read. The original proof is kept as today. A
`runtime.execution_ownership` event and an audit line with the basis are saved in the same step.

`saveReconciliation` accepts today only a receipt that became replaceable (`canReplace`). It will
also accept one that carries a release record. That is the one change to the protected store.
Where today's rules upgrade the stop proof (`observing`, `restarted`), they keep doing so under
their existing conditions, because that upgrade is what Retry reads. A release that only this rule
or a decision grants leaves the stop proof as written at exit.

## B. An override that cannot dead-end

"Review workspace" evaluates rule A for every holder that conflicts with the waiting request and
shows what it found. It no longer asks whether the holder's turn completed.

- If every holder now passes the rule, they are released and the request starts. No decision.
- If any holder has something **running on this Mac**, the dialog names it (task, process name and
  PID) and offers to open that task, to stop it, or to keep waiting. It does not offer to start.
- Otherwise every remaining blocker is an **unknown**. The dialog names each one and offers "Start
  now" and "Keep waiting". Starting records the person's decision on each reviewed holder and
  releases it, exactly as rule A's release does, with basis "decision", the request that asked and
  the unknowns named. Retry inside that holder stays blocked by its unchanged stop proof.

A reviewed holder is resolved, so the next task is not asked about it again and the new task
inherits nothing: `inheritedToolUncertainty` is no longer set, and the admission-time exclusion of
reviewed claims is no longer needed for new decisions.

Today every decision without SSH jobs is remembered for the workspace without asking. It becomes
a checkbox, "Don't ask again for SSH work in this workspace", offered only for the SSH-route
unknown. It is saved as today's workspace-scoped decision and resolves later holders in that
workspace whose only blocker is that unknown, when a person's own instruction is waiting. It never
covers an SSH job that has not ended, a container, a lost run, or a request from a schedule,
chain, plan step or automatic retry. The two remembered decisions in production carry over for
the same workspaces.

The decision is still made only for a request a person wrote (`isManualSource`). Decisions already
saved stay readable and valid until their holders release.

## C. What does not change

- Two live writers never share a folder. A task that is working holds its claims through the
  per-task kernel lease and the queue's active locks, as today.
- Remote work ASTRA cannot observe needs a person. A restart, a clean process table or an exit
  code never answers for another machine or a container.
- Retry, Resume, approved plan steps, permission approvals and automatic recovery keep their full
  termination proof (`canReplace`) and remaining limits. Releasing a folder does not make an
  unfinished execution replayable.
- A new human message inside a task still continues the same owner through
  `RuntimeCompletedUserTurnContinuation.permits`. One addition: a receipt released by rule A or by
  a decision also accepts a new human message, so a task whose last turn left a stale settlement
  barrier is not stuck behind itself.
- The journal is the authority. Events explain it; they never grant a release.
- Unreadable ownership never admits work.

## How today's exits map onto the rule

| Today | What it requires beyond the facts | Under this spec |
| --- | --- | --- |
| `RuntimeExecutionOwner.finish()` releases when `canReplace` | nothing | Kept. It is rule A read at exit, the fast path for a clean run. |
| Survivors check at exit (`AgentExecutionScopedProcess.stopProof(observingLocalSurvivors:)`, called from `AgentRuntimeProcessRunner`) | host placement, no SSH route | Kept as evidence capture; it records the scope value fact 3 asks about later. One change: the scope is recorded for every host launch, also with an SSH route open, so the local answer no longer depends on the remote one. |
| `RuntimeHostNoToolReceiptReconciliation.reobserved` | `finished`, remote excluded, no inherited uncertainty, not cancelled | Subsumed by fact 3 (process table, now). Kept only as the stop-proof upgrade Retry reads. |
| `RuntimeHostRestartRelease.awaits` / `released` | `finished`, latest run completed, remote excluded, not cancelled, no registration folder | Subsumed by facts 2 to 4 (ended before this boot). Kept only as the stop-proof upgrade, with its conditions unchanged. |
| `RuntimeHostNoToolReceiptReconciliation.reconciled` | `finished`, latest run completed, host, no inherited uncertainty | Subsumed. A tool-free transcript is one way fact 3 holds; withdrawn SSH jobs are fact 5. |
| `RuntimeHostNoToolReceiptReconciliation.reconcile` (driver) | a candidate filter per exit | Replaced by one driver that evaluates every unreleased receipt. Its leases, `saveReconciliation`, event and audit are reused. |
| `ProviderSharedStateReadObservation.noRemoteRegistrations` | no `remote-jobs/<task>` folder | Replaced inside the rule by the job inventory: a registration with no job is not remote work. The settings-reader rule that owns this helper is not changed. |
| `RuntimeWorkspaceContinuation.preview` / `authorize` | holder's turn completed successfully (`hasCompletedTurn`), holder claims limited to three kinds | Replaced by the review in B. A refusal carries what is running; an unknown is named. |
| `RuntimeWorkspaceContinuation.admission`, `Admission.excludedClaims`, `inheritedToolUncertainty` | a saved decision per request | Not used by new decisions: the holder is released, so ordinary admission applies. Still honored for decisions saved before this change. |
| `RuntimeWorkspaceContinuationScope` ("remember") | same claims, manual successor | Kept as the store of remembered answers. `inherited` resolves holders instead of building a per-request authorization. |
| `RuntimeCompletedUserTurnContinuation.hasCompletedTurn` | success | No longer called by release or review. Removed once the saved-decision path is its last caller. |
| `RuntimeCompletedUserTurnContinuation.hasSettledTurn` / `permits` | settlement closed, exit recorded | Kept: it admits a person's next message in the same task. It also accepts a released receipt (C). |

The release decision then has one owner. An architecture fitness test pins that
`resourcesReleased = true` is assigned only in that service and in `finish()`.

## Receipts that already exist

Nothing is migrated or rewritten ahead of time. The rule reads the fields older receipts already
have, and a receipt is released the first time the rule or a decision reaches it. The validation
below is the rule run against the 15 unreleased production receipts.

### Validation on production data

The rule was written as a throwaway probe and run on the copy, with the real boot time
(2026-11-17 12:29) and the real journal files' change times. The probe is not in the repository.

| Task | Reserved | State, last run | Today | Rule A | What holds it |
| --- | --- | --- | --- | --- | --- |
| 5C892B2E Implement user notes | `starr-docs-omop`, its `.git` | unverified, failed (`capability_session_expired`) | Review refuses; restart rule skips it | **Release** | Nothing: host, no SSH, ended 13 days before the boot |
| 9C8B97DB, 20F98DCD, 9DB3ECCE, A46D5C20, 104C15EA, D4652A28 (six one-line `printf` checks) | `clew`, its `.git` | finished, completed | Review allowed | Hold, unknown | SSH route open; no job; no `ssh` ever run |
| F15A1801, 84DE003D, 5A13F0D1 | `clew`, its `.git` | finished, completed | Review allowed | Hold, unknown | SSH route open in each of 2 to 3 executions; no job; no `ssh` ever run |
| 7900335C Data Services Investigation | `clew`, its `.git` | unverified, failed (`runtime_settlement_uncertain`), settlement barrier still open | Review refuses; its own follow-up refuses | Hold, unknown | SSH route open in 89 of 94 executions; no job. The barrier is answered by the boot |
| E0F780F8 Run C2STAN Cycle 20 | `pcornet-data-curation` | finished, completed | Review allowed | Hold, unknown | SSH route open; no job |
| 8B6BAD9C Review TREETOP2.0 ticket | `pcornet`, Box `DockerPackage Responses` | finished, completed | Review allowed | Hold, unknown | SSH route open; no job; 7 `ssh` commands in its last run |
| 9875EA90 Share VM SSH setup | `pcornet`, Box folder | finished, completed | Review allowed | Hold, unknown | SSH route open; no job; no `ssh` ever run |
| E027F715 Duke Delivery | `pcornet`, Box folder | finished, completed | Review allowed for one request | Hold, unknown | SSH route open, and 2 SSH jobs still `unverified` |

Result: 1 released, 14 held, each with a named fact. None of the 15 has anything running, so the
"running" refusal is covered by tests and not by this data.

- The one release is the dead end reported on 2026-11-18: a request waiting on `starr-docs-omop`
  starts with no decision. Nothing the rule releases should stay held.
- With the two remembered answers carried over, 12 of the 14 resolve the next time a person sends
  an instruction in those workspaces (10 in Data Services Investigations, 2 in Pcornet PAQS).
  E0F780F8 asks once, because its workspace has no remembered answer. E027F715 asks and names its
  two jobs.
- If open question 1 is answered the other way, 13 of the 14 release by themselves and only
  E027F715 holds, for its two jobs.
- A limit of the rehearsal: an SSH registration stores its absolute production path, so the job
  loader refuses a copy. The probe read the copied job records directly.

Fields these receipts lack: none of the 15 carries a scope value (13 predate it, and the two newer
ones had an SSH route, where it is not recorded today), so the process table cannot be asked about
them; the boot answers for all of them. `providerLaunchCount` is absent on the ten oldest and is
not read. All 15 have captured claims.

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
   told and ASTRA reports on, not a wall (E); see open question 7.
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
3. **Plain local folder given as an extra path: one writer at a time.** Unchanged. There is no
   undo and no cheap way to see what a shell command changed.
4. **Cloud-synced or non-local folder: one writer at a time, and never unguarded.** A stray write
   leaves this Mac within seconds. A task that may write one runs either with a write fence that
   covers it or after the person approved that task writing that folder. Readers of it are treated
   as writers unless a fence is on.
5. **Remote host: unchanged.** ASTRA does not reserve a remote directory and cannot observe one.
   Managed SSH jobs stay tracked per task; the rest is a person's decision (A5, B).
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
  shared claim still becomes exclusive when nothing enforces it, and a cloud-synced folder also
  needs the approval in D4.
- **Writes outside a task's folders are reported, not blocked.** File-tool writes outside the
  policy are named on the task after the turn. Writes made by a shell command in a folder that is
  not a repository are not seen; that is the stated limit of running with enforcement Off.

## Wording

The banner names the task, the folder and the one fact that holds it. The dialog repeats that
fact and says what each button does. No "cleanup", "receipt", "reservation" or "verified" in
anything a person reads.

| Case | Banner on the waiting task | "Review workspace" dialog |
| --- | --- | --- |
| Holder is working | Waiting for "Duke Delivery" to finish in `pcornet`. | No dialog. The action is "Open task". |
| Holder ended, a process it started is alive | "Duke Delivery" ended but left `python3` (process 4821) running in `pcornet`. This starts when that stops. | **Something is still running in `pcornet`.** `python3` (process 4821), started by "Duke Delivery". Buttons: Stop these processes, Open task, Keep waiting. |
| Holder ended, an SSH job has not ended | Waiting for you: "Duke Delivery" has an SSH job on `alvaro-pcornet-backup` that has not ended: "Step 8 CSV export". | **Start in `pcornet` now?** Nothing from "Duke Delivery" is running on this Mac. Its SSH job "Step 8 CSV export" on `alvaro-pcornet-backup` is still running (or: could not be confirmed stopped). Starting now does not stop it. Buttons: Start now, Open task, Keep waiting. No checkbox. |
| Holder ended, SSH route, no job | Waiting for you: "Run C2STAN Cycle 20" could run commands on `alvaro-pcornet-backup`, and ASTRA cannot see that machine. | **Start in `pcornet-data-curation` now?** Nothing from "Run C2STAN Cycle 20" is running on this Mac. It could run commands on `alvaro-pcornet-backup` over SSH, and ASTRA cannot see whether something is still running there. Checkbox: Don't ask again for SSH work in this workspace. Buttons: Start now, Keep waiting. |
| Holder ran in a container | Waiting for you: "…" ran in a container ASTRA cannot inspect. | Same shape; names the container. No checkbox. |
| ASTRA lost track of the run (quit or crash, same boot) | Waiting for you: ASTRA lost track of "…" when it quit and cannot confirm its commands ended. | **Start in `clew` now?** ASTRA sees no process from "…", but it lost its record of that run. Restarting the Mac settles this without a decision. Buttons: Start now, Keep waiting. |
| Ownership unreadable | ASTRA cannot read its record of who is using `clew`. Nothing was started. | No dialog. |

After "Start now" the holder's task shows one line in its history: "You let other tasks use
`pcornet` on Nov 18. Retry here stays unavailable until ASTRA can confirm this run's work ended."

## Increments

Each is one draft PR from `main`. Narrow tests first, then `script/test_architecture.sh`, then
`script/swift_test.sh --no-parallel` because every one touches shared runtime or persistence.

**1a. The release rule (A).** One typed service evaluates the six facts and returns release,
running or unknown with the named fact. `refreshResourceOwnership` calls its driver in place of
`RuntimeHostNoToolReceiptReconciliation.reconcile`, the admission loop re-asks it for the holders
of waiting requests, and the scope value is recorded for every host launch. The banner reads the
returned fact. No dialog change.
Tests: one table over the verdict, each fact failing alone and all passing, for every `state` and
run outcome; a failed, timed-out and cancelled run that ended before the boot is released; a live
child process holds (running); a live survivor holds and is named; an SSH route, an open SSH job,
a container and a same-boot lost run are unknown; a registration folder with no job does not hold;
inherited uncertainty is ignored; the release keeps the original proof, writes the event and the
audit line, is idempotent, and skips a busy lease; the stop proof is upgraded only where it is
today; Retry of a failed holder stays blocked. Rehearsal on a production copy: 5C892B2E releases
and a request waiting on `starr-docs-omop` is admitted with no decision; the other 14 hold with
the facts in the validation table.

**1b. The override (B).** `preview` returns the review (holders, kind, named facts) instead of
throwing `.busy`; confirming releases the reviewed holders with basis "decision"; "remember"
resolves later holders; a released receipt accepts the task's own next message. Banner and dialog
wording as above.
Tests: preview never refuses a holder whose processes are gone; a running holder refuses and
carries what runs; confirming releases every reviewed holder, records the event on each holder and
on the waiter, and the waiter is admitted by ordinary admission with no inherited uncertainty; a
second waiter is not asked; "remember" covers only the SSH-route unknown and only a person's
request; a decision saved before the change is still honored; a holder changing while the dialog
is open invalidates the confirmation; Retry in a resolved holder stays blocked. Rehearsal on a
production copy: a request in `clew` reviews ten holders by name, confirming releases them, and
the next request needs nothing. Development app: hold a synthetic workspace with a tool run that
has an SSH connection, review it from a second task, and repeat with a live `sleep` survivor to
see the refusal.

**2. Task folders (D1) and fork folders.** The workspace root stops being a writable root when it
is not a repository; the claim resolver stops claiming it; shared workspace files keep their
ASTRA-side serialization; a fork starts from copies in its own folder, and a fork that keeps the
parent's folder claims it.
Tests: two tasks in a non-code workspace hold no conflicting claim and run together; a task with a
non-git additional folder still excludes another with the same folder; the launch plan, sandbox
grants and provider directory arguments all show the task folder and not the workspace root; a
fork's writable folder is its own, its inherited files are readable, and the parent's folder is
not in its writable set; the stray-write notice fires for a change outside the folder.
Development app: two analysis tasks in one synthetic workspace overlap; a fork writes only its own
folder.

**3. Worktrees with detection (D2, E) and the folders without an undo (D3, D4).** With enforcement
Off, a worktree task no longer re-claims its source checkout or the Git directory; the source
checkout is compared before and after the turn and a change is reported on the task; a
cloud-synced or non-local folder is classified and stays one writer at a time, with approval when
enforcement is Off.
Tests: two worktree tasks of one repository run together with enforcement Off; a same-directory
task still excludes them; a planted change in the source checkout is detected and named; a folder
under `~/Library/CloudStorage` and a ubiquitous folder classify as cloud-synced, a plain folder
does not; a read-only turn on a cloud folder with enforcement Off is still exclusive.
Development app: two worktree tasks in a synthetic repository overlap; a deliberate write to the
source checkout produces the notice.

**4. Automations.** Specification only: an unattended launch requires prevention for every
writable root it is given, never inherits a remembered decision, and never resolves a holder. No
code until the owner uses schedules (production has none).

## Risks

- **A restart is trusted for local work.** A tool that registered a launchd job, a cron entry or a
  container that restarts by itself survives it. This limit exists today in
  `RuntimeHostRestartRelease`; the rule now applies it to failed and cancelled runs too.
- **The process table has blind spots.** A system binary hides its environment, and an orphan that
  left the folder is not tied to its launch. Unchanged from today, and now reached by more
  receipts.
- **A decision frees the folder for everyone, not for one request.** That is the point of
  resolving the holder, and it makes a wrong click wider. The dialog refuses while something runs
  and names what is unknown.
- **The admission loop does more work while something waits.** The re-ask reads the conflicting
  holders' journals and, for a holder with recorded survivors, the process table. It runs on a
  counted pass and only for holders a waiting request names. The 2 Hz re-render that fed the
  October menu live-lock is the reason it must not write unless a receipt changes.
- **Two shapes of reconciliation entry, and rollback.** A build from before this change that reads
  an entry which is released but not replaceable refuses it (`reconciledRecord` requires
  `canReplace`) and then admits nothing until the newer build runs again. Increment 1a has to
  either keep such entries out of the path older builds read or state that rolling back needs the
  store backup. That is rehearsed with the current production build on a copy before 1a leaves
  draft.
- **One new evaluator can become a second owner.** It must replace the conjunctions in the same
  PR that adds it, and the fitness test pins the single assignment. If review starts adding
  per-case conditions back, stop at round two and return to this document.
- **Parallel tasks in one non-code workspace can still touch the same file** when an agent writes
  outside its folder with enforcement Off. The policy and the prompt say where to write, and the
  notice says when it did not. Nothing prevents it.
- **Detection is after the fact.** For a repository the undo is Git. For a cloud-synced folder
  there is none, which is why that type keeps one writer and asks.

## Open questions for the owner

1. **SSH workspaces with nothing open.** 13 of the 15 held receipts could reach
   `alvaro-pcornet-backup`, registered no SSH job and left no process; 10 never ran `ssh`. This
   spec holds them for a decision (remembered per workspace), as agreed. The alternative is to
   release them by the local facts alone and keep the decision for open SSH jobs only: a job on
   another machine cannot write a folder on this Mac, so what the wait protects is the remote
   directory, which ASTRA does not reserve. Which one?
2. **The two remembered answers** (Data Services Investigations, Pcornet PAQS) were given under
   wording that did not name SSH. Carry them over (proposed), or ask once more?
3. **Retry after a release.** A failed run that a restart has made harmless releases its folder
   but stays not retryable. Keep that (proposed), or let Retry read the same facts?
4. **A stop button for leftover processes.** ASTRA has no action that ends a leftover local
   process today. Build one that signals exactly the processes the table tied to that run
   (proposed for 1b), or name them and leave stopping to the person?
5. **Worktree per task as the default in a repository.** Every one of the 2,207 production tasks
   runs in the checkout itself. Parallel work in a repository only appears if new tasks there get a
   worktree unless the person says otherwise. Make that the default?
6. **Cloud-synced folders with enforcement Off.** Ask once per task that is given one (proposed),
   or turn on the write-only fence for those runs?
7. **Writing the workspace root.** In a non-code workspace a task would write its own folder and
   the extra folders, not the workspace folder itself. Is there anything you rely on agents
   writing directly there (the playbook files, for example)?
