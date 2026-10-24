# Shared runtime supervision: investigation and status

## Shipped scope

The shared process runner supervises Claude Code, Codex, Copilot, Antigravity,
Cursor and OpenCode. Silence triggers an independent model investigation before
the inactivity watchdog stops the provider. The provider keeps running while
that bounded investigation runs. Existing budget, policy, cancellation, terminal
reaping and wall-clock limits remain authoritative.

This stage does **not** automatically restart a provider. Signalling a local
process group does not establish that escaped descendants or remote jobs have
stopped. A model verdict is not permission to start a second writer.

## Flow and ownership

1. `AgentProcessMonitor` observes parsed progress, raw stream volume, active tools
   and managed-job heartbeats. Raw bytes alone do not reset the supervisor clock.
   Existing silence thresholds determine when investigation is due, including
   the longer active-tool window and managed-job heartbeat deadline.
2. `RuntimeSupervisionSession` owns one process attempt's transient investigation.
   It collects bounded file metadata and asks the configured **Verifier** role in
   a separate utility process. It never enters the normal task execution queue.
3. The model returns a typed assessment: progressing, waiting, suspected stalled,
   or inconclusive. Progress extensions require recent file evidence; known-wait
   extensions require an open tool or managed job. Neither proves useful progress.
   Responses may contain plain JSON or one complete JSON Markdown fence; prose,
   multiple blocks, invalid fields and oversized responses remain rejected.
4. The monitor rechecks the progress revision before accepting a stop. New parsed
   progress or a renewed managed-job heartbeat invalidates an older verdict.
   A suspected-stall result also rechecks file metadata within the same absolute
   deadline. New changes or degraded coverage invalidate that old verdict and
   produce an inconclusive update rather than claiming verified progress.
   Cancellation and process completion cancel the investigation. A late result
   cannot change a later attempt or buy time after its absolute deadline.
5. The event sink writes `runtime.supervision` plus a human-readable `system.info`
   message through the existing ordered event queue and persistence coordinator.
   Reports identify the attempt, sequence, configured investigator provider/model,
   observations, assessment and reserved allocation. Save failures use the existing
   persistence audit path. Final task/run state remains owned by worker settlement.

## Evidence and limits

- Evidence: current user request, a redacted 1,200-character output tail, stream
  counts, unknown-frame count, up to eight open tools/jobs, and file size/time
  changes since the attempt baseline or last investigation.
  Stdout and stderr retain separate bounded raw buffers privately so split
  credentials can be redacted before truncation or persistence.
- Local files: task-folder artifacts and dirty/untracked files under the active
  Git workspace. Small non-Git workspaces use a bounded metadata scan. No file
  contents are read. Hidden task-folder files are excluded; symlinks are not
  traversed. File activity outside the silence window is excluded.
- Each root is limited to 200 files; subprocess inspections have 2–3 second
  deadlines and capped output. Partial coverage and inaccessible roots are stated.
  The evidence bundle is capped at 8 KiB; it contains at most 20 file deltas.
- Remote files are **not directly inspected**. Reported managed-job state and
  authorized heartbeat/result evidence already consumed by the monitor are
  available. Missing remote coverage is unknown, never proof that work stopped.
- Investigation deadline: 75 seconds including collection. Model utility:
  at most 45 seconds, one model turn, 2,048 generated tokens (including thinking),
  32 KiB combined raw output, 4 KiB final assessment, and a short replacement
  system prompt. At most
  two investigations per uninterrupted quiet episode and two concurrent model
  investigations app-wide. New provider progress resets the episode, while all
  reservations still consume the same run budget. A quiet attempt gets a
  120-second interval after a non-stop verdict.
  Further silence after those bounded checks stops with an explicit inconclusive
  reason; no indefinite timer extensions. The final waiting update states that
  the next deadline stops the attempt unless new provider progress arrives.
- Each admitted investigation reserves 16,384 tokens against the run budget.
  The allocation is conservatively recorded separately as estimated usage because
  utility CLIs do not all expose exact billable usage. It is not an exact token or
  dollar cap. Known sensitive-data admission failures and same-provider
  Antigravity lock conflicts and unsupported verifier providers do not allocate
  model tokens. Hard-stop budgets reject unaffordable reservations; warning-only
  budgets record a warning and retain their configured continuation behavior.
- All six **task** providers remain supervised. This version admits only Claude
  Code as the **investigator**: the other CLIs lack a verified equivalent launch
  contract here. Selecting another Verifier produces an explicit unavailable
  explanation, without launching it or silently switching providers.
- The investigator uses an empty temporary working folder and a dedicated
  observation mode: empty built-in tools, empty strict MCP config plus MCP denial,
  safe mode, no user/project settings, no skills or persisted session, and disabled
  user hooks. The environment contains only authentication and transport inputs.
  Explicit account directories and supported endpoint selectors are retained.
  Unsupported authentication routes or user settings that would otherwise be
  discarded fail admission before reservation, without falling back to a saved
  account. Optional telemetry/error reporting is disabled for observation.
  Claude's administrator-managed policy remains authoritative, including managed
  hooks; this is not a guarantee of zero host side effects. ASTRA does not bypass
  organizational policy or extract OAuth tokens to circumvent that boundary.
  See the [Claude CLI reference](https://code.claude.com/docs/en/cli-reference).
- An enforced OS read boundary applies even when ordinary utility isolation is
  disabled, preserving explicit network denial. Narrow read-only Keychain and
  Vertex ADC paths retain authentication access. No task MCP/capability manifest
  is supplied. Evidence is untrusted data; investigation is not recursively
  supervised. Older CLIs that reject the isolation flags fail closed.
- An unavailable/malformed/overloaded investigator produces an inconclusive
  status. A same-provider Antigravity verifier is unavailable because it shares
  the main run's model-settings lock; select another Verifier provider.
- No conversational status prompt is sent to a running provider: current adapters
  do not expose a uniform, proven non-mutating status-query contract.

## Safe automatic recovery: next stage

Recovery requires a typed, durable operation separate from the model assessment:

1. Fence the old attempt and durably record recovery intent and an idempotency key.
2. Obtain an adapter-specific cleanup receipt covering local descendants and any
   remote job leases. Unknown cleanup blocks automatic relaunch.
3. Establish whether unfinished tool actions are replayable or have committed
   side effects. File timestamps and a model's confidence are insufficient.
4. Select a supported continuation/checkpoint, retain remaining token/turn/time
   limits, and launch at most one replacement attempt under the existing run owner.
5. Reconcile an app crash at each step without creating a duplicate writer; expose
   the reason when recovery needs user action.

Current adapters cannot prove all these conditions, so this PR preserves partial
work and settles the attempt with a clear error instead of auto-restarting.

## Verification

`RuntimeSupervisionTests`, `RuntimeSupervisionProcessTests` and
`RuntimeSupervisionWorkerTests` and `RuntimeSupervisionReviewRegressionTests`
exercise deadlines, stale answers, fresh versus
stale file evidence, renewed managed jobs, cancellation before launch, the shared
six-provider process path, output limits, isolated model utility fixtures and
durable worker settlement, stream redaction, network policy, warning budgets,
auth projection and actual observation argv. These are controlled CLI tests, not authenticated
live-provider acceptance tests. Required runtime/full-suite, hooks, native Dev
startup and CI results are recorded on the PR.
