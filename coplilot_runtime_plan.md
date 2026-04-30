# Copilot Runtime Plan

This plan adds GitHub Copilot CLI as a second ASTRA agent runtime while moving the current Claude-specific execution path toward a provider-neutral runtime layer. The goal is to let ASTRA run tasks through Claude Code, Copilot CLI, and future local/API providers without duplicating queueing, persistence, isolation, validation, or UI logic.

## Scope

- In: runtime abstraction, Copilot CLI preflight, programmatic JSONL execution, normalized event parsing, permissions, settings, tests, and guarded rollout.
- In: an ACP-compatible design path so ASTRA can later talk to `copilot --acp --stdio` without reshaping the app.
- Out: replacing Claude Code, building a native local model tool loop in the same pass, embedding libghostty, or depending on Copilot's interactive terminal UI.

## Current Constraints

- `TaskQueue` owns a pool of `ClaudeCodeWorker` instances, so the worker type is currently the runtime boundary.
- `ClaudeCodeWorker` handles too much at once: CLI detection, process launch, prompt construction, event persistence, validation routing, file-change extraction, budget monitoring, cancellation, and session history.
- `StreamEventParser` is Claude stream-json specific and maps directly to shared task events.
- Settings and onboarding assume `claudePath`, Claude model IDs, and `CommonCLIPrerequisites.claude`.
- Some follow-up flows still call Claude directly through `SpecEngine` and `ValidationService.aiCheck`.

## Target Architecture

```text
TaskQueue
  -> AgentWorker
      -> AgentRuntime
          -> ClaudeCodeRuntime
          -> CopilotCLIRuntime
          -> ACPAgentRuntime
          -> FutureNativeModelRuntime
```

`TaskQueue` should only know how to assign work, track active tasks, cancel work, and route completed tasks. Runtime-specific behavior should live behind `AgentRuntime`.

## Proposed Types

- `AgentRuntime`: protocol for `preflight`, `execute`, `continueSession`, and `cancel`.
- `AgentRunRequest`: task ID, prompt, workspace path, model, permissions, environment, token/max-turn settings, validation strategy, and session metadata.
- `AgentRunResult`: exit status, stop reason, timeout/budget flags, stderr, and provider session ID.
- `AgentEvent`: normalized event stream used by SwiftData persistence and UI.
- `AgentRuntimeDescriptor`: user-visible provider metadata, supported modes, install/auth hints, default models, and capability flags.
- `AgentRuntimeRegistry`: creates runtime instances from settings and exposes available providers to onboarding/settings.

## Runtime Event Model

Normalize provider output into these events before touching SwiftData:

- `started(sessionID:model:)`
- `thinking(text:)`
- `text(text:)`
- `toolUse(name:id:input:)`
- `toolResult(id:content:)`
- `fileChange(path:kind:summary:)`
- `permissionRequested(tool:reason:)`
- `stats(inputTokens:outputTokens:costUSD:durationMs:turns:)`
- `completed(summary:)`
- `failed(message:)`
- `unknown(provider:type:raw:)`

Claude and Copilot parsers can keep provider-specific structs, but only normalized events should cross into `AgentWorker`.

## Copilot CLI Strategy

Use the standalone `copilot` binary, not `gh copilot`, as the primary executable. GitHub documents `gh copilot` as a preview wrapper that can run or download Copilot CLI, while `copilot` has the direct programmatic and ACP surfaces ASTRA needs.

Initial command shape:

```bash
copilot \
  --prompt "<ASTRA prompt>" \
  --output-format=json \
  --stream=on \
  --model "<selected model>" \
  --no-ask-user \
  --allow-tool="read,write,shell(git:*),shell(swift:*),shell(./script/*)" \
  --secret-env-vars="ANTHROPIC_API_KEY,OPENAI_API_KEY,COPILOT_PROVIDER_API_KEY"
```

Use `COPILOT_HOME` to isolate ASTRA channels:

- Dev: `~/Library/Application Support/AstraDev/Copilot`
- Prod: `~/Library/Application Support/Astra/Copilot`

Use `COPILOT_MODEL` only as a fallback. Prefer explicit `--model` for reproducible task runs.

## ACP Strategy

Treat ACP as the long-term transport, but keep it behind the same runtime protocol:

```bash
copilot --acp --stdio
```

The ACP adapter should own NDJSON transport, initialize sessions with `cwd`, stream `sessionUpdate` messages, answer permission requests through ASTRA's permission policy, and map ACP stop reasons into `AgentRunResult`.

Because ACP support is public preview, do not make it the only Copilot integration until ASTRA has compatibility tests against pinned Copilot CLI versions.

## Implementation Checklist

### 1. Discovery And Compatibility

- [ ] Capture current `copilot --version`, `copilot help`, and `copilot help permissions` behavior on macOS arm64.
- [ ] Verify `copilot --prompt ... --output-format=json --stream=on` emits stable JSONL for text, tool use, tool results, permissions, stats, and failures.
- [ ] Verify `copilot --acp --stdio` can start, initialize, create a session, run one prompt, stream updates, and terminate cleanly.
- [ ] Document the minimum supported Copilot CLI version in code and settings copy.
- [ ] Add install/auth hints for `copilot`, including `brew install copilot-cli`, `npm install -g @github/copilot`, and GitHub login/PAT options.

### 2. Runtime Abstraction

- [ ] Add `AgentRuntime`, `AgentRunRequest`, `AgentRunResult`, `AgentEvent`, and `AgentRuntimeDescriptor` in `ASTRACore` if they are pure types.
- [ ] Add `AgentRuntimeRegistry` in `Astra/Services` to resolve the selected provider from settings.
- [ ] Refactor `ClaudeCodeWorker` into a generic `AgentWorker` while preserving existing behavior through `ClaudeCodeRuntime`.
- [ ] Keep `TaskQueue` worker-pool behavior intact but change the pool type from `ClaudeCodeWorker` to `AgentWorker`.
- [ ] Move process-launch plumbing shared by Claude and Copilot into a reusable async process runner.
- [ ] Move budget, max-turn, idle-timeout, repetition, and cancellation monitoring to provider-neutral code.

### 3. Claude Preservation

- [ ] Keep the existing Claude Code command shape unchanged for the first refactor.
- [ ] Move `StreamEventParser` usage into `ClaudeCodeRuntime`.
- [ ] Preserve Claude-specific file-change extraction for `Write` and `Edit`.
- [ ] Preserve current team/subagent event mapping.
- [ ] Run existing Claude-focused tests before adding Copilot behavior.

### 4. Copilot Runtime

- [ ] Add `CommonCLIPrerequisites.copilot` with binary `copilot` and liveness args `["--version"]`.
- [ ] Add `CopilotCLIRuntime` that launches `copilot` from the selected workspace directory.
- [ ] Build Copilot arguments from `AgentRunRequest`, including `--prompt`, `--output-format=json`, `--stream=on`, `--model`, `--no-ask-user`, permissions, extra directories, and transcript export when enabled.
- [ ] Inject channel-specific `COPILOT_HOME`.
- [ ] Inject `COPILOT_PROVIDER_*` env vars only when the selected runtime config intentionally uses BYOK/local provider mode.
- [ ] Redact configured secret env vars from persisted logs and user-visible failure output.
- [ ] Treat nonzero exits, auth failures, policy-disabled errors, unsupported model errors, malformed JSONL, and missing binary as first-class failure reasons.

### 5. Copilot Event Parsing

- [ ] Add `CopilotStreamEventParser` with fixtures captured from real JSONL output.
- [ ] Map streamed text chunks into `AgentEvent.text`.
- [ ] Map tool calls and tool results into `AgentEvent.toolUse` and `AgentEvent.toolResult`.
- [ ] Map permission prompts or denied tool usage into `AgentEvent.permissionRequested` or `AgentEvent.failed`.
- [ ] Map token/model/duration stats into `AgentEvent.stats` where present.
- [ ] Map file edits from Copilot JSONL when available; otherwise add a post-run git/worktree diff scanner to recover changed files.
- [ ] Preserve unknown JSON objects as debug/audit events without failing the run.

### 6. Permissions And Isolation

- [ ] Define an ASTRA permission profile to Copilot permission mapping.
- [ ] Start with least privilege: `read`, targeted `write`, selected shell tools, and selected URLs only.
- [ ] Use `--add-dir` for ASTRA additional workspace folders instead of global path access.
- [ ] Avoid `--allow-all` except in an explicitly isolated workspace mode.
- [ ] Ensure Copilot runs inside ASTRA's prepared isolation path, not production workspaces directly.
- [ ] Ensure hook injection and restoration remain Claude-specific unless Copilot has an equivalent safe mechanism.
- [ ] Verify cancellation kills the process tree, not just the parent process.

### 7. Settings And UX

- [ ] Add a provider selector: Claude Code, GitHub Copilot CLI, and future providers.
- [ ] Rename settings concepts from `claudePath` and `defaultModel` to provider-aware settings without breaking existing user defaults.
- [ ] Add Copilot executable path override with auto-detection.
- [ ] Add provider-specific default model selection.
- [ ] Add provider health in onboarding and settings.
- [ ] Show provider/runtime on task detail, run history, and logs.
- [ ] Keep existing Claude defaults for current users.
- [ ] Add copy that explains Copilot CLI uses the user's GitHub/Copilot account and may consume premium requests.

### 8. Session And Resume

- [ ] Store provider runtime ID and provider session ID on each run/task.
- [ ] Preserve current Claude follow-up behavior until provider-neutral resume is complete.
- [ ] For Copilot programmatic mode, first implement fresh follow-up prompts with ASTRA session history.
- [ ] Add native `--resume` support only after reliable session ID capture is proven.
- [ ] For ACP, create and retain ACP session IDs per ASTRA task where possible.
- [ ] Ensure mixed-provider resumes are blocked or explicitly treated as new sessions.

### 9. Validation And AI Check

- [ ] Keep `runTests` validation provider-neutral.
- [ ] Refactor `ValidationService.aiCheck` to use a selected lightweight runtime instead of hard-coding Claude.
- [ ] Keep validation model settings provider-aware.
- [ ] Add a fallback rule: if the task runtime is Copilot but AI-check runtime is unavailable, mark `pendingUser` with a clear message.
- [ ] Ensure validation output is attached to the same run and redacted consistently.

### 10. Testing Checklist

- [ ] Add unit tests for `AgentRuntime` request construction and descriptor registry behavior.
- [ ] Add unit tests for Claude runtime parity against existing stream fixtures.
- [ ] Add unit tests for Copilot JSONL parsing using text, tool use, tool result, permission, stats, error, and malformed-line fixtures.
- [ ] Add unit tests for permission mapping from ASTRA policies to Copilot `--allow-tool`, `--deny-tool`, and `--add-dir` flags.
- [ ] Add unit tests for `COPILOT_HOME` channel isolation.
- [ ] Add unit tests for missing binary, auth failure, policy-disabled, unsupported model, timeout, cancellation, and nonzero exit mapping.
- [ ] Add tests that verify file changes are captured from Copilot event JSON or post-run diff scanning.
- [ ] Add tests for provider-aware settings migration from existing `claudePath` and `defaultModel`.
- [ ] Add queue tests proving mixed runtime workers still respect pool size, task mapping, cancellation, and chained tasks.
- [ ] Add integration tests guarded by an environment flag, such as `ASTRA_ENABLE_COPILOT_INTEGRATION_TESTS=1`, so normal CI does not require a Copilot account.
- [ ] Add one manual verification script that runs a tiny Copilot task in an isolated fixture repo and confirms output, file edit, stats, cancellation, and transcript handling.

### 11. Manual Verification

- [ ] Run `swift test --filter StreamParserTests`.
- [ ] Run `swift test --filter ClaudeCodeWorkerTests` after the Claude runtime extraction.
- [ ] Run `swift test --filter QueueLockTests`.
- [ ] Run new `swift test --filter CopilotRuntimeTests`.
- [ ] Run new `swift test --filter AgentRuntimeTests`.
- [ ] Run full `swift test` before enabling the provider selector by default.
- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] In `ASTRA Dev.app`, configure Copilot CLI and run a read-only summarization task.
- [ ] In `ASTRA Dev.app`, run a small file-editing task in an isolated fixture workspace.
- [ ] Cancel a running Copilot task and verify process termination, task status, and no dangling writes.
- [ ] Trigger an auth failure and verify the user-facing remediation is actionable.
- [ ] Trigger a missing binary and verify onboarding/settings preflight catches it.
- [ ] Verify production channel data is untouched during all development tests.

### 12. Rollout

- [ ] Hide Copilot runtime behind an experimental setting for the first pass.
- [ ] Log provider runtime IDs and stop reasons, but do not log prompt content by default.
- [ ] Add migration code that preserves existing Claude defaults.
- [ ] Add release notes warning that Copilot CLI availability depends on GitHub account/org policy.
- [ ] Keep Claude Code as the default runtime until Copilot has passed manual fixture runs and full tests.
- [ ] Add a quick rollback path: disable Copilot provider selection without changing task persistence.

## Robustness Checklist

- [ ] No runtime-specific parser writes directly to SwiftData.
- [ ] No provider process can run against production workspace paths during development-channel tests.
- [ ] All provider env vars are opt-in, scoped to the child process, and redacted in logs.
- [ ] Missing auth, missing binary, disabled org policy, model unavailable, bad JSONL, and timeout produce distinct user-facing errors.
- [ ] Cancellation kills the process and prevents late events from changing terminal task state.
- [ ] File-change capture works even when provider event schemas change.
- [ ] Existing Claude tasks, schedules, templates, and validation strategies continue working.
- [ ] Provider choice is persisted per task/run so history remains understandable.
- [ ] Mixed-provider continuation is explicit and never silently resumes with the wrong runtime.
- [ ] Tests can run without a Copilot account unless explicitly opted into integration tests.

## Open Questions

- Should ASTRA expose Copilot's BYOK/local-provider mode immediately, or should local providers be implemented as native ASTRA runtimes first?
- Should Copilot be allowed to use its GitHub MCP server by default, or should ASTRA require explicit workspace-level approval?
- Should the first Copilot runtime ship with programmatic JSONL only, or should ACP support be developed in parallel behind a second experimental flag?

## References

- GitHub Copilot CLI overview: https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-copilot-cli
- GitHub Copilot CLI programmatic usage: https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically
- GitHub Copilot CLI command reference: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference
- GitHub Copilot CLI ACP server: https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server
- GitHub Copilot CLI BYOK/local models: https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models
