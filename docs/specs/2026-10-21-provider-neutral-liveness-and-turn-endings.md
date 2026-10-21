# Provider-neutral liveness and truthful turn endings

Status: proposed (2026-10-21). Only slice 1 (Codex `file_change` counts as
progress) is built. The rest waits for the owner to agree to the design.

## Problem

ASTRA decides whether a provider is alive from parsed stdout events alone.
Which event types count as progress is a hand-kept list per provider:
`RuntimeProgressSignals.progressBearingControlTypes` and
`AgentProcessMonitor.progressKind(for:)`
(`Astra/Services/Runtime/AgentProcessSupport.swift:2160`). Anything a parser
drops, half-decodes or classes as `diagnostic` reads as silence. When a
provider changes its output, the list goes stale without any error, and working
agents get killed.

Verified false kills:

- **Antigravity, task 7900335C.** 6 of 57 turns were watchdog kills of a working
  agent. After each agy auto-update ASTRA falls back to plain-text mode and sees
  no tool events at all. agy reports "waiting for background task(s)" only on
  stderr, and stderr never reaches the watchdog
  (`AgentRuntimeProcessRunner.swift:1023-1031` only buffers it). The killed
  10:57 run had 51 steps (ssh, scp, edits) in agy's own conversation store.
- **Codex, run 5642 on task E0F780F8 (Oct 19).**
  - A successful `file_change` became `.fileChange`, which the monitor never
    sees, plus an empty `toolResult`, which counts as `diagnostic`.
  - Codex sends nothing while the model composes an `apply_patch` (about
    2 minutes each), so every patch opened a 180 s semantic-stall window.
  - Reasoning items are only liveness. Unknown item types such as `web_search`
    map to `nil`, not `.unknown`, so the "parser is behind" deferral never sees
    them either.

Truncated turns are recorded as completed. Twelve of 7900335C's 57 turns hit
agy's own 10-minute `--print-timeout`. That flag is fed ASTRA's *idle* timeout
(`AntigravityCLIRuntime.swift:483,788`; the same value becomes the monitor's
`idleTimeoutSeconds` at `AgentRuntimeProcessRunner.swift:945`). agy exits 0
with partial output. `RuntimeTurnOutcomeService.apply` treats any exit 0 as
`.completed` (`:105-107`). The only guard fails a run that has neither output
nor a run-scoped file (`:275-279`). One of those twelve "completed" turns had
0 output characters. Nothing on the run path recognises agy's partial-output
marker; only the readiness probe does
(`AntigravityCLIRuntimeAdapter+Readiness.swift:116-132`).

## Principles

1. **Liveness comes from ground truth, not from a parser.** Evidence is
   anything the provider changes: bytes on stdout or stderr, its own transcript
   file growing, child processes starting or exiting, CPU time of its process
   tree. Parsed events drive the UI. For liveness they are just one more piece
   of evidence. An unknown frame counts as evidence of life.
2. **One question per guard.** The silence watchdog answers only "is it hung?".
   Loops belong to the repetition breaker. Spend belongs to the wall clock
   (`defaultMaxRunSeconds`, 4 h) and the token budget.
3. **ASTRA owns every limit.** Any provider-side limit flag is derived from one
   run-limit policy, and is always at or above ASTRA's own ceiling, so ASTRA's
   guard fires first and ASTRA records why the run ended.
4. **Unknowns default to the safe side.** Unknown activity means alive. An
   ending ASTRA cannot classify means "ended without a result", never
   "completed". Exit 0 alone proves nothing.

## Design

### 1. Activity evidence

The monitor keeps a last-moved time for each evidence source. A source "moves"
when its sample differs from the previous one. The watchdog thread samples every
check interval (≤ 30 s), so the main actor is never involved.

| Source | Moves when | Where it comes from |
| --- | --- | --- |
| Stream | Any stdout or stderr byte. Any parsed event, including thinking, accounting and unknown frames. | Existing `recordStreamVolume`, without the 16 KiB threshold, plus a new stderr hook in `consumeStderr`. Codex `parsedEvent(from:)` forwards `.unknown`. |
| Transcript | The (size, mtime) of the provider's own session files changes. | New `ProviderTranscriptLocator` (see below). |
| Process tree | A descendant starts or exits, or the tree's summed CPU time rises above a calibrated floor. | New `ProcessTreeSampler` in ASTRACore: `proc_listchildpids` walk from the provider pid (the same walk as `SpecEngine.swift:185`) plus `proc_pid_rusage`. The provider already gets its own process group (`ProcessGroupSpawn`); `AgentRuntimeProcessControl` gains an optional `processIdentifier`. |
| Tool in flight | Not a heartbeat. It raises the quiet bound (see §2). | A parsed tool use without its result (today's `activeToolUseIDs`), or a descendant that is not a known helper. Known helpers are ASTRA's own binaries and the MCP server commands ASTRA wrote into the run's provider config. |

`ProviderTranscriptLocator` is a sibling of `ProviderNativeSessionStore`, not
an extension of it. The store answers "can this id be resumed?", and it only
checks Cursor, Antigravity, Copilot and OpenCode. Claude and Codex return
`.present` without touching disk, so they need new paths:

- **Antigravity:** the per-run `--log-file` ASTRA already passes
  (`<task>/diagnostics/antigravity-<RUN8>.log`). This path is known before
  launch, even in plain-text mode. Also `conversations/<id>.db` and its
  `-wal`, once the id is known.
- **Codex:** `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*-<thread_id>.jsonl`, from
  `thread.started`.
- **Claude:** `$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session_id>.jsonl`, from
  the init event.
- **Copilot:** `$COPILOT_HOME/session-state/<id>/events.jsonl`. Check both
  ASTRA's `COPILOT_HOME` and `~/.copilot`.
- **Cursor, OpenCode:** best effort. Process-tree evidence covers them anyway.

A missing or unreadable path is "no evidence", never an error. A run on a
remote or container route has less local evidence. The watchdog logs which
sources were live (`liveness_sources=stream,transcript,process_tree`), so a
degraded run is visible in the log.

The CPU floor needs calibration before it is enforced. A hung Node CLI still
burns a few milliseconds on timers. A Codex run that is receiving a long patch
over SSE burns only a little more. Slice 2 logs per-window CPU deltas at every
watchdog decision. The floor is picked from that data, and until then CPU
evidence is only logged.

### 2. One hang rule

A run is hung when **no evidence source has moved** for its quiet bound:

- `idleTimeoutSeconds`: the user's existing setting, default 600 s;
- `activeToolIdleTimeoutSeconds` (3600 s) while a tool is in flight.

Some silences carry no evidence at all. Codex composing a patch is one: nothing
on stdout, and nothing in its rollout until the patch lands. Those stretches
are covered by this bound being 600 s instead of 180 s.

The graceful-stop ladder stays: close stdin, wait, then signal. Every kill audit
records how long ago each source last moved, and the descendants it saw.

These guards are unchanged: the wall-clock ceiling, the token budget, max
turns, the repetition breaker, the managed-workspace-job heartbeat, policy
stops, and the terminal-progress reap.

These guards are retired, because each one is a parser opinion standing in for
"hung": `provider_no_semantic_progress`, `provider_no_actionable_progress`,
`provider_semantic_progress_stalled`, the 180 s window and its one extension,
the deliverable window (`AgentRuntimeProgressTimeoutPolicy`), and the
unrecognised-traffic deferral (moot once unknown frames are evidence). Their
stop reasons stay decodable for old runs.

Accepted costs:

- A provider that streams thinking forever without acting is no longer stopped
  at about 6 minutes. The token budget or the 4 h ceiling stops it.
- A startup hang (no evidence at all after launch) is caught at 600 s instead
  of about 360 s.

### 3. Run limits owned by ASTRA

`RuntimeRunLimitPolicy` becomes the one owner of a run's limits: the quiet
bounds, the wall-clock ceiling, max turns and the token budget. It replaces
`AgentRuntimeProgressTimeoutPolicy` and the loose `timeoutSeconds` and
`maxRunSeconds` fields on the worker. Adapters stop receiving the idle value.
Instead they get `providerTurnLimitSeconds`, which is the run's remaining
wall-clock budget plus a margin, so it is never below ASTRA's own ceiling.

Today only agy takes a limit flag. Copilot accepts `timeoutSeconds` and ignores
it. Codex, Cursor and OpenCode discard it. Claude's `--max-turns` takes the
task's full `maxTurns`, while the monitor counts the remaining turns; that is
already provider ≥ ASTRA, so it complies.

Two new `ArchitectureFitnessTests` rules:

- no `*CLIRuntime.swift` or `*RuntimeAdapter*.swift` file reads the idle value
  (the launch context's watchdog field) when it builds provider arguments;
- every provider limit flag (`--print-timeout`, `--max-turns`, and any later
  one) takes its value from `RuntimeRunLimitPolicy`.

### 4. Typed turn endings

`RuntimeTurnEnding`, in ASTRACore, is derived once at settlement from
`AgentProcessResult`, the last parsed events and the stderr tail:

| Ending | When | Persisted as |
| --- | --- | --- |
| `completed` | The provider's own terminal event was seen (`result`, `turn.completed`, agy's final), and no cut marker. In plain-text mode: exit 0, non-empty output, and no cut marker. | `RunStatus.completed`, `.completed` |
| `cutByLimit(kind, resumable)` | A provider cut marker: agy "print timeout … returning partial output", Claude `error_max_turns`, or ASTRA's own wall clock. | `RunStatus.cancelled` + `provider_turn_limit` / `provider_run_wall_clock_exceeded` |
| `endedWithoutResult` | Exit 0 in structured mode with no terminal event. | `RunStatus.cancelled` + `ended_without_result` |
| `providerError(kind)` | The provider reports quota, auth or rate limiting (e.g. a Copilot 402 `session.error`), or another failure. | `RunStatus.failed` + `provider_quota` / `provider_auth` / existing reasons |
| `stoppedByASTRA(reason)` | Hang, budget, repetition, policy, user. | Unchanged |

No schema change. An interruption is already stored as `.cancelled` plus a
stop reason (`TaskRunInterruptionSource`). Adding `provider_turn_limit` and
`ended_without_result` to the reasons that `interruptedRunResumeMessage`
accepts (`TaskLifecycleCoordinator.swift:231-257`) gives these runs the
existing native-resume Retry. The run view says "Interrupted: the provider's
turn limit ended this turn" instead of showing a completed answer.

Cut markers are per-provider knowledge again, but a stale marker list fails
safe. A marker ASTRA misses still cannot make a run "completed" in structured
mode, because the terminal event is missing too.

### 5. Optional bounded auto-continue

After a `cutByLimit(resumable: true)` ending, ASTRA may resume the native
session up to N times (proposed: 2) within the same wall-clock budget. Each
attempt is a typed event (`runtime.auto_continue.scheduled`), carrying the
parent run id and the ending, and goes through the existing `TaskTurnRequest`
admission. ASTRA kills, errors and user stops never auto-continue. A plain-text
agy run has no session id, so it can never auto-continue. Once §3 lands,
provider cuts should be rare, so this slice comes last and stays behind a
setting.

## Slices

Each slice is one draft PR from `main` with its own regression tests.

1. **Codex `file_change` counts as progress.** Built. It is the 5642 fix and
   does not depend on the rest.
2. **Evidence, as a veto only.** Stderr bytes, unknown frames, the transcript
   locator and the process-tree sampler. Any moving source defers every silence
   kill, audited as `outcome=deferred_ground_truth_activity`. CPU is logged and
   not enforced. This alone stops the agy and Codex false kills, and it is safe
   on its own: it can only remove kills. The wall clock still bounds every run.
3. **One hang rule.** Replace the semantic branches with §2. Retire their
   tests, and keep the escalation and graceful-stop tests.
4. **`RuntimeRunLimitPolicy` and the fitness rules.** This takes over the agy
   `--print-timeout` fix if the sibling session has not landed it.
5. **Typed turn endings.** The classifier, the agy and Claude cut markers, the
   settlement mapping, the resume eligibility and the run-view wording.
6. **Auto-continue.** Opt-in.

## Open questions for the owner

- Retiring the 180 s semantic window means "busy but unproductive" relies on
  token budgets. Many tasks run with no budget set, so the 4 h ceiling is their
  only bound. Is that acceptable, or should the default token budget change?
- Should a non-helper descendant that sits idle (for example `ssh` waiting on a
  remote job) buy the 1 h tool allowance? Proposed: yes, with the pid and
  command recorded in the audit.
- Should `endedWithoutResult` be shown as interrupted (proposed) or as failed?

## Coordination

- *Stop capping Antigravity turns at 10 minutes* (sibling session) owns the
  `--print-timeout` value and the structured-output re-probe after agy updates.
  Slice 4 generalises its fix instead of redoing it.
- *Managed long-running jobs for SSH remote workspaces* (sibling session)
  touches the managed-job heartbeat, which §2 leaves as its own guard.
