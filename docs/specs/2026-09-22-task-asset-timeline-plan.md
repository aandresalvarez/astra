# Task Asset Timeline Plan

Status: draft, 2026-09-22. Branch `claude/astra-asset-timestamps-20f05f`.

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
  Outputs found at finalization are appended to the run that produced them as
  `discovered` changes.
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
- PR 4 needs PR 2's reader. It can ship without PR 3, but then outputs that no
  tool event recorded show no turn.

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
    fallback) record through `TaskEventInsertionService.insertAttachments`.
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

### PR 3: stamp discovered outputs onto their run

**Change.**

- Pass the run into `TaskArtifactPersistenceService.reconcileTaskOutputArtifacts`
  from both callers:
  - `AgentRuntimeRunPersistence.finalizeAndPersist`
    ([:121](../../Astra/Services/Runtime/AgentRuntimeRunPersistence.swift#L121))
  - `TaskDeliverableVerificationService`
    ([:47](../../Astra/Services/Validation/TaskDeliverableVerificationService.swift#L47))

  For each newly created row, append a `discovered` `StoredFileChange` to that
  run, unless the run already records that path.
- Timestamp each change with the file's modified time from discovery
  (`TaskOutputDiscoveredFile.modifiedAt`), clamped to the run's window, instead
  of the reconcile time.
- Add a batch `TaskRun.appendFileChanges(_:)`. The single-item version decodes
  and re-encodes the whole JSON on every call
  ([TaskRun.swift:140](../../Astra/Models/TaskRun.swift#L140-L145)), which is
  quadratic for a run that produces hundreds of files.
- Review every `run.fileChanges` consumer for the new entries:
  - `DiffsTabView`: a `discovered` entry has no diff content.
  - `hasRunScopedArtifact`.
  - Deliverable verification: must stay idempotent.
  - The changed files in `current_state.json`: that projection already
    synthesizes `discovered` entries, so dedupe against them.
  - The thread snapshot's 256 KB decode cap per run
    ([TaskThreadSnapshot.swift:51](../../Astra/Views/TaskThreadSnapshot.swift#L51)).
    A `discovered` entry carries no content, so it is about 150 bytes.

**Tests.**

- `TaskArtifactPersistenceServiceTests`: the run is stamped, there is no
  duplicate when a tool change already exists for the path, and batch append
  works.
- A finalization test.
- One test per consumer reviewed above.

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

- **Rollback is safe.** Older builds hide unknown event types from the thread
  ([TaskThreadSnapshot.swift:1235](../../Astra/Views/TaskThreadSnapshot.swift#L1218-L1237)),
  and the store shape does not change.
- **`discovered` entries become visible to every `run.fileChanges` consumer.**
  That is why PR 3 includes the review list.
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
- **Edits to existing files made without a tool event**, for example from a
  shell command. `TaskOutputDiscovery.filesChanged(during:)` could feed them in,
  at the cost of noise.
- **Other surfaces:**
  - per-turn file lists under every agent response (today only the latest run
    has one);
  - dates on the Files shelf;
  - search by date;
  - times in `current_state.json` for the agent.
