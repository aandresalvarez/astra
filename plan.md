# Astra — Improvement Plan

## Overview

This plan is informed by a code audit of the `claw-code` reference implementation (a Python port of Claude Code's session/thread management) and a thorough review of Astra's current architecture. It identifies 8 improvement areas organized by priority, each with specific changes, affected files, and implementation details.

---

## 1. Message Compaction & Conversation Memory Management

**Problem**: Task conversations (`TaskEvent` records) grow unbounded. Long-running tasks or multi-resume sessions accumulate hundreds of events, increasing SwiftData query cost and bloating the Activity tab. The claw-code reference uses a `TranscriptStore` with `compact()` to truncate to the last N entries.

**Changes**:

### 1a. Add compaction to TaskEvent storage
- In `ClaudeCodeWorker.swift`, after each `execute()` or `continueSession()` completes, count events for the task. If count exceeds a threshold (e.g., 200), archive older events into a single summary event.
- Add a new event type `"activity.compacted"` with payload containing a summary (e.g., "Compacted 150 earlier events. Key actions: 12 tool uses, 3 file edits, 2 errors").
- Delete the original compacted events from SwiftData to free memory.

### 1b. Add conversation window to resume prompts
- In `buildFollowUpMessage()` (line 530), instead of injecting the full `session_history.md`, only include the last 5 turns. This reduces prompt size and keeps the agent focused on recent context.
- Add a `maxHistoryTurns` setting (default 5) to `ClaudeCodeWorker`.

### 1c. Activity tab lazy loading
- In `TaskMainView.swift`, the activity feed currently loads all events with `task.events.sorted(...)`. Change to paginated loading: show the last 50 events by default with a "Load Earlier" button.
- Use `@Query` with a `fetchLimit` and `fetchOffset` instead of loading the full array.

**Files**:
| File | Action |
|------|--------|
| `Services/ClaudeCodeWorker.swift` | Add `compactEvents(for:modelContext:)` method, call after execute/resume |
| `Models/TaskEvent.swift` | Add `"activity.compacted"` event type documentation |
| `Views/TaskMainView.swift` | Add paginated event loading with "Load Earlier" |

---

## 2. Turn Limits & Enhanced Budget Controls

**Problem**: Tasks only have a `tokenBudget` control. The claw-code reference also has `max_turns` and `max_budget_tokens` as separate knobs. A task can make dozens of turns within budget but spin without progress. Additionally, the resume path (`runClaudeResume`) has **no budget enforcement at all** — `budgetExceeded` is hardcoded to `false`.

**Changes**:

### 2a. Add `maxTurns` to AgentTask
- Add `maxTurns: Int` property to `AgentTask` (default 0 = unlimited).
- In `ClaudeCodeWorker.runClaudeProcess()`, track turn count by counting `result` events or `agent.response` events. When count exceeds `maxTurns`, terminate the process and set `task.status = .budgetExceeded` with a descriptive event.

### 2b. Fix resume budget enforcement
- In `runClaudeResume()` (line 953), add the same budget enforcement logic that exists in `runClaudeProcess()`:
  - Track estimated tokens in the `readabilityHandler`
  - Check against remaining budget (`task.tokenBudget - task.tokensUsed`)
  - Set `budgetExceeded = true` and terminate if exceeded
- Also add the repetition circuit breaker and idle timeout watchdog that are missing from the resume path.

### 2c. Add `maxTurns` to the UI
- In `ChatPanelView.swift` composer, add a turns budget picker alongside the token budget picker.
- In `NewTaskView.swift`, add a `maxTurns` field.
- In `TaskMainView.swift` header, show turns used / max turns alongside token progress.

### 2d. Stop reason tracking
- Add `stopReason: String` to `TaskRun` (values: `"completed"`, `"failed"`, `"max_turns_reached"`, `"max_budget_reached"`, `"timeout"`, `"cancelled"`, `"repetition_detected"`).
- Set this in the worker based on how the process ended.
- Display in the Activity tab result card for quick diagnosis.

**Files**:
| File | Action |
|------|--------|
| `Models/AgentTask.swift` | Add `maxTurns: Int = 0` property |
| `Models/TaskRun.swift` | Add `stopReason: String = ""` property |
| `Services/ClaudeCodeWorker.swift` | Add turn counting, fix resume budget/watchdog/circuit-breaker |
| `Views/ChatPanelView.swift` | Add turns picker in composer |
| `Views/TaskMainView.swift` | Show turns + stop reason in header/result card |

---

## 3. Permission Denial Tracking & UI

**Problem**: When Claude hits a permission prompt (tool blocked, requires user approval), it's captured as a generic `tool.use` event or swallowed entirely. The claw-code reference has explicit `PermissionDenial` tracking with tool name and reason. Users can't easily see why a task stalled.

**Changes**:

### 3a. Add permission event parsing
- In `StreamEventParser.swift`, detect permission-related patterns in stream output:
  - Claude's `"user"` type events with permission prompt text
  - Tool results that indicate denial
- Add new `ParsedEvent` case: `.permissionDenied(tool: String, reason: String)`

### 3b. Surface permission events in the Activity tab
- In `TaskMainView.swift`, render `"permission.denied"` events distinctly:
  - Yellow/amber warning card with lock icon
  - Show which tool was blocked and why
  - For `.pendingUser` tasks, include an "Approve" action inline

### 3c. Permission summary in task header
- When a task is in `.pendingUser` status, show a pill in the header: "Waiting: permission for [tool name]"
- This gives immediate context without scrolling through the activity feed.

**Files**:
| File | Action |
|------|--------|
| `Services/StreamEventParser.swift` | Add `.permissionDenied` case, detect permission patterns |
| `Services/ClaudeCodeWorker.swift` | Emit `"permission.denied"` TaskEvent when detected |
| `Views/TaskMainView.swift` | Render permission events with warning styling + inline approve |

---

## 4. Structured Output for Spec Extraction

**Problem**: `SpecEngine.extractFromConversation()` runs Claude and parses JSON from free-form text output. It strips markdown code fences as a workaround. The claw-code reference has a `structured_output` mode with retry logic. Our extraction sometimes fails on malformed JSON.

**Changes**:

### 4a. Add retry logic to SpecEngine
- When JSON parsing fails in `extract()` or `extractFromConversation()`, retry up to 2 times with a refined prompt that emphasizes "respond with valid JSON only, no markdown fences."
- Track retry count and log warnings.

### 4b. Use JSON schema in the prompt
- Include the exact `TaskSpec` JSON schema in the extraction prompt so Claude knows the exact shape expected.
- Add `"You must respond with a single JSON object matching this schema. No other text."` instruction.

### 4c. Remove the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` flag from SpecEngine
- Lines 61, 155, 227 set this env var for all Claude subprocesses, including spec extraction and AI validation. This is unnecessary and may cause unexpected behavior.

**Files**:
| File | Action |
|------|--------|
| `Services/SpecEngine.swift` | Add retry logic, JSON schema in prompt, remove teams flag |

---

## 5. Session History & Audit Trail

**Problem**: `TaskEvent` mixes conversation messages, tool uses, lifecycle events, and system notifications in one flat list. There's no structured audit trail. The claw-code reference separates `HistoryLog` (labelled audit events) from `TranscriptStore` (conversation messages). Additionally, `TaskEvent.run` relationship is often `nil` for non-worker events, making per-run filtering unreliable.

**Changes**:

### 5a. Add event categories
- Add `category: String` property to `TaskEvent` with values:
  - `"lifecycle"` — task.started, task.completed, task.cancelled, task.retried, task.resumed, task.approved
  - `"conversation"` — user.message, agent.response, agent.thinking
  - `"tool"` — tool.use, permission.denied
  - `"system"` — error, budget.exceeded, task.stats, task.chained
  - `"team"` — team.created, team.deleted, team.message, team.agent.started, team.agent.completed
- Populate automatically based on `type` string (computed or set at creation).

### 5b. Activity tab filtering
- Add filter chips at the top of the Activity tab: All | Conversation | Tools | Lifecycle | Errors
- Default to "All" but remember user's last selection per task.
- Counts on each chip (e.g., "Tools (12)").

### 5c. Ensure `run` relationship is set for all worker-created events
- In `ClaudeCodeWorker.execute()` and `continueSession()`, pass the current `TaskRun` to event creation helpers.
- Add convenience: `TaskEvent(task:run:type:payload:)` initializer that sets both.

### 5d. Per-run event grouping in UI
- In the Activity tab, group events by run with collapsible sections: "Run 1 (completed, 45k tokens)" / "Run 2 (resumed, 12k tokens)"
- Each run section shows its duration, token count, and status.

**Files**:
| File | Action |
|------|--------|
| `Models/TaskEvent.swift` | Add `category: String` property with auto-population |
| `Services/ClaudeCodeWorker.swift` | Pass `run` to all event insertions |
| `Views/TaskMainView.swift` | Add filter chips, per-run grouping |

---

## 6. Resume Path Hardening

**Problem**: The `runClaudeResume()` method (line 953) is significantly less robust than `runClaudeProcess()`. It lacks:
- Idle timeout watchdog (a hung resume runs forever)
- Repetition circuit breaker (agent can loop on same tool call)
- Budget enforcement (tokens are never checked against remaining budget)
- Proper error handling for session ID not found

**Changes**:

### 6a. Add idle timeout watchdog to resume
- Extract the watchdog logic from `runClaudeProcess()` (line 929) into a shared helper method.
- Call it from both `runClaudeProcess()` and `runClaudeResume()`.

### 6b. Add repetition circuit breaker to resume
- Extract the repetition detection from `runClaudeProcess()` (line 800) into a shared helper or closure.
- Apply to both paths. Configuration: kill after 8 identical consecutive event signatures.

### 6c. Add budget enforcement to resume
- In `runClaudeResume()`, calculate remaining budget as `task.tokenBudget - task.tokensUsed`.
- Apply the same mid-stream token estimation and termination logic.
- Return proper `budgetExceeded = true` in the `ProcessResult`.

### 6d. Handle stale session IDs
- When `--resume <sessionId>` fails (Claude exits with error about session not found), detect this from stderr or exit code.
- Set a descriptive error event: "Session expired. Starting a fresh run."
- Optionally fall back to a fresh `execute()` with the resume message as the new goal.

### 6e. Extract shared process monitoring
- Create a `ProcessMonitor` struct or helper that encapsulates: token estimation, budget checking, repetition detection, idle timeout.
- Used by both `runClaudeProcess()` and `runClaudeResume()` to eliminate code duplication.

**Files**:
| File | Action |
|------|--------|
| `Services/ClaudeCodeWorker.swift` | Extract `ProcessMonitor`, apply to both run paths |

---

## 7. Task Queue Race Condition Fix

**Problem**: `processQueue()` (line 102) has a potential race condition. It fetches queued tasks, dispatches the first one via `Task {}`, then sleeps 100ms hoping the task flips to `.running` before the next fetch. If SwiftData flush takes longer, the same task could be dispatched twice.

**Changes**:

### 7a. Track dispatched task IDs
- Maintain a `Set<UUID>` of dispatched-but-not-yet-running task IDs in `TaskQueue`.
- Before dispatching, check if the task ID is already in this set.
- Add to the set before `Task {}`, remove when the worker confirms running.

### 7b. Replace polling with continuation
- Instead of `try await Task.sleep(for: .milliseconds(100))`, use a `CheckedContinuation` or `AsyncStream` to signal when a worker starts running.
- The worker calls `onStarted()` callback after setting `isRunning = true`, which resumes the queue loop.

### 7c. Dynamic pool sizing
- Currently `poolSize` is read once from `UserDefaults` at startup. Add `resizePool(to:)` on `TaskQueue` that adds/removes workers at runtime.
- Wire to Settings so changing pool size takes effect immediately.

**Files**:
| File | Action |
|------|--------|
| `Services/TaskQueue.swift` | Add dispatch tracking set, replace polling, add `resizePool()` |
| `Services/ClaudeCodeWorker.swift` | Add `onStarted` callback |

---

## 8. Artifact Versioning & Cleanup

**Problem**: `Artifact.version` is always `1` and never incremented. When the same file is edited multiple times in a task, each edit creates a new Artifact record but all have `version = 1`. Additionally, `IsolationService.cleanup()` is a no-op — git branches and workspace copies are never cleaned up.

**Changes**:

### 8a. Implement artifact versioning
- In `ClaudeCodeWorker`, when creating an `Artifact`, query existing artifacts for the same `path` on the same task.
- If found, increment `version` to `max(existing.version) + 1`.
- In the Artifacts tab, group by path and show version history with diffs between versions.

### 8b. Add isolation cleanup
- `IsolationStrategy.gitBranch`: After task completion, offer to merge the branch back to the original branch or delete it. Add a "Merge Branch" button in the task detail view.
- `IsolationStrategy.copy`: After task completion, show a "Delete Copy" button that removes the workspace copy.
- Add a workspace-level "Clean Up" command that lists all `astra/*` branches and copy directories, letting the user delete them in bulk.

### 8c. Stale artifact detection
- After a task completes, check if artifact files still exist on disk (they may have been reverted by git or deleted).
- Mark stale artifacts with a warning badge in the Artifacts tab.

**Files**:
| File | Action |
|------|--------|
| `Services/ClaudeCodeWorker.swift` | Query existing artifacts for version increment |
| `Services/IsolationService.swift` | Implement real cleanup with user confirmation |
| `Views/TaskMainView.swift` | Add version history in Artifacts tab, cleanup buttons |
| `Models/Artifact.swift` | Add `isStale: Bool` computed property |

---

## Implementation Priority

| Priority | Improvement | Impact | Effort |
|----------|------------|--------|--------|
| P0 | 6. Resume Path Hardening | Critical — hung resumes and no budget enforcement are bugs | Medium |
| P0 | 7a. Queue Race Condition Fix | Critical — can dispatch same task twice | Small |
| P1 | 2. Turn Limits & Budget Controls | High — gives users fine-grained control | Medium |
| P1 | 3. Permission Denial Tracking | High — explains why tasks stall | Medium |
| P1 | 1. Message Compaction | High — prevents memory bloat on long tasks | Medium |
| P2 | 5. Session History & Audit Trail | Medium — improves debugging and task review | Large |
| P2 | 4. Structured Output for SpecEngine | Medium — reduces spec extraction failures | Small |
| P3 | 8. Artifact Versioning & Cleanup | Low — cosmetic and housekeeping | Medium |

---

## Dependencies

- **6 before 2**: Resume hardening (shared `ProcessMonitor`) should be done before adding turn limits, since turn limits need the same monitoring infrastructure.
- **5a before 5b**: Event categories must exist before filter UI can be built.
- **1a before 1c**: Compaction reduces the event count that lazy loading needs to handle.

---

## Testing Strategy

Each improvement should include:
1. **Unit test** for the core logic (e.g., compaction threshold, turn counting, budget math)
2. **Integration test** with a mock Claude process that emits known stream events
3. **Manual UI test** to verify visual changes (activity tab filters, permission cards, etc.)

Existing test files in `Tests/` provide patterns for `StreamEventParser`, `ClaudeCodeWorker`, and integration tests.

---

## Files Summary

| File | Changes From |
|------|-------------|
| `Models/AgentTask.swift` | 2a |
| `Models/TaskRun.swift` | 2d |
| `Models/TaskEvent.swift` | 1a, 5a, 5c |
| `Models/Artifact.swift` | 8c |
| `Services/ClaudeCodeWorker.swift` | 1a, 1b, 2a, 2b, 3a, 5c, 6a-e, 8a |
| `Services/StreamEventParser.swift` | 3a |
| `Services/SpecEngine.swift` | 4a, 4b, 4c |
| `Services/TaskQueue.swift` | 7a, 7b, 7c |
| `Services/IsolationService.swift` | 8b |
| `Views/TaskMainView.swift` | 1c, 2c, 3b, 3c, 5b, 5d, 8a, 8b |
| `Views/ChatPanelView.swift` | 2c |
