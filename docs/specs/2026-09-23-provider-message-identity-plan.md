# Provider Message Identity Plan

Status: draft, 2026-09-23. Branch `claude/agent-work-visibility-4b1cae`.

## Goal

For every provider, each assistant message is recorded exactly once and in
full. The user's answer then shows up where they look for it: in the answer
bubble, not in a 4-line Updates entry, a truncated "summary", or nowhere at
all. The rules must be the same for Claude Code, Copilot, Codex, Antigravity,
Cursor, OpenCode and any provider added later.

The plan starts with the root cause: ASTRA decides whether two pieces of
assistant text are the same message by **comparing strings**. Every provider
already labels its messages with IDs, and ASTRA's parsers throw those IDs away.

## What goes wrong today

These numbers come from a read-only investigation of the production store on
2026-09-23 (active recovery store, schema 13, app 0.1.28). The investigation
compared the store against each CLI's own session logs.

| Provider | Symptom | Scale | Where |
| --- | --- | --- | --- |
| Claude Code | Every text block arrives twice: first as streamed deltas, then as a full `assistant` envelope. The envelope is split into lines before the echo check, and lines under 80 characters are never treated as echoes. The result is a gutted skeleton copy after the real text, and short messages recorded twice. | 52 of 74 September runs (70%) and 875 of 1,505 June–August runs. Zero before 2026-06-02, when `--include-partial-messages` was added. | [AstraRunProtocol.swift:219](../../ASTRACore/AstraRunProtocol.swift#L219), [AgentEventRecorder.swift:129](../../Astra/Services/Tasks/AgentEventRecorder.swift#L129) |
| Copilot | When a message carries `toolRequests`, the full `assistant.message` is re-sent as `.text` after its deltas, so short narration is recorded twice. | 33 of 120 September runs (28%) | [CopilotStreamEventParser.swift:187](../../ASTRACore/CopilotStreamEventParser.swift#L187) |
| Copilot | A JSON line that fails to parse is recorded as answer text. Copilot's own `******` masking breaks its JSON escaping. | 23 of 324 runs, all on CLI 1.0.83 or later (September: 1.0.77 0/17, 1.0.83 17/72, 1.0.86 6/31) | [CopilotStreamEventParser.swift:112](../../ASTRACore/CopilotStreamEventParser.swift#L112) |
| Codex | Each `agent_message` becomes `.completed`, and last-completed-wins overwrites `run.output`. No `agent.response` rows are written, so earlier messages are lost and nothing shows while the run is in progress. | All 15 runs with two or more messages lost the earlier ones. Codex's own rollouts still have them. | [CodexStreamEventParser.swift:120](../../ASTRACore/CodexStreamEventParser.swift#L120), [AgentEventRecorder.swift:880](../../Astra/Services/Tasks/AgentEventRecorder.swift#L880) |
| Cursor | `tool_call` frames are not parsed, so no tool, command or file-change events are recorded, and narration and answer render as one block. The Phase 0 capture also showed that the last `assistant` frame re-sends the previous message before appending, which produces the same hollow echo as Claude. | 2 of 2 runs (tools); echo seen in the capture | [CursorStreamEventParser.swift](../../ASTRACore/CursorStreamEventParser.swift) |
| Antigravity | No double delivery (0 of 55 runs). Affected only by the shared display rules below. | — | — |
| OpenCode | Not measured: no runs in the store. | — | — |

Four display rules are shared by every provider:

- **The answer is only the text after the last tool call or permission request.**
  [TaskThreadSnapshot.swift:589](../../Astra/Views/TaskThreadSnapshot.swift#L589).
  "Draft the reply → save it with `Write` → short sign-off" shows only the
  sign-off (prod task E027F715, run 5343). A permission request after the answer
  falls back to raw output, which can bury the answer under all the narration
  (Copilot run 5237).
- **The summary cut.** [TaskRunAnswerPresentationPolicy.swift:160](../../ASTRACore/TaskRunAnswerPresentationPolicy.swift#L160)
  shows only the text from the *last* `## Summary` or `Bottom line` onward. In
  Claude run 4946, a 3,804-character answer was shown as 62 characters, because
  the gutted echo had put an empty `## Bottom line` at the very end.
- **No way to see the full text.** Updates entries are clamped to 4 lines
  ([RunActivityTabsView.swift:7](../../Astra/Views/RunActivityTabsView.swift#L7)),
  and no view reads `TaskRunOutputPresentation.rawText`.
- **Compaction repeats the answer rule.** It has its own copy in
  [AgentEventCompactor.swift:207](../../Astra/Services/Tasks/AgentEventCompactor.swift#L207)
  and deletes every `agent.response` row that is not the selected answer. A
  demoted answer is therefore hidden first and then deleted: task E027F715 has
  84 runs, and the older ones kept only their last tool result and trailing text.

## Where the IDs already are

| Provider | Delta frame | Final frame | Identity | Parsed today? | Verified |
| --- | --- | --- | --- | --- | --- |
| Claude Code | `stream_event` `content_block_delta` (after `message_start`) | `assistant` envelope, one per content block | `message.id` plus the ordinal of the text block within that message | No. `StreamMessage` has no `id`, and `StreamPartialEvent` has no `index` ([StreamEventParser.swift:42](../../ASTRACore/StreamEventParser.swift#L42)). | Yes, CLI 2.1.270 |
| Copilot | `assistant.message_delta` `data.messageId` | `assistant.message` `data.messageId` | `messageId` | No | Yes, CLI 1.0.86 |
| Codex | none (`item.updated`, if it ever streams) | `item.completed` with `agent_message` | `item.id` (`item_N`) | No | Yes, CLI 0.153.4 |
| Antigravity | `step_update` `agent_response` (ACTIVE) | the same step at `state: DONE` | `step_index` | No | Yes, agy 1.2.9 |
| OpenCode | `text` part updates | `text` part | `part.id` (+ `messageID`) | No | Not installed |
| Cursor | none (no partial output flag) | `assistant`, one per model call; the last frame, which has no `model_call_id`, repeats the previous message and appends to it | `model_call_id` (`<uuid>-<n>-<suffix>`). The id-less last frame continues the previous key when that message's text is its exact prefix. | No | Yes, cursor-agent 2026.09.02 |

Phase 0 captured real streams from 2026-09-23 into
`Tests/Fixtures/ProviderStreams`. They also showed the following:

- **Claude subagents.** A subagent's frames arrive as whole `assistant` and
  `user` envelopes tagged with a non-null `parent_tool_use_id`, with no deltas,
  interleaved with the main agent's stream. Key subagent messages separately and
  keep them out of the main answer.
- **Copilot phase labels.** Copilot labels a message's `phase` on
  `assistant.message_start`, but in the capture the real 1,048-character answer
  was `commentary`, and only the one-line closing marker message was
  `final_answer`. Provider phase labels must not pick the answer.
- **Cursor's last frame is cumulative.** After the final tool call, Cursor's
  last `assistant` frame has no `model_call_id` and holds the previous
  message's full text plus the new text. Its `result.result` is every message
  concatenated. The exact-prefix continuation rule above keys it without
  comparing text heuristically.
- **Result frames repeat text.** Claude's `result.result`, Copilot's `result`
  and Antigravity's `result.response` repeat text that already streamed. They
  may only seed output when the ledger is empty, which the plan already requires.
- **Codex warning items.** Codex emits `item.completed` items of `type: error`
  for non-fatal config warnings, such as enterprise-managed requirements that
  override `approval_policy`. ASTRA parses them as `.failed`
  ([CodexStreamEventParser.swift:134](../../ASTRACore/CodexStreamEventParser.swift#L134)),
  which fails the whole run as `agent_reported_error`. Prod runs 5113 and 5114
  (2026-09-10) produced answers and were still marked failed this way. Only
  `turn.failed` is fatal.

## Decisions

**Key assistant text by provider message ID, and upsert.** A delta appends to its
message's draft, and a final **replaces** the draft. Text is never compared to
detect an echo. Under this rule every delivery style converges on the same
result: deltas then final (Claude, Copilot), final only (Codex, Cursor),
cumulative re-sends (possibly OpenCode), and interleaved messages.

**No SwiftData schema change.** Identity lives in the recorder's per-run ledger
while the stream is processed. The one durable boundary each later reader needs
is a new typed event, `agent.message.committed`, with a JSON payload. Runs
recorded before this change have no commit events, so readers keep today's
legacy path for them. That follows the V19 guidance in
[2026-09-22-task-asset-timeline-plan.md](2026-09-22-task-asset-timeline-plan.md).

**One owner for run text.** During recording, the ledger is the only writer of
`agent.response` rows and `run.output`. Result frames (`.completed`) seed
`run.output` only when the ledger recorded nothing. This removes the
last-completed-wins and echo-heuristic special cases.

**One owner for "which message is the answer".** A single ASTRACore policy is
used by both the thread presentation and the compactor (Phase 3).

## Design

### 1. Event model (ASTRACore)

```swift
public struct AssistantMessageFragment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case delta, final }
    /// Provider-namespaced and stable for the run, e.g. "claude:msg_01A…#0",
    /// "copilot:063c6f05-…", "codex:item_3", "agy:step-5".
    public let key: String
    public let kind: Kind
    public let text: String
}
```

- Add `AgentEvent.assistantMessage(AssistantMessageFragment)` and the matching
  `ParsedEvent` case. Five files switch exhaustively over `AgentEvent`:
  `AgentEventRecorder`, `AgentRuntimeStreamDebugCapture`,
  `AgentProcessSupport`, and the Codex and Copilot parsers.
- `.text(text:)` stays for sources without identity: plain-text modes, local
  MLX, and Copilot's plain-text fallback. The recorder gives each contiguous run
  of `.text` a synthesized key, so it goes through the same ledger.

### 2. Identity per provider (parsers)

A per-run **identity resolver** is added next to the pipeline in
`AgentRuntimeEventPipelineBox`, because some keys need state that a single line
doesn't carry.

- **Claude:** decode `message.id`, `index`, and `parent_tool_use_id`.
  - `message_start` sets the current message for that `parent_tool_use_id`
    stream.
  - `content_block_start` of type `text` assigns the next text ordinal.
  - Deltas map `index` to the key.
  - An `assistant` envelope maps `message.id` plus its n-th text block to the
    same key, as a final.
  - Subagent streams (non-nil `parent_tool_use_id`) get their own keys and a
    `subagent` flag, so Phase 3 can keep them out of the main answer. Whether
    Claude Code emits them on stdout in ASTRA's mode is verified in Phase 0.
- **Copilot:** `assistant.message_delta` becomes a delta, and `assistant.message`
  becomes a final, keyed by `messageId`, with or without `toolRequests`.
  `.completed` is reserved for the result frame. This deletes the
  "`.completed` for messages" workaround documented at
  [CopilotStreamEventParser.swift:188](../../ASTRACore/CopilotStreamEventParser.swift#L188).
- **Codex:** an `agent_message` from `item.completed` becomes a final keyed by
  `item.id`. The result: every Codex message is kept, and earlier ones show up
  as live progress.
- **Antigravity:** `agent_response` deltas are keyed by `step_index`. The DONE
  frame closes the message; its trailing delta still appends before the commit.
- **OpenCode:** `text` becomes a final keyed by `part.id`. Upsert makes a
  cumulative re-send harmless.
- **Cursor:** each `assistant` frame becomes a final keyed by `model_call_id`.
  The id-less last frame is a final for the previous key when that message's
  text is its exact prefix, and otherwise gets a new synthesized key.

### 3. Protocol markers per message (pipeline)

`AgentRuntimeEventPipeline` keeps one `AstraRunProtocolTextFilter` **per key**
for deltas, so line buffering never splices two messages together.

A final is filtered in one shot: a fresh filter, then `process` plus `flush`. It
is emitted as **one** fragment holding the visible text; it is never split into
lines. That removes the step that turned a whole-message echo into per-line
echoes. Protocol events from both paths stay deduplicated by
`emittedValidProtocolEvents`.

### 4. Recorder ledger (single writer)

`AgentEventRecordingState` gains an `AssistantMessageLedger` per run. Each
entry holds the key, the visible text, a `committed` flag, its row(s), and a
cached UTF-8 length.

- **Delta:**
  1. Append to the entry.
  2. Append to the entry's row (redacted append, as today). Never coalesce two
     keys into one row. If a message goes over the row cap, it continues in
     extra rows that the commit event lists.
  3. If the entry is the last one, append to `run.output`; otherwise rebuild it.
- **Final:**
  - If the final equals the draft, whitespace-insensitively, only mark it
    committed. This is the common case, and it writes nothing.
  - Otherwise, replace the entry's text, rewrite its row payloads through the
    redacting path, and rebuild `run.output` from the entries in order.
- **Commit:** on a final, when a new key starts after a tool event, or at run
  end, write one `agent.message.committed` event:
  `{key, provider, rowIDs, characterCount, sequence, subagent}`.
- **Ordering constraint:** today's coalescing bumps a row's timestamp so the
  incremental tail reader re-fetches it
  ([AgentEventRecorder.swift:90](../../Astra/Services/Tasks/AgentEventRecorder.swift#L90)).
  A rewritten row that is **not** the newest must not be bumped, because that
  would reorder it past later tool events. Post a full-refresh transcript
  notification instead.
- **Deletion:** for keyed text, `responseTextToAppend` and the echo floor are
  bypassed now and deleted in Phase 4, once no adapter emits unkeyed duplicates.

### 5. Process monitor

The monitor counts a final whose key already had deltas as `.control` for token
estimates and repetition signatures. Today that echo double-counts estimated
tokens against the budget for Claude and Copilot.

## Phases

Each phase is one PR, merged in order. Phases 1 and 2 are the ID-based tracking.

### Phase 0: capture real streams and write failing conformance tests

Status: landed with this plan, except the OpenCode capture.

- `script/capture_provider_stream.sh` runs one installed CLI with ASTRA's
  stream-format flags, in the provider's most restrictive mode that still allows
  writes, in a scratch workspace. `script/redact_provider_stream.py` then strips
  the machine: paths, user, email, host, init-frame tool/MCP/plugin inventory,
  rate-limit details, opaque signatures and managed-policy names. It is run by
  the owner, never in CI; set `ASTRA_CAPTURE_MODEL` to keep captures cheap. A
  Claude capture on Sonnet 5 cost $0.10.
- Capture safeguards, added after an Antigravity write-first run explored
  outside its workspace (`env`, `ls /tmp`, a `grep` through `/tmp`). That
  fixture was never committed.
  - The CLI runs under `env -i` with an allowlist, so no session tokens.
  - Tool results are replaced with a placeholder in every fixture, including
    failure details, partial output, progress messages, wrapped Copilot
    envelopes, Codex file-change text and Claude subagent summaries.
  - `redact_provider_stream.py --audit` refuses a capture whose tool calls
    reach outside the workspace or dump the environment, in every tool-call
    shape the parsers accept.
  - A capture that stops before its audit passes deletes the staged fixture,
    and a signal stops the timeout watchdog too, so it cannot later signal a
    reused process group.
  - The audit is a tripwire, not isolation: it also refuses inherited path
    variables, parameter expansions that can build a path, and a bare `cd` or
    `cd -`. The owner still reviews every fixture diff.
- Captured scenarios:
  - `answer-write-signoff` for Claude, Copilot, Codex, Antigravity and Cursor.
    It covers planned scenarios 1–4: narration, a tool read, a multi-line
    answer with short lines, a quote block and a table, a file write, and a
    final message that opens with an `ASTRA_EVENT complete` marker.
    Antigravity was captured with `--add-dir <workspace>` (see "Resolved:
    Antigravity sees the workspace" below). Its print mode ends the turn after
    the text-only answer, so that capture has no write or sign-off.
  - `subagent` for Claude.
  - Still to capture: OpenCode (not installed). A long answer over 4,096
    characters stays a synthetic Phase 1 test.
- Store the captures under `Tests/Fixtures/ProviderStreams/<provider>/<scenario>.jsonl`
  and add them to the test target's `resources`.
- Add a `ProviderTranscriptConformanceTests` suite that replays every fixture
  through the real adapter, pipeline and recorder, using the
  `HeadlessChatHarness` pattern with a fake CLI that `cat`s the fixture. For
  every provider and scenario it asserts:
  - every provider message appears in `run.output` exactly once;
  - there are no duplicated lines beyond what the provider sent;
  - no raw provider JSON appears in the text;
  - tool calls are recorded;
  - once Phase 3 lands, the answer bubble contains the final answer;
  - a successful turn completes and records no error events;
  - messages are recorded in provider order;
  - every file the provider wrote is recorded as a file change;
  - no output line is text the provider never sent, apart from joins at
    message boundaries;
  - identical messages are counted by how many times the provider sent them;
  - messages and tool calls interleave in provider order;
  - each message keeps its line and paragraph breaks;
  - tool results are recorded with their success or failure outcome;
  - the run's token totals equal what the provider reported;
  - every distinct `ASTRA_EVENT` complete marker leaves its `astra.complete`
    event (identical markers are idempotent and recorded once);
  - the session the provider announced reaches `task.sessionId` and
    `run.providerSessionId`, which native continuation resumes;
  - each subagent the provider starts and finishes leaves a durable
    `team.agent.started` / `team.agent.completed` event with its task id.
- A fixture that cannot exercise a check says so in `notExercised`, and the
  suite fails if it starts to. Antigravity's `agy` print mode ends the turn on
  a response without tool calls, so the answer-first scenario never reaches its
  write or its closing `ASTRA_EVENT` message; the Claude subagent scenario asks
  for no marker. Completion recording is therefore not exercised for either.
- A known issue is scoped to the items it explains: a specific message,
  duplicated lines under the 80-character echo floor, or errors that start
  with "Configured value for". Any other failure of the same check is a real
  failure.
- The suite landed with 15 known issues across 4 fixtures, all matching
  production symptoms or the captures:
  - Claude: short closing message doubled, hollow echo lines, answer not shown.
  - Copilot: answer not shown; `apply_patch` write not recorded; session id
    not recorded.
  - Codex: run failed by warning items, earlier messages lost, spurious errors,
    write not recorded, answer not shown.
  - Cursor: the re-sent previous message recorded as a hollow echo, the
    message not stored once, tool calls and the write not recorded.
  - Antigravity and the Claude subagent capture: fully green.
- Copilot's narration doubling is not exercised: the capture's only narration
  with `toolRequests` is the run's first message, which today's whole-output
  echo check already drops.

### Phase 1: core types, ledger and Claude

- The fragment type and new cases, the per-key pipeline filters, the ledger, the
  commit event, and the monitor change.
- Claude parser identity.
- Tests:
  - Claude conformance fixtures go green.
  - The run-5343 reproduction: the greeting appears once and the reply text is
    in exactly one row.
  - A redaction test: a secret split across a delta and a final replacement is
    redacted.
  - An interleaving test: a delta for an older key rebuilds the output without
    reordering rows.
- Suites: `AgentEventRecorderTests`, `StreamParserTests`,
  `HeadlessChatDuplicateOutputTests`, the conformance suite,
  `ArchitectureFitnessTests`.

### Phase 2: Copilot, Codex, Antigravity, OpenCode, Cursor identity

- Copilot keyed by `messageId`. Codex keeps every `agent_message`. Antigravity
  keyed by `step_index`. OpenCode keyed by `part.id`. Cursor keyed by
  `model_call_id`, with the exact-prefix continuation for its last frame.
- Copilot names its session only in the `result` frame's `sessionId`, which
  the parser does not read, so `task.sessionId` and `run.providerSessionId`
  stay empty. Copilot has no native continuation today, so follow-ups are not
  affected yet; record it with the rest of Copilot's identity.
- Codex `item.completed` items of `type: error` become a warning or diagnostic
  event, not `.failed`. Only `turn.failed` fails the turn.
- Codex's `input_tokens` already include `cached_input_tokens`; Codex's own
  `total_tokens` is input plus output. `usageEvent` adds the cached count again
  ([CodexStreamEventParser.swift:173](../../ASTRACore/CodexStreamEventParser.swift#L173)).
  The capture records 118,991 input tokens instead of 65,359, which inflates
  Codex token budgets. Count `input_tokens` once.
- An `ASTRA_EVENT` marker in a Codex `agent_message` reaches the recorder as
  `.completed`, bypasses the protocol filter, and is stripped from the output
  without being recorded. No September Codex run has an `astra.complete`
  event (0 of 8). Route agent messages through the same marker handling as
  other providers' text.
- Codex `file_change` items carry their paths under `changes[]`, which
  `fileChangeEvent` does not read
  ([CodexStreamEventParser.swift:165](../../ASTRACore/CodexStreamEventParser.swift#L165)),
  so every Codex write is dropped. Record one file change per entry.
- **Behavior change:** Codex `run.output` becomes every message in order, like
  the other providers, instead of the last one only. Update
  `codexMultipleCompletedMessagesKeepFinalAnswer` to assert the answer
  presentation rather than `run.output`. Check the validation `text_contains`
  assertions and continuation prompts that read `run.output`.
- Tests: every provider's conformance fixtures go green on the "recorded exactly
  once" and "no lost messages" assertions.

### Phase 3: choose the answer from messages (shared policy)

- Add `RunAnswerSelectionPolicy` in ASTRACore, fed by committed messages and
  tool events. It is used by `TaskRunOutputPresentation` **and**
  `AgentEventCompactor`, so the two can no longer disagree.
- Rules:
  - The answer is the last non-subagent message, extended backward over trailing
    bookkeeping: file writes (`Write`, `Edit`, `MultiEdit`, `NotebookEdit`),
    `TodoWrite`, permission requests and resolutions, and `ASTRA_EVENT`-only
    messages.
  - A trailing message that is shorter than a third of the message it follows,
    after only bookkeeping, is shown **with** that message, never instead of it.
  - Permission events are no longer answer boundaries.
  - Provider phase labels (Copilot's `commentary` / `final_answer`) are ignored,
    because the capture shows them tagging the real answer `commentary`.
- Summary cut: remove it for runs with commit events. For legacy runs, apply it
  only when the marker is a heading line *and* its section has substantive text;
  it must never land inside a trailing duplicate.
- Messages join with paragraph breaks at commit boundaries instead of the
  sentence-repair regex. That fixes "sent.Good question…" gluing.
- Tests:
  - Presentation fixtures for runs 5343 (answer before `Write`), 4946 (summary
    cut), 5237 (permission request after the answer) and 5189 (Antigravity
    summary cut).
  - A compactor test: the selected answer survives compaction for a task with
    more than 200 events.

### Phase 4: full text reachable, adapter gaps, deletion

- Make Updates entries expandable: remove the 4-line clamp on tap, and render
  entries as markdown. Add "Show full response" on the answer bubble, backed by
  `rawText`.
- Cursor: parse `tool_call` `started`/`completed` into `toolUse`/`toolResult`
  and `fileChange`.
- Copilot: record `apply_patch` writes as file changes. The replay records none,
  even though Copilot's own `result` frame lists them in
  `usage.codeChanges.filesModified`.
- Copilot: record a line that looks like JSON but fails to parse
  (`{"type":"…`) as a diagnostic event, never as `.text`. File the `******`
  masking bug upstream with a redacted sample.
- Delete `responseTextToAppend`'s echo heuristics and the Copilot and Codex
  last-completed-wins paths once no adapter emits unkeyed duplicates.
- Read `docs/design-system/lean-ui-system.md` before the Updates and bubble UI
  changes.

## Measuring success

After each phase ships to the dev channel, rerun the investigation queries
read-only against the active store, following `active-store.json`. Count only
runs started after the phase's build:

| Metric | Detector | Target |
| --- | --- | --- |
| Echo residue | A heading repeated with a hollow second section, or a short sentence immediately repeated | 0 for Claude and Copilot |
| Lost Codex messages | Codex rollout assistant messages missing from `run.output` | 0 |
| Raw provider JSON in text | `{"type":"assistant.…` in `run.output` | 0 |
| Long answer not shown | A response of 600 or more characters absent from the displayed answer, which is under a third of its length | 0 |
| Cursor tool events | `tool.use` rows in Cursor runs that used tools | Greater than 0 |

## Risks

- **Real frames differ from this plan.** Phase 0 captures them before any parser
  change, and the identity table is corrected from the captures.
- **Interleaving.** Claude subagents and parallel narration make a delta target a
  non-last message. The ledger rebuilds `run.output` only in that case, and the
  rebuild is bounded by the run's output size.
- **Row mutation cost.** Long messages keep today's row cap as continuation rows
  listed by the commit event. Rows never coalesce across keys.
- **Redaction.** A final that replaces a draft must go through the same redacting
  path as the original insert, and the split-secret redaction test covers it.
- **Line budgets.** `TaskThreadSnapshot.swift`, `AgentEventRecorder.swift` and
  `TaskMainView.swift` sit under `ArchitectureFitnessTests` line budgets. Put
  the new code in companion files (`AssistantMessageLedger.swift`,
  `RunAnswerSelectionPolicy.swift`).
- **Historic data.** Runs recorded before Phase 1 keep their duplicates, and the
  answer rows already compacted away stay gone. Nothing is migrated. A later
  optional repair could rebuild old runs from provider transcripts
  (`~/.claude/projects`, `~/.codex/sessions`, Copilot `session-state`), but it is
  out of scope here.

## Resolved: Antigravity sees the workspace

An early capture raised the concern that `agy` ignores its working directory:
one `run_command` printed the home directory for `pwd`, and the model did not
know the workspace path. The question was checked on 2026-09-23, and ASTRA's
reliance on the working directory
([AntigravityCLIRuntime.swift:473](../../Astra/Services/Runtime/AntigravityCLIRuntime.swift#L473))
holds:

- Two controlled `agy` 1.2.9 runs under `env -i`, both without `--add-dir`
  and one also without `--mode accept-edits`, ran `pwd` in the working
  directory and read a file there by absolute path.
- In production, Antigravity runs used `view_file`, `replace_file_content`,
  `write_to_file` and `list_dir` on workspace and task-folder paths, and ran
  repo-relative commands. For example, run 5222's `git log
  origin/main..origin/perf/…` returned that Astra branch's commit.
- The early capture's `init` frame already reported the scratch directory as
  `cwd`. Its one home-directory `pwd` did not reproduce.

The capture script still passes `--add-dir <workspace>`, which makes the
workspace explicit to the model; ASTRA's launch needs no change.

## Out of scope

- Copilot's own `******` masking bug. ASTRA only stops presenting its fallout as
  answer text.
- OpenCode behavior beyond what the Phase 0 captures show.
- The `AgentEventCompactor` threshold and retention policy, apart from sharing
  the answer policy.
