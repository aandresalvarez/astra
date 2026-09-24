# Task Asset Timeline Plan

Status: draft, 2026-09-22. Branch `claude/astra-asset-timestamps-20f05f`.
PR 1 and PR 2 shipped (#414, #417). Revised 2026-09-23: PR 3 now records
every task-folder change from a before/after snapshot, and PR 4 adds a by-turn
view to Browse files (branch `claude/turn-organized-file-view-5825d8`).

## Goal

When someone goes back to a task, every file in the conversation should answer
two questions: **when did it enter the task, and in which turn?** That covers
files the user attached (picked, dragged, or pasted) and files the agent created
or changed. The answer appears where people review files: the Task Files list
and the user's own messages in the thread.

## What ASTRA records today

| Asset | Durable record | Time | Turn | Shown |
| --- | --- | --- | --- | --- |
| File attached when the task is created | `AgentTask.inputs: [String]` | None per file, only the task's `createdAt` | Implied (first turn) | Task Files list as "input", no time |
| File attached to a follow-up | An `Attached files:` text block appended to the `user.message` event payload ([TaskComposerCoordinator.swift:117](../../Astra/Services/Tasks/TaskComposerCoordinator.swift#L117-L121)) | Event `timestamp` | The event's `run`, once the turn launches | Inline text in the bubble; the bubble discards its timestamp ([TaskMainView.swift:2030](../../Astra/Views/TaskMainView.swift#L2028-L2049)) |
| Pasted text or image, or dropped image, on a follow-up | The same text block, pointing at `$TMPDIR/astra_paste_*` or `astra_drop_*` | Event `timestamp` | Same | Same. The file itself is purged by macOS after about three days, because only `task.inputs` is copied into the task folder ([TaskInputMaterializer.swift:40](../../Astra/Services/Tasks/TaskInputMaterializer.swift#L40-L87)) |
| File the agent wrote or edited with a tool | A `StoredFileChange` in `TaskRun.fileChangesJSON`, plus a new `Artifact` row per change (version n+1) | Change `timestamp`, row `createdAt` | The run that holds the change | Task Files list with a source label; `TaskFileItem.change.timestamp` is never shown |
| File the agent created without a tool event (for example from a shell command) | An `Artifact` row from the output reconcile at run finalization | Row insert time | None: the run is in scope but not passed ([AgentRuntimeRunPersistence.swift:121](../../Astra/Services/Runtime/AgentRuntimeRunPersistence.swift#L121)) | Task Files list as "output", no time |

Measured on a production task (2026-09-23, 90 runs, 529 distinct file
paths): only 14 paths are tied to a run, and 76 runs recorded no file change
at all. Claude records only its own `Write`/`Edit` tool uses. The inferred
detector for Codex, Copilot, and the others ignores `.astra/`, which is where
task folders live, so its 59 Copilot runs recorded nothing either. Every
`Artifact` row lands inside a run or less than 5 s after one ends, so the turn
that *created* each file can be recovered for old history; 42 files were
edited and 48 removed later with no record, and that cannot be.

Two facts shape this plan:

- **Edits are already timed.** Each tool edit adds a new `Artifact` row with its
  own `createdAt`, so "first created" and "last changed" are both derivable. No
  `updatedAt` column is needed.
- **No view lists `Artifact` rows.** Every file list the user sees is built from
  `run.fileChanges`, disk scans, and `task.inputs`
  ([TaskFileIndex.swift:41](../../Astra/Views/TaskFileIndex.swift#L41-L86)).

## Decision: no SwiftData schema change

Two records already carry a time and a turn: the conversation event and the
run's file-change log. Between them they can cover every gap, and both keep
their details in JSON, so extending them needs no migration.

A schema bump would cost:

- a snapshot of V19's relationship closure (`ASTRASchemaV19Models`, the V18
  pattern);
- a V20 lightweight stage in all three migration plans;
- a pinned-digest test;
- a one-way store migration;
- a dev-store lockout for every sibling worktree still on V19.

No reader in this plan needs a new column. V19 has not reached a release tag,
but it has already written dev and locally built stores, so treat it as shipped
if a bump is ever needed.

## Ownership

This follows the AGENTS.md rule that durable records own facts and everything
shown is derived from them.

- **What was attached, and when.** Conversation events. A new typed
  `user.attachments` event is written in the same save as the `user.message` it
  belongs to. Older messages keep working through one shared parser for the text
  block.
- **The current set of task inputs.** Still `task.inputs`. The event is
  history; `inputs` stays the live set the runtime reads.
- **What the agent touched, when, and in which turn.** `TaskRun.fileChangesJSON`.
  What changed in the task folder between the run's start and end is appended
  to that run as `discovered`, `modified`, and `removed` changes.
- **What the user sees.** A pure, `Sendable` `TaskAssetTimeline`, built off the
  main actor from a store read. No view body touches `task.artifacts`,
  `task.events`, or the disk.

The prompt keeps its `Attached files:` block, so the model sees attachments
exactly as it does today. The block and the typed event are written once, in
one save, from one list, and are never updated, so they cannot drift apart.

## Work plan

Four PRs:

- PR 1 is a standalone bug fix.
- PR 2 and PR 3 are independent of each other.
- PR 4 needs PR 2's reader. It can ship without PR 3, but then files that no
  tool event recorded show no turn, and edits and removals do not show at all.

### PR 1: keep follow-up pastes and drops alive

**Why.** A file pasted or dropped on a follow-up lives only in `$TMPDIR`.
`TaskInputMaterializer` copies only `task.inputs`, which follow-ups never
touch, so the file disappears about three days later and the history points at
nothing. [#391](https://github.com/aandresalvarez/astra/pull/391) fixed the
same purge for initial inputs only.

**Change.**

- Before the composer builds the message text, copy each ephemeral attachment
  (`EphemeralComposerAttachment.isEphemeralPath`) into `<taskFolder>/inputs/`
  and use the copy's path. A task without a folder keeps today's behavior.
- One call in the `.message` branch of `TaskMainView.sendMessage` covers all
  four send branches: plan mode, queued, submitted, and fallback. It runs after
  the fork and runtime-eligibility checks, which compare against a preview
  built from the composer's live paths.
- Reuse the materializer's copy routine (write to `.partial`, then rename; adopt
  an existing copy) through a new `durableAttachmentPaths(_:for:)`.

**Tests.**

- `TaskInputMaterializerTests`: follow-up paths are copied, the message text
  names the copy, and an existing copy is adopted.
- `ComposerPresentationTests`: the send-action case.

### PR 2: record attachments as a typed event

**Change.**

- **Event.** Add `TaskEventTypes.Conversation.attachments = "user.attachments"`,
  category `conversation`. Payload:
  `TaskAttachmentsPayloadV1 { version, messageEventID, items: [{ path, kind }] }`.
  - `kind` is one of `file`, `pastedText`, `pastedImage`, or `droppedImage`,
    inferred from the `astra_paste_` and `astra_drop_` basenames that a durable
    copy keeps, so the composers need no new state.
  - The event takes its message's timestamp.
  - Display names ("Pasted image" instead of the temp name) are derived when
    read, not stored.
- **One writer, the event factory `TaskEvent.attachmentsEvent(for:paths:)`.**
  - Follow-ups: `ExecutionRequestSubmissionService.submit`
    ([:361](../../Astra/Services/Tasks/ExecutionRequestSubmissionService.swift#L361))
    takes the attachment paths and inserts the event in the same save as the
    `user.message` and its `TaskTurnRequest`. A failed save rolls back all
    three.
  - The three branches that insert events directly (plan mode, queued,
    fallback) insert the message and its record together through
    `TaskEventInsertionService.insert(_:attachmentPaths:into:)`.
    `TaskComposerSendAction.message` did not need to change: since PR 1 the
    send recomposes the message from the durable paths and passes those same
    paths along.
- **Initial inputs get no typed record.** They are copied into the task folder
  at launch, after submission, so a record written at submission would name a
  temp path that is about to vanish. `task.inputs` stays their owner, and their
  time is the task's first request.
- **One reader, `TaskAttachmentLedger`.** Each user-authored message
  (`user.message` or `plan.user.message`) is answered from its typed record
  when it has one, and otherwise from the text block in its own payload.
  Records whose message is not among the events given are ignored.
- **One parser for the legacy block.** Today there are two, and they disagree:
  - `AgentRuntimeAttachmentProjection.attachmentBlockPaths`
    ([:20](../../Astra/Services/Runtime/AgentRuntimeAttachmentProjection.swift#L20-L48))
    is case-insensitive, accepts `-` and `*` bullets, strips quotes and
    backticks, and stops at the first non-list line.
  - `AgentTaskForkService.attachmentPaths(in:)`
    ([:333](../../Astra/Models/AgentTaskForkService.swift#L333-L347)) does none
    of that.

  The runtime's version moves to `ASTRACore` as `TaskAttachmentBlock`, beside
  the writer the composer uses, so launch, fork, and ledger read the same
  format. The fork service lives in `ASTRAModels`, which cannot import the app
  target, which is why it had grown its own parser.
- **Fork remap.** `AgentTaskForkService` rewrites copied payloads with
  `TaskForkPathRewriter`, a plain substring replace
  ([:280](../../Astra/Models/AgentTaskForkService.swift#L278-L292)).
  `TaskEventPayloadCodec` escapes `/` as `\/`
  ([TaskEvent.swift:179](../../Astra/Models/TaskEvent.swift#L179-L184)), so paths
  inside the new JSON payload would silently not be remapped. The fork decodes
  each record, points it at its copied message and copied files, and
  re-encodes it. A record whose message stays on the far side of the cutoff
  (a follow-up queued during the checkpoint run) is not copied.

**Tests.**

- `TaskTurnSubmissionServiceTests`: the record is durable after the same save
  as the message and the request.
- `TaskAttachmentRecordTests`: the writer and parser round-trip, the parser
  reads every legacy spelling, kinds and display names, the ledger's record and
  text fallbacks, and the event factory.
- `AgentTaskForkServiceTests`: a file-copy fork remaps the record's paths and
  message (disabling the remap fails the test), and a record stays behind with
  its message.

### PR 3: record every task-folder change on its run

**Why.** Stamping only the outputs found at finalization would still miss
every edit and deletion made without a tool event, which is most of them (see
the measurement above). Edit history that is not recorded when it happens is
lost for good, so this ships before the UI.

**Change.**

- `TaskFolderRunSnapshot` walks the task folder just before the provider
  starts and again after it exits, off the main actor. It reads size,
  modified and status-change times, and file identifier for every file, and a
  content fingerprint for files up to 256 KB (at most 32 MB per walk), which
  catches a same-length rewrite whose timestamps round to the same tick. The
  visibility rules are the Files shelf's
  (`TaskOutputArtifactPathPolicy`), so `outputs/`, `inputs/`,
  `current_state.*`, `diagnostics/`, dependency trees, and hidden files never
  count. A folder past 50,000 entries is skipped rather than half-compared.
- The difference is appended to the run as content-less `StoredFileChange`s:
  `discovered` (created), `modified` (new kind), and `removed` (new kind).
  Paths the run already recorded through a tool event keep that record. Older
  builds read the new kinds as `unknown`.
- Created and modified changes are timestamped with the file's modified time,
  clamped to the run; removals with the run's end.
- `TaskRun.appendHostFileChanges(_:)` appends the batch with one decode and one
  encode. At most 250 observed changes are kept per run, new and edited files
  ahead of removals, and never more than still fit under the 256 KB past which
  the thread stops decoding a run's changes, tool changes included
  (`TaskRun.displayedFileChangesJSONByteLimit`). A record already past it
  gains at most 64 KB: the thread shows none of it, but the turns ledger
  reads the whole record.
- A walk that hits an unreadable directory, or a visible file whose metadata
  cannot be read, is discarded rather than compared, since every file it
  missed would otherwise read as removed. A tool path
  relative to the provider's working directory is resolved before deduping,
  and a removal is kept even when a tool edited the file earlier in the run.
- **No existing reader changes behavior.** `TaskRun.fileChanges` now returns
  tool evidence only (tool events plus the inferred detector), and the
  thread's own decoder applies the same filter. `allFileChanges` is the whole
  record. An audit of every consumer found several that must not see observed
  entries as they are: Git publication would take ownership of task-folder
  edits the agent did not make; deliverable and empty-run checks would count a
  removed file as output; the AI self-check would start reviewing path-only
  entries; prompts and `session_history.md` would mark removals and new files
  as edits. Each is opted in deliberately in PR 4 or later.
- `reconcileTaskOutputArtifacts` is unchanged: it still creates `Artifact` rows
  for new paths. Observed edits and removals create no `Artifact` rows.
- One `task.stats event=task_folder_snapshot` log line per run, with counts,
  the number of detected changes the bounds omitted, and duration.

**Not covered.** Workspace files outside the task folder that a shell command
changes (tool events and the Git-based detector still cover those), and a
user editing a task file by hand while a run is in progress, which is
attributed to that run. ASTRA's `connector-mutations/` and `mission-audit/`
folders are not hidden by the path policy, on the shelf or here. A file a tool
created and a command deleted within one run keeps only the tool's write: the
recorder stores a tool's file change when the tool is called, before its
result says whether it succeeded, so the write is no proof the file existed
and no deletion is inferred from it. A run whose change record cannot be
decoded is skipped rather than rewritten. A run interrupted by a crash or quit
records no observed changes: the pre-run baseline lives only in the worker's
memory, and `TaskRunLifecycleService.finalizeInterruptedRuns` has nothing to
compare against. Recovering them means persisting the baseline with a
fingerprint that is stable across launches (the current one is a per-process
`Hasher`).

**Tests.**

- `TaskFolderRunSnapshotTests`: created, modified, and removed; ignored paths;
  a folder the run creates; the entry limit; dedupe against tool paths across
  a symlinked root; timestamps and kinds; the batch append and the per-run
  cap; `fileChanges` and the thread snapshot leaving observed entries out.

### PR 4: the asset timeline in the UI

**Data.**

- Add `assetTimelineInput(taskID:)` to `TaskThreadHistoryStore`. It reads:
  - all runs (id, times, file changes);
  - the message, attachment, and initial-request events;
  - `Artifact` rows (path, version, `createdAt`), as the fallback for outputs
    that no run recorded.
- It reads the task's full history, not the thread's window of 50 runs and
  1,200 events
  ([TaskThreadSnapshot.swift:351](../../Astra/Views/TaskThreadSnapshot.swift#L351-L352)).
  It follows that store's fresh-context-per-read contract, so the caller flushes
  the main context first.
- `TaskAssetTimeline.build(_:) -> [TaskAssetTimelineEntry]` is pure and
  produces one entry per normalized path, with:
  - origin (attached, with its source; or created, edited, or output);
  - first and last time;
  - turn;
  - change count;
  - whether the file is still on disk.
- It refreshes through `.task(id:)` on a signature that needs no system calls:
  run count, event count, latest run id and status, and file-change length.
  This is the same idiom as `recomputeHeaderFileItems`
  ([TaskMainView.swift:1010](../../Astra/Views/TaskMainView.swift#L1010-L1029)).

**UI** (following `docs/design-system/lean-ui-system.md`).

- **Browse files, by turn.** A `Folders | Turns` switch beside the scope menu.
  It is a way of organizing files, not a scope, because one turn can touch
  task files and workspace files.
  - One section per turn, newest on top. A running turn is live at the top.
  - The section title is what the user asked; `Turn 87 · Today 10:05 AM ·
    1 new, 2 edited` is its subtitle. Only the latest turn starts expanded.
  - A file appears under every turn that touched it, so a turn's list is
    complete. Clicking opens the current version; removed files are dimmed.
  - Turns before snapshot capture show new files only, recovered from
    `Artifact.createdAt`, and say so.
- **Thread.** Each answer's changed-files button opens that turn's files, not
  the task-wide list.
- **Opting readers in to observed changes.** The ledger reads
  `allFileChanges`. Before any existing reader does, it needs:
  - `SessionHistoryManager` and `AgentPromptBuilder`: `+` for new, `~` for
    edited, `-` for removed, a cap on the list, removals left out of "You
    were working in".
  - `DiffsTabView`: icons by kind, and "No diff recorded" for observed entries.
  - Changed-file counts (`TaskRunVisibleFileChangeCounts`,
    `RunActivityPresentation`, `MissionControlPresentation`) and
    `TaskContextStateManager`: removals excluded or shown as removals, and
    paths deduped before `isUserFacingOutputPath`, which resolves symlinks on
    the main actor.
  - `TaskMainView.headerFileItemsInputSignature` joins every path on every
    keystroke; it needs a cheap key first.
  - Git publication, deliverable checks, and `ValidationService` stay on tool
    evidence.
  - A fork keeps the parent's paths for observed edits and removals (its
    manifest maps artifacts only), so the ledger matches them by path relative
    to the task folder.

- **Task Files list.**
  - Rows get a quiet subtitle, `Turn 3 · Today 2:14 PM`. The tooltip shows the
    full date, plus `Created … · Last edited …` for edited files.
  - Group headings `Attached` and `Created by the agent`, newest first, replace
    the source label on every row.
  - Follow-up attachments join the list. Today they are missing from it.
- **Thread.**
  - The user bubble shows its time. `ChatTranscriptUserBubble` already supports
    this; `chatUserBubble` throws the value away.
  - Attachments render as chips instead of inline text. Today the
    `.inlineOnly` markdown collapses the list into one line.
  - A chip's tooltip gives the path and the time it was attached. Clicking it
    opens the file, or marks it missing if the file is gone.
- **Line budget.** `TaskMainView.swift` has 8 lines of headroom under its
  5,200-line budget. New views go in `Astra/Views/Components/`, wired with
  one-line calls.

**Tests.**

- `TaskAssetTimelineTests`: dedupe, first and last times, turn mapping for
  retries and plan steps, each fallback, and an imported workspace missing old
  runs.
- `TaskThreadConversationSnapshotTests`: chips render and the text block is
  stripped from the bubble.
- A presentation test for the row subtitle and grouping.

## Turn numbering

Proposed:

- "Turn N" is the Nth thing the user asked, with the goal counting as 1.
- A run belongs to the message it was launched for (the `user.message` event's
  `run` link). If there is no link, it belongs to the latest ask before the run
  started. This keeps retries and plan steps in their ask's turn.
- Numbers count the whole task.

The thread's existing "Run N" labels count only within the snapshot's 50-run
window ([TaskMainView.swift:3873](../../Astra/Views/TaskMainView.swift#L3873-L3881)),
so on tasks with more than 50 runs the two would disagree.

## Verification

- **Per PR:** run `swift test --filter <suite>`, then
  `./script/build_and_run.sh --verify` and `git diff --check`. Run the full
  `swift test` for PR 2 and PR 3, since they change shared persistence behavior.
- **In ASTRA Dev.app:**
  1. Create a task with a file attached at creation.
  2. Paste an image on turn 2.
  3. On turn 3, have the agent write one file with a tool and one from a shell
     command.
  4. Check the Task Files list and the thread, relaunch, and check again.
  5. Fork at turn 2 and confirm the fork shows the original attach times.
- **Performance:** open a task with over 13,000 artifacts (the largest task in
  the 2026-09-03 production store had 13,295) and type in the composer. There
  should be no `main_thread_stall` lines. Log how long the timeline takes to
  build.

## Risks

- **Rollback is safe for PR 2's event, not for PR 3's entries.** Older builds
  hide unknown event types from the thread
  ([TaskThreadSnapshot.swift:1235](../../Astra/Views/TaskThreadSnapshot.swift#L1218-L1237)),
  and the store shape does not change. But PR 3's observed entries share
  `fileChangesJSON` with tool changes, and a build from before PR 3 has no
  `isObserved` filter: it reads `discovered` as it is and `modified` and
  `removed` as `unknown`, so Git publication ownership, deliverable and
  empty-run checks, validation, prompts, and counts would treat them as tool
  evidence for runs this build recorded. Keeping them out of an older build's
  way means a separate record: a typed per-run event (subject to compaction,
  the fork's substring path rewrite, and the 10-event export mirror) or a V20
  column. Open for the owner to decide before PR 3 ships.
- **Observed entries are hidden from every existing `run.fileChanges` reader**
  in this build (`isObserved`); each is opted in deliberately (PR 4).
- **Imports lose turns.** The workspace export mirrors only the last 10 runs and
  10 events per task
  ([WorkspaceConfigManager.swift:24](../../Astra/Services/Persistence/WorkspaceConfigManager.swift#L24-L33)),
  so after an import, older turns fall back to `Artifact.createdAt` and show no
  turn. This limit already applies to all history.

## Not in this plan

- **Schema V20 with `Artifact.runID`.** Revisit only if exports must keep turn
  links beyond the 10-run mirror, and freeze V19 first.
- **Launch reading the typed record.** Read grants and Docker mounts would come
  from the typed record instead of parsing message text, leaving the typed event
  as the only owner.
- **Shell edits to workspace files outside the task folder** for providers
  without the Git-based detector.
- **Other surfaces:**
  - dates on the Files shelf;
  - search by date;
  - times in `current_state.json` for the agent.
