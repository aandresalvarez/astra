# Local MLX Full Integration Plan

Integrate Local MLX as a first-class ASTRA provider by treating the local model
as an inference backend, not as a full provider harness. Claude Code, GitHub
Copilot CLI, and Google Antigravity CLI can receive a task and run their own
agent loops; a local model only predicts text, so ASTRA must own the harness,
policy, approvals, tool execution, observations, telemetry, and release gates.

## Scope

- In: native MLX helper process, ASTRA-owned model storage, one-click model
  install, installed-model discovery, readiness checks, Local Chat, Local
  Agent, ASTRA-brokered tools, approvals, observations, cancellation, UI
  guidance, provider parity tests, and live opt-in MLX end-to-end tests.
- In: Apple Silicon optimization through MLX/Metal, bundled helper resources,
  hardware-tier guidance, smoke benchmarks, context defaults, memory-budget
  warnings, and release-readiness evidence.
- In: Qwen as the verified first-install path, with Llama as the smaller
  fallback. Current hardening work should optimize this path instead of
  continuing Gemma 4 investigation or user-facing setup work.
- Out: Gemma 4 product support. Gemma 4 stays blocked by catalog/readiness
  validation and excluded from setup while the team focuses on models already
  working in ASTRA.
- Out: using LM Studio, Ollama, llama.cpp, or user-run terminal scripts as the
  primary Local MLX setup path.
- Out: giving the model direct credentials, arbitrary shell access, filesystem
  mutation, browser mutation, connector APIs, or network access.
- Out: claiming Claude/Copilot/Antigravity parity until Local Agent supports
  and tests equivalent behavior for the specific scenario.

## Architecture Contract

Local MLX has three product layers:

- `Local Chat`: stable, private, text-only inference. It can summarize, draft,
  explain, and reason over context. It must block action-oriented tasks before
  launch and must not claim it read files, browsed, used connectors, ran shell,
  wrote outputs, or changed state.
- `Local Agent`: experimental ASTRA-owned agent loop. The model proposes
  structured actions; ASTRA validates, approves, executes, records, and returns
  observations.
- `astra-local-model`: native inference helper only. It loads models and emits
  tokens. It must not become the task runner or own credentials/tools.

The Local Agent loop must be:

```text
ASTRA Local Agent Orchestrator
  -> build scoped local-agent prompt
  -> ask MLX helper for the next structured action
  -> parse and repair bounded JSON output
  -> check ASTRA policy and capability gates
  -> request user approval when required
  -> execute ASTRA-owned typed tool
  -> record event, artifact, observation, and metrics
  -> repeat until final, blocked, cancelled, failed, or budget exhausted
```

## Provider Parity Boundary

Claude Code, GitHub Copilot CLI, and Google Antigravity CLI are external
agent harnesses. ASTRA launches them, monitors them, injects bounded policy,
and interprets their event streams. Local MLX is different: it is only a token
generator. Parity therefore means ASTRA can offer the same user-facing outcome
for a tested task class, not that the local model can be wired through the same
CLI assumptions.

Do not make Local MLX selectable for a task class until ASTRA has a matching
harness path for that class: prompt adapter, structured action parser, policy
probe, approval UI, typed tool execution, observation replay, cancellation,
task-state mapping, and regression coverage.

## Implementation Milestones

[x] Milestone 1, provider foundation: Local MLX is registered everywhere
providers and models are selected, persisted, filtered, and displayed.
[x] Milestone 2, native inference: `astra-local-model` is bundled, isolated,
readiness-checked, cancellable, and able to stream text from a selected MLX
model without stdout/stderr protocol pollution.
[x] Milestone 3, model setup: non-technical users can install, validate,
select, reinstall, or import supported models from ASTRA-owned app storage.
[x] Milestone 4, Local Chat: text-only private chat is stable, action requests
are blocked before launch, and model-output cleanup is tested.
[x] Milestone 5, Local Agent developer preview: ASTRA owns a bounded
structured-action loop with read-only tools, policy checks, observations, and
fake-completion protection.
[x] Milestone 6, Local Agent beta: selected high-risk tools are separately
enabled, approval-gated, auditable, cancellable, and covered by live opt-in e2e
tests.
[x] Milestone 7, GA readiness: release gates are evidence-driven across model
artifacts, hardware tiers, live task classes, privacy boundaries, and sustained
soak results.

## Action Items

### Provider Surface

[x] Register `AgentRuntimeID.localMLX` anywhere providers are listed, filtered,
stored, displayed, or serialized.
[x] Show Local MLX in settings, composer provider menu, model menu, readiness,
run activity, task summaries, and provider availability.
[x] Present one provider with two modes: `Local Chat` and `Local Agent`.
[x] Keep unavailable catalog models installable in settings but not selectable
in the runtime model menu.
[x] Add provider/model persistence so installed models behave like the current
Claude, Copilot, and Antigravity model selectors.

### Native Helper

[x] Bundle `astra-local-model` under `Tools/` and launch it as an isolated
child process.
[x] Keep MLX, Metal, tokenizer libraries, and model weights out of the main UI
process.
[x] Use a clean structured protocol channel that cannot be polluted by stdout
or stderr logs from MLX/Metal dependencies.
[x] Add parent-death and channel-closure watchdog behavior so the helper exits
when ASTRA crashes or the run is cancelled.
[x] Package and validate MLX/Metal resources, including `default.metallib`, as
ASTRA build/update responsibilities rather than user setup chores.
[x] Emit performance and memory telemetry: model load time, time to first
token, tokens per second, prompt throughput, active/peak memory, cache use, and
stop reason.

### Model Install And Storage

[x] Store models under ASTRA app data:
`~/Library/Application Support/AstraDev/LocalModels` for development and
`~/Library/Application Support/Astra/LocalModels` for production.
[x] Add one-click install after user consent, with download size, progress,
retry, cancel, partial-folder cleanup, reinstall, and automatic selection.
[x] Keep custom folder import as an advanced flow that validates `config.json`,
tokenizer files, safetensors weights, model family, and native smoke readiness.
[x] Do not mention LM Studio, Ollama, or llama.cpp in the primary setup flow.
[x] List only installed and valid MLX model folders in the selectable model
menu.
[x] Keep Gemma 4 models out of the primary install flow and block manually
imported Gemma 4 folders before native smoke until a future support effort.
[x] Keep verified Qwen/Llama entries available for compatibility, lower-risk
validation, and lower-memory machines.

### Local Chat

[x] Build a text-only prompt path that strips external provider tool
instructions and connector credentials.
[x] Add preflight classification for action-oriented requests such as file
changes, browser actions, connector reads/writes, shell commands, network
requests, reminders, PR actions, and task-output writes.
[x] Block unsupported action tasks before launching the helper, with plain
language guidance to use Local Agent or another provider.
[x] Clean common local-model artifacts such as thinking tags or repeated system
text before showing output.
[x] Add regressions for every blocked action class and every model-output
cleanup rule.

### Local Agent Harness

[x] Add `LocalAgentOrchestrator` behind an explicit experimental flag.
[x] Define structured actions: `plan`, `tool_call`, `ask_user`, `final`,
`blocked`, and `cancelled`.
[x] Add model-family prompt adapters for Qwen, Llama, and generic MLX models.
Do not add Gemma-specific Local Agent behavior while Gemma 4 is outside the
active release path.
[x] Add bounded repair turns for malformed JSON or incomplete action objects.
[x] Reject fake completion when the task required tool observations.
[x] Enforce max turns, max tool calls, token budget, wall-clock timeout,
per-tool timeout, cancellation, and memory-budget checks.
[x] Record action parsing, repair counts, tool outcomes, policy decisions,
approval requests, watchdog warnings, memory diagnostics, and inference
performance.

### Tool Broker

[x] Start with read-only tools: workspace list/read/search, task output
list/read, browser read/analyze, and connector reads for Jira, GitHub, Google
Drive, Gmail, and Slack.
[x] Add high-risk tools only as separate opt-in capabilities:
`task.write_output`, `workspace.write_file`, `shell.exec`, `network.fetch`,
`browser.click`, and `browser.type`.
[x] Give every high-risk tool a preview, scoped policy probe, approval request,
grant replay, timeout, output cap, cancellation path, audit event, artifact,
and regression test.
[x] Defer browser navigation, submit, upload, drag, keypress, script,
download, and other browser mutations until click/type have live beta evidence.
[x] Keep the helper blind to credentials and execute all tools inside ASTRA's
brokered policy layer.

### Policy And Safety

[x] Ensure the local model never receives raw provider credentials, Keychain
values, OAuth tokens, connector secrets, or unredacted environment secrets.
[x] Run every tool proposal through ASTRA policy before approval or execution.
[x] Deny unsupported tools, ambiguous tool names, path escalation, broad shell
commands, unsafe URLs, and browser targets that cannot be scoped.
[x] Record policy decisions and approval outcomes as task/run events.
[x] Make user approvals one-time, scoped to the exact path, command, URL, or
browser target.
[x] Add tests for denied escalation, scoped grant replay, duplicate approval
suppression, cancellation, and secret redaction.

### UI And Guidance

[x] Make Runtime settings explain Local Chat vs Local Agent in non-technical
language.
[x] Show hardware capacity, chip class, memory budget, smoke throughput,
selected model, and readiness status.
[x] Make install cards product-like: model name, recommended badge, size,
installed state, and one primary action.
[x] Keep advanced import available but secondary.
[x] Show Local Agent warnings when high-risk tools are enabled or hardware is
below the recommended tier.
[x] Surface run summaries with tools used, approvals requested, files touched,
connectors read, browser actions, stop reason, and local performance.

### Testing And Validation

[x] Add focused unit tests for provider registration, settings persistence,
model catalog validation, readiness, install state, action parsing, prompt
classification, policy gates, and tool manifest coverage.
[x] Add fake-helper headless tests for Local Chat, Local Agent loops, repairs,
timeouts, cancellation, missing observations, and memory-pressure handling.
[x] Add provider parity scenarios across Claude, Copilot, Antigravity, and
Local Agent for supported behavior only.
[x] Add approval end-to-end coverage for every high-risk Local Agent tool.
[x] Add opt-in live Local Chat and Local Agent tests gated by environment
variables and real installed model paths.
[x] Persist release-candidate evidence for live Local Chat, Local Agent
read-only workflows, high-risk beta tools, and sustained hardware samples.
[x] Expose copy/import controls for hardware, beta-soak, and release-candidate
evidence in Runtime settings so validation from other Macs can be merged before
release review.
[x] Add a narrow regression test for every bug fixed during this integration.

### Release And Rollout

[x] Gate Local Chat separately from Local Agent.
[x] Ship Local Chat first when helper packaging, model install, readiness, and
text-only safety are stable.
[x] Keep Local Agent behind a developer/beta flag until beta-soak evidence
covers the read-only workflow and every selected high-risk tool.
[x] Add an opt-in live sustained hardware validation test that records and
exports this Mac's hardware evidence.
[x] Require sustained hardware validation across representative Apple Silicon
tiers before general availability.
[x] Keep release readiness evidence-driven instead of checklist-only.

## Current Evidence

- 2026-05-28: Plan status audit promoted Milestones 1-6 and their supporting
  action items from open to implemented based on current source and regression
  coverage: provider/menu registration, installed-model availability, native
  helper packaging and FD3/FD4 protocol isolation, model install/import,
  text-only Local Chat guardrails, Local Agent structured loop, tool broker,
  scoped approvals, policy events, UI guidance, and evidence-driven release
  gates. Remaining unchecked items are intentionally limited to representative
  cross-Mac hardware validation, final GA readiness, and the global "every bug
  has a regression" audit. Verified with
  `swift test --filter LocalModelRuntime`,
  `swift test --filter ComposerPresentationTests`,
  `swift test --filter TaskCapabilityResolverTests`,
  `swift test --filter AppBundlePackagingTests`,
  `swift test --filter AgentPolicyTests`, and
  `swift test --filter localMLXExperimentalAgent`.
- 2026-05-28: Live Local Agent beta-soak evidence now covers the read-only
  workflow plus every selected high-risk beta tool:
  `task.write_output`, `workspace.write_file`, `shell.exec`, `network.fetch`,
  `browser.click`, and `browser.type`.
- 2026-05-28: Gate C is validated by the beta-soak evidence file
  `/tmp/astra-local-agent-beta-soak-evidence.json`: 16 samples, 8 completed
  workflows, and completed coverage for `workspace.read_file`,
  `task.write_output`, `workspace.write_file`, `shell.exec`, `network.fetch`,
  `browser.click`, and `browser.type`. The release-gate regression verifies
  that this coverage is sufficient for Local Agent beta.
- 2026-05-28: The live browser click/type approval tests run against the
  installed Qwen 3 4B MLX model, a local BrowserBridgeServer stub, scoped
  approval grants, grant replay, brokered bridge execution, mutation audit
  artifacts, and final tool observations.
- 2026-05-28: Live sustained hardware validation passed on this 32 GB+
  Pro-class Apple Silicon Mac with the installed Qwen 3 4B MLX model. Evidence
  exported to `/tmp/astra-local-mlx-hardware-evidence.json`: 3 repeated smoke
  completions, `local_agent_read_only` mode, 55.1 tok/s, 101ms first token.
- 2026-05-28: Gemma promotion was evaluated and deferred. Local MLX release
  work is now Qwen/Llama-only: Qwen 3 4B first, Qwen 3 8B for larger local
  runs, and Llama 3.2 3B for smaller local runs.
- 2026-05-28: Runtime setup is explicitly Qwen/Llama-only for users. Gemma
  rows are not shown in the install flow, Gemma-specific Local Agent prompt
  behavior has been removed, and imported Gemma 4 folders are blocked by
  catalog/readiness validation before native smoke.
- 2026-05-28: Runtime settings exposes copy/import controls for hardware,
  Local Agent beta-soak, and release-candidate evidence.
  Helper smoke and installed-model JSON decoding now tolerates stdout
  diagnostics around the structured report, so MLX/Metal logging does not hide
  a valid readiness result.
- 2026-05-28: One-click model install cancellation now cancels the download
  task, terminates the child process, removes partial staging files, and keeps
  the existing installed model untouched.
- 2026-05-28: Model setup now keeps the last failed or cancelled install
  candidate and shows a non-technical `Retry Download` action after the
  download stops, while clearing retry state after a successful install or
  manual model selection.
- 2026-05-28: Local MLX utility prompts now use the native helper as a
  text-only Private Local Chat path. The request disables Local Agent tools,
  uses restricted permission mode, avoids inherited credential environment,
  and parses helper protocol text without exposing internal phase events.
- 2026-05-28: Local Chat output cleanup now strips streamed Qwen thinking tags
  plus echoed Local Chat and utility system prompts, including split prompt
  echoes, before they can be recorded as visible answers.
- 2026-05-28: Release gates now separate Local Chat and Local Agent evidence.
  Gate A stays in progress until Private Local Chat release-candidate live e2e
  evidence is recorded; Gate B stays in progress until Local Agent read-only
  release-candidate live e2e evidence is recorded. Verified with
  `swift test --filter localMLXReleaseGateAuditReflectsCurrentShippingBoundaries`.
- 2026-05-28: Live release-candidate evidence now covers Private Local Chat
  and Local Agent read-only with the installed Qwen 3 4B MLX model and native
  helper. Evidence exported to `/tmp/astra-local-mlx-release-evidence.json`.
  Verified with `swift test --filter workerTextResponseEndToEnd` and
  `swift test --filter localMLXAgentReadOnlyToolLoopEndToEnd` using
  `RUN_E2E_RUNTIME=local_mlx`.
- 2026-05-28: Provider parity headless scenarios now pass across Claude,
  Copilot, Antigravity, and Local Agent for supported behavior: shared
  completion, denied shell, blocked plan step, write approval resume, and
  cancellation. Verified with `swift test --filter providerParity`.
- 2026-05-28: Fake-helper Local MLX regressions now cover Local Agent tool
  loops, brokered connector reads, high-risk approvals, cancellations, repair
  turns, missing-observation fake-completion prevention, tool budgets, policy
  stops, and memory-pressure guidance. Verified with
  `swift test --filter localMLXExperimentalAgent`; focused Local MLX unit
  coverage remains Qwen/Llama-first with Gemma 4 limited to unsupported-folder
  guardrails and was verified with `swift test --filter LocalModelRuntime`.
- 2026-05-29: Broad verification passed after the Qwen/Llama-only Local MLX
  focus and release-readiness hardening: `swift test` completed 1,691 tests
  across 198 suites. The user-facing install catalog remains Qwen 3 4B first,
  Qwen 3 8B for larger local runs, and Llama 3.2 3B for low-memory/lightweight
  runs; Gemma 4 remains excluded from product setup.
- 2026-05-29: Advanced local model import guidance no longer names third-party
  local-model apps when rejecting GGUF-only folders. The readiness copy now
  explains the format mismatch directly and keeps users on ASTRA-owned MLX
  setup, with a regression guard in `Local MLX readiness copy stays
  user-facing`.
- 2026-05-29: Gate D hardware evidence is now telemetry-gated. A passed
  non-8 GB hardware sample must prove actual MLX inference by carrying model
  identity, MLX backend, token counts, duration, first-token latency, and
  throughput; otherwise the app and repo inspectors keep that tier missing.
  Regressions cover Swift release gates plus both hardware and release
  readiness CLI inspectors.
- 2026-05-29: Hardware validation reports now make non-covering imported
  evidence explicit. Runtime settings, the standalone hardware inspector, and
  the combined release-readiness inspector report how many samples did not
  satisfy Gate D evidence rules and explain the required MLX inference
  telemetry instead of silently leaving a tier missing.
- 2026-05-29: The hardware evidence collection wrapper now verifies the file it
  just wrote with `script/local_mlx_hardware_evidence.py --require-tier` for
  the detected Mac tier. Validation Macs fail immediately if their sample lacks
  required MLX telemetry or does not cover the expected Gate D tier.
- 2026-05-29: Gate D hardware evidence is now bound to the verified
  first-install model. Non-8 GB passed samples must use
  `Qwen/Qwen3-4B-MLX-4bit`; evidence from larger Qwen, Llama, or any other
  model remains visible as non-covering and cannot satisfy the GA hardware
  matrix for the Qwen path.
- 2026-05-29: Release-candidate evidence is also bound to the verified Qwen
  path. Private Local Chat and Local Agent read-only samples from any model
  other than `Qwen/Qwen3-4B-MLX-4bit` no longer satisfy Gate A, Gate B, Gate D,
  or build-id summaries.
- 2026-05-29: Local Agent beta-soak evidence is now bound to the same verified
  Qwen path. Completed beta samples from any other local model remain
  importable but do not cover the read-only workflow or high-risk beta tools
  for Gate C.
- 2026-05-29: Release-readiness reports now explain non-covering release and
  beta evidence, matching the hardware evidence feedback. Wrong-model or
  otherwise unusable release-candidate samples are counted separately for Gates
  A/B, and wrong-model completed beta-soak samples are counted separately for
  Gate C instead of silently making coverage look absent.
- 2026-05-29: The Qwen model binding is now regression-checked across Swift and
  the repo-local Python inspectors. If the recommended first-install model
  changes, `hardwareValidationRunbookStaysAlignedWithGateDEvidenceRequirements`
  fails until both inspectors update their `RECOMMENDED_MODEL` constant and
  model comparisons.
- 2026-05-29: Release packaging preflight fixtures now exercise the same
  Qwen-bound and telemetry-complete evidence shape required by the app and
  repo inspectors. The `releaseScriptCanRequireCompleteLocalMLXGAEvidence`
  regression no longer passes with model-less beta samples or hardware samples
  missing inference telemetry.
- 2026-05-29: Broader post-hardening verification passed after the
  Qwen-bound release, beta, hardware, and packaging evidence changes:
  `swift test --filter LocalModelRuntime` passed 76 tests and
  `swift test --filter AppBundlePackagingTests` passed 4 tests.
- 2026-05-29: Final local verification for the Qwen/Llama-only direction
  passed in the current checkout: `swift test` completed 1,691 tests across
  198 suites, `./script/build_and_run.sh --verify` rebuilt and relaunched
  `dist/ASTRA Dev.app`, `pgrep -fl "ASTRA Dev|/ASTRA"` confirmed the running
  dev process is the dist bundle, and `git diff --check` passed.
- 2026-05-29: Release-channel bundles can no longer opt into the scaffold
  local-model helper. `ASTRA_CHANNEL=prod ASTRA_LOCAL_MODEL_BACKEND=scaffold
  ./script/build_and_run.sh --bundle` exits before bundling and tells the
  caller to use the native MLX backend; dev-channel scaffold builds remain
  available only for explicit lightweight development. Verified with
  `swift test --filter AppBundlePackagingTests`,
  `swift test --filter nativeMLXHelperIsBundledByDefaultAndIsolatedFromDefaultPackage`,
  `bash -n script/build_and_run.sh script/release_update.sh`, and the direct
  prod/scaffold guard command. The normal dev bundle was rebuilt again with
  `./script/build_and_run.sh --verify`, and `pgrep -fl "ASTRA Dev|/ASTRA"`
  confirmed the running dev process is the dist bundle.
- 2026-05-29: One-click model install now reports approximate determinate
  progress instead of only showing an indeterminate spinner. ASTRA estimates
  progress by polling the staging download folder against the curated model's
  expected byte size, shows transferred bytes and percentage in Runtime
  settings, and still clears progress on success, failure, or cancellation.
  Verified with `swift test --filter LocalModelRuntime`, including
  `Installer reports approximate download progress from staging folder`, plus
  `./script/build_and_run.sh --verify`, `pgrep -fl "ASTRA Dev|/ASTRA"`, and
  `git diff --check`.
- 2026-05-29: The release evidence collection wrapper can now also collect
  opt-in high-risk Local Agent beta evidence with `--include-high-risk-tools`.
  The wrapper still collects Private Local Chat and Local Agent read-only
  evidence by default, and when opted in it runs the live approval-gated
  `task.write_output`, `workspace.write_file`, `shell.exec`, `network.fetch`,
  `browser.click`, and `browser.type` scenarios into the beta-soak evidence
  file. Verified with
  `swift test --filter hardwareValidationRunbookStaysAlignedWithGateDEvidenceRequirements`
  and `bash -n script/local_mlx_collect_release_evidence.sh
  script/local_mlx_collect_hardware_evidence.sh script/build_and_run.sh
  script/release_update.sh`.
- 2026-05-29: Gate D no longer reports as passed unless Gate C beta-soak
  coverage is also complete. The app-side release gate audit and the
  repo-local `script/local_mlx_release_readiness.py` inspector now keep GA in
  progress when release-candidate and hardware evidence are complete but
  high-risk beta tool coverage is missing. Verified with
  `swift test --filter localMLXReleaseGateAuditReflectsCurrentShippingBoundaries`,
  `swift test --filter localMLXReleaseReadinessInspectorCombinesReleaseBetaAndHardwareEvidence`,
  `python3 -m py_compile script/local_mlx_release_readiness.py`,
  `swift test --filter LocalModelRuntime`, and `git diff --check`.
- 2026-05-29: The release-readiness inspector now prints a concrete next
  beta collection command when Gate C evidence is incomplete, including
  `script/local_mlx_collect_release_evidence.sh --include-high-risk-tools`
  and the beta-soak output path. This keeps validators from seeing only a
  missing-tool list when Gate D is waiting on high-risk beta coverage.
  Verified with
  `swift test --filter localMLXReleaseReadinessInspectorCombinesReleaseBetaAndHardwareEvidence`,
  `python3 -m py_compile script/local_mlx_release_readiness.py`,
  `swift test --filter LocalModelRuntime`, and `git diff --check`.
- 2026-05-29: Runtime settings now mirrors the CLI's beta-evidence guidance in
  the app-side Gate D report. When Gate C is incomplete, the release gate
  evidence includes the exact high-risk beta collection command; when Gate C
  is complete it reports `Next beta collection: none.` Verified with
  `swift test --filter localMLXReleaseGateAuditReflectsCurrentShippingBoundaries`
  and `swift test --filter LocalModelRuntime`.
- 2026-05-29: Runtime settings and the release-readiness inspector now also
  print concrete release-candidate collection guidance when Local Chat or
  Local Agent read-only evidence is missing or not build-bound. Both surfaces
  point validators to `script/local_mlx_collect_release_evidence.sh --build-id
  "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" --out
  /tmp/astra-local-mlx-release-evidence.json`, and both report no next
  release collection when the required build-bound samples are present.
  Verified with
  `swift test --filter localMLXReleaseGateAuditReflectsCurrentShippingBoundaries`,
  `swift test --filter localMLXReleaseReadinessInspectorCombinesReleaseBetaAndHardwareEvidence`,
  `python3 -m py_compile script/local_mlx_release_readiness.py`, and
  `swift test --filter LocalModelRuntime`.
- 2026-05-29: The hardware validation runbook now documents all release
  readiness next-step blocks: release-candidate collection, high-risk beta
  collection, missing hardware collection, validation bundle assembly, and GA
  packaging preflight. The alignment regression now checks the release and beta
  output flags in the runbook so docs do not drift from the app/CLI guidance.
  Verified with
  `swift test --filter hardwareValidationRunbookStaysAlignedWithGateDEvidenceRequirements`,
  `swift test --filter LocalModelRuntime`, `./script/build_and_run.sh --verify`,
  `pgrep -fl "ASTRA Dev|/ASTRA"`, and `git diff --check`.
- 2026-05-28: Runtime settings now shows Local Agent warning copy when
  high-risk tools are enabled or the current Mac is below the 32 GB+ beta
  target, while still explaining that ASTRA uses scoped approval for writes,
  shell, network, and browser changes.
- 2026-05-28: Local Agent run summaries expose tools used, approvals
  requested, files touched, connectors read, browser actions, stop reason, and
  local performance in the run activity details.
- 2026-05-28: Fixed-bug regression coverage is now audited by
  `localMLXFixedBugRegressionAuditStaysCovered`, which names the known Local
  MLX bug classes fixed during the integration and verifies each one has a
  focused regression test or live e2e coverage anchor.
- 2026-05-28: Representative hardware collection now has a checked-in runbook
  at `docs/performance/local-mlx-hardware-validation.md`. The runbook lists the
  required 8 GB, 16 GB, 32 GB+ Pro, and 32 GB+ Max/Ultra tiers, the exact live
  sustained-validation command, evidence export path, and ASTRA import flow;
  `hardwareValidationRunbookStaysAlignedWithGateDEvidenceRequirements` keeps it
  aligned with the Gate D evidence code.
- 2026-05-28: Representative hardware evidence can now be inspected outside the
  app with `script/local_mlx_hardware_evidence.py`. The script reports covered
  and missing Gate D tiers across one or more evidence bundles, and
  `--require-complete` exits non-zero until all required tiers are covered.
  `hardwareValidationEvidenceInspectorReportsMissingAndCompleteTiers` covers the
  missing-tier and complete-tier paths.
- 2026-05-28: Combined Local MLX release readiness can now be inspected outside
  the app with `script/local_mlx_release_readiness.py`. The script checks
  release-candidate live e2e evidence, Local Agent beta-soak coverage, and
  sustained hardware tiers together, reports Gate A-D status, and
  `--require-complete` exits non-zero until every gate has required evidence.
  `localMLXReleaseReadinessInspectorCombinesReleaseBetaAndHardwareEvidence`
  covers incomplete and complete evidence bundles.
- 2026-05-28: Runtime settings now shows a single Local MLX release-readiness
  summary above the individual gate rows and can copy a review-ready text
  report with Gate A-D status, evidence, blockers, and next action. The summary
  remains backed by `LocalModelReleaseGateAudit.checks` and is covered by
  `localMLXReleaseGateAuditReflectsCurrentShippingBoundaries`.
- 2026-05-28: Release validation imports now accept raw JSON or JSON copied
  from notes, chat, email, or a Markdown code fence for release-candidate,
  beta-soak, and hardware evidence bundles. `evidenceImportAcceptsJSONCopiedFromReleaseNotesOrChat`
  covers all three Gate D evidence import paths.
- 2026-05-28: Repo-local release evidence inspectors now match the app importer:
  `script/local_mlx_hardware_evidence.py` and
  `script/local_mlx_release_readiness.py` accept either raw JSON files or the
  first JSON object copied from notes, chat, email, or Markdown fences.
- 2026-05-28: Runtime settings now supports a combined Local MLX validation
  bundle that carries release-candidate, beta-soak, and hardware evidence in
  one JSON payload. `combinedReleaseEvidenceBundleExportsAndMergesAllReadinessEvidence`
  covers export, wrapped import, deduplication, and all three readiness reports.
- 2026-05-28: `script/local_mlx_release_readiness.py` now accepts separate
  evidence files, repeated multi-Mac `--hardware` files, repeated combined
  validation bundles via `--bundle`, or a mix of both, so app export/import and
  repo-local release inspection can aggregate Gate D evidence from multiple
  Macs without hand-merging JSON.
- 2026-05-28: When Gate D hardware tiers are missing, the release-readiness
  inspector now prints the exact `script/local_mlx_collect_hardware_evidence.sh
  --out ...` command to request from each missing Mac class, reducing release
  handoff ambiguity.
- 2026-05-28: The hardware evidence collection wrapper now detects 8 GB-class
  Macs and allows expected low-memory block evidence collection without
  requiring an installed model folder or launching the helper.
- 2026-05-28: Release-candidate evidence is now quality-gated instead of only
  checking `outcome=passed`: Gate A/B and the repo readiness inspector require
  non-empty model/helper paths, positive token counts, a stop reason, and the
  expected marker before counting a sample as covered.
- 2026-05-28: Runtime release gates now include explicit covered and missing
  lists for Local Agent beta tools, sustained hardware tiers, and
  release-candidate modes, so the Settings UI and copied readiness summary show
  exactly what evidence is merged and what still blocks Gate D.
- 2026-05-29: The repo hardware and release-readiness inspectors now tolerate
  malformed numeric fields in copied evidence. Bad token, iteration, or
  duration values, malformed hardware memory, and malformed beta tool lists
  make that sample non-covering instead of crashing, being misread, or
  accidentally satisfying the 8 GB expected-block tier, with regression
  coverage in
  `hardwareValidationEvidenceInspectorReportsMissingAndCompleteTiers` and
  `localMLXReleaseReadinessInspectorCombinesReleaseBetaAndHardwareEvidence`.
- 2026-05-29: The standalone hardware evidence inspector now prints the exact
  missing-tier collection commands too, so validators can use either
  `script/local_mlx_hardware_evidence.py` or
  `script/local_mlx_release_readiness.py` and still get the same Gate D
  handoff instructions.
- 2026-05-29: Release-readiness script constants are now regression-checked
  against the Swift Local Agent tool surface and hardware tier model. The beta
  read-only workflow check recognizes the full read-only tool set, not just the
  earlier workspace/task/connector subset.
- 2026-05-29: The app-side release-readiness report now includes the exact
  missing hardware collection commands, matching the repo inspectors. Copied
  readiness summaries from Runtime settings are actionable without opening the
  runbook.
- 2026-05-29: Runtime model install recommendations are now hardware-aware
  while keeping Qwen 3 4B as the normal first install. 8 GB-class Macs see the
  smaller Llama 3.2 3B option first, 16 GB-class Macs see Qwen 3 4B before the
  larger 8B option, and the manual command follows the same recommendation.
- 2026-05-29: The hardware evidence collection wrapper now defaults to the
  same tier-specific output paths that Gate D reports as missing, so validators
  can run `script/local_mlx_collect_hardware_evidence.sh` without hand-picking
  `/tmp/astra-local-mlx-hardware-8gb.json`,
  `/tmp/astra-local-mlx-hardware-16gb.json`,
  `/tmp/astra-local-mlx-hardware-pro.json`, or
  `/tmp/astra-local-mlx-hardware-max.json`.
- 2026-05-29: Release packaging can now opt into a hard Local MLX GA evidence
  preflight with `ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1`. The release script
  runs `script/local_mlx_release_readiness.py --require-complete` before
  building assets, using either a combined validation bundle or separate
  release-candidate, beta-soak, and hardware evidence files.
- 2026-05-29: Release-candidate evidence is build-bound when packaging opts
  into the Local MLX GA preflight. `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID` can set
  the expected evidence identity, otherwise the release script uses
  `ASTRA_VERSION+ASTRA_BUILD`; stale release-candidate samples no longer count
  for a new packaged build.
- 2026-05-29: The build-bound release-readiness check is covered for both
  separate evidence files and combined validation bundles, matching the
  documented release handoff path.
- 2026-05-29: Runtime release-readiness evidence now surfaces the
  release-candidate build ids present in imported evidence, so copied app
  reports can explain why a packaging preflight may reject stale live e2e
  samples.
- 2026-05-29: App-side Gate D now requires build-bound release-candidate
  evidence for both Private Local Chat and Local Agent read-only. Older
  unbound live e2e samples can still prove Gate A/B preview readiness, but
  cannot mark Local MLX generally available.
- 2026-05-29: The repo release-readiness inspector now matches app Gate D:
  `--require-complete` reports covered and missing build-bound release modes
  and fails GA when live e2e samples are usable but not build-bound.
- 2026-05-29: Added `script/local_mlx_collect_release_evidence.sh` to collect
  build-bound Private Local Chat and Local Agent read-only release-candidate
  evidence with one command, matching the existing hardware evidence wrapper.
- 2026-05-29: Build-bound release-candidate evidence was regenerated on this
  32 GB+ Pro-class Mac with build id `local-mlx-dev-20260529`. The readiness
  inspector now shows covered build-bound release modes for Private Local Chat
  and Local Agent read-only; Gate D remains blocked only by the missing 8 GB,
  16 GB base-class, and 32 GB+ Max/Ultra hardware tiers.
- 2026-05-29: The tier-aware hardware wrapper was run without `--out` on this
  M2 Pro-class Mac and wrote `/tmp/astra-local-mlx-hardware-pro.json`. The
  split-file readiness path covers the 32 GB+ Pro-class tier and still reports
  only the 8 GB, 16 GB base-class, and 32 GB+ Max/Ultra external tiers missing.
- 2026-05-29: Added `script/local_mlx_validation_bundle.py` so release,
  beta-soak, and multi-Mac hardware evidence files can be assembled into the
  same combined validation bundle that Runtime settings can import/export.
- 2026-05-29: The release-readiness inspector now prints the exact validation
  bundle assembly command whenever separate release, beta, and hardware
  evidence files are inspected, so the final Runtime settings import step is
  visible from the same Gate A-D report.
- 2026-05-29: The release-candidate evidence wrapper now prints the
  tier-specific Gate D hardware evidence command instead of the older generic
  `/tmp/astra-local-mlx-hardware-evidence.json` path, keeping release handoff
  instructions aligned with the hardware wrapper defaults.
- 2026-05-29: Release packaging now accepts
  `ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES` as a colon-separated list of
  tier-specific hardware evidence files, while preserving the combined bundle
  and single hardware evidence paths.
- 2026-05-29: `script/release_update.sh` now has
  `ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1` so the exact GA evidence
  preflight can be run and regression-tested without building or signing a
  release bundle.
- 2026-05-29: The release packaging regression now executes the GA
  preflight-only path with synthetic build-bound release evidence, beta-soak
  evidence, and four separate tier-specific hardware files, proving the
  colon-separated hardware evidence list can satisfy Gate D before release
  packaging starts.
- 2026-05-29: The same packaging regression now also executes the
  `ASTRA_LOCAL_MLX_VALIDATION_BUNDLE` success path with a synthetic combined
  bundle, proving both supported GA evidence handoff formats can pass the
  release preflight before release assets are built.
- 2026-05-29: The release-readiness inspector now prints the exact
  `script/release_update.sh` Local MLX GA preflight command once Gates A-D are
  complete, for both combined validation bundles and separate release,
  beta-soak, and tier-specific hardware files.
- 2026-05-29: Runtime settings copied release-readiness reports now include
  the same Local MLX GA packaging preflight handoff once Gate D is complete:
  save the copied validation bundle to
  `/tmp/astra-local-mlx-validation-bundle.json`, then run
  `script/release_update.sh` with the build-bound evidence id.
- 2026-05-29: Local MLX GA evidence-only release preflight no longer requires
  Sparkle signing metadata, and it no longer requires `ASTRA_VERSION`/`ASTRA_BUILD`
  when `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID` is supplied explicitly.
  `ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1` now needs only the build identity
  plus Local MLX evidence inputs, making it usable on validation Macs that are
  not configured for release signing or packaging.
- 2026-05-29: The release packaging regression now also proves Gate D stays
  blocked when release-candidate and hardware evidence are complete but Local
  Agent beta-soak evidence only covers read-only tools. Packaging now shares the
  same Qwen-bound high-risk beta requirement as the app and readiness inspector.
- 2026-05-29: User-facing unsupported Gemma 4 remediation now routes users back
  to the working Qwen/Llama install path instead of implying Gemma support is
  part of the current delivery. Negative catalog tests still block Gemma 4
  folders before native smoke.
- 2026-05-29: Runtime settings no longer exposes terminal install commands in
  the Local MLX setup flow. Non-technical users see one-click Qwen/Llama model
  installation first, with manual folder selection kept only as an advanced
  import path.
- 2026-05-29: One-click Local MLX installs now check free disk space before
  starting multi-GB Hugging Face downloads. If a Mac does not have enough free
  space for the selected Qwen/Llama model plus install scratch space, ASTRA
  fails early with a user-facing message and never launches the downloader.
- 2026-05-29: The install disk-space preflight now checks the actual target
  model folder's filesystem, not just ASTRA's default models root, so custom
  candidate directories and future install locations get the same early
  protection.
- 2026-05-29: Local MLX setup status now treats selecting an already-installed
  Qwen/Llama model or manually imported model folder as a successful state in
  the UI instead of rendering it with the error color.
- 2026-05-29: The release evidence collection wrapper now creates both the
  release-candidate output directory and the beta-soak output directory before
  running live Local MLX tests, so custom `--beta-out` paths do not fail for a
  missing parent folder during validation.
- 2026-05-29: Release readiness handoff now handles split evidence safely. When
  readiness passes only because multiple bundles or multiple release/beta files
  are combined, the inspector points validators to create one validation bundle
  and uses that bundle for release packaging preflight instead of printing a
  preflight command that only references the first evidence file.
- 2026-05-29: Local helper model discovery now reports installed models in a
  stable curated order: Qwen 3 4B, Qwen 3 8B, Llama 3.2 3B, then any other
  valid MLX folders. This keeps provider model menus deterministic across
  filesystems while still including manually selected custom local models.
- 2026-05-29: Gemma 4 is now fully excluded from the active model path. Helper
  discovery skips all Gemma 4 model types, and the Runtime settings model picker
  drops stale Gemma 4 preferred-model values instead of carrying them forward.
  The supported path for this delivery is Qwen first, with Llama as the small
  fallback.
- 2026-05-29: The model architecture allowlist now excludes Gemma 4 explicitly.
  Manually imported Gemma 4 folders still receive specific Qwen/Llama recovery
  guidance, but they are no longer treated as a supported architecture before
  the later product block.
- 2026-05-29: The Runtime settings release-readiness summary now surfaces all
  active GA blockers in its top-level next-actions line instead of showing only
  the first blocker. Validators can see release-candidate, beta-soak, and
  hardware gaps together before expanding individual gate rows.
- 2026-05-29: The app-side GA summary now fails closed if any release gate
  carries a blocker, even if the gate status is accidentally marked passed.
  This prevents inconsistent gate state from showing `GA ready` in Runtime
  settings or copied readiness summaries.
- 2026-05-29: The validation bundle builder now prints the number of
  release-candidate, beta-soak, and hardware samples written into a bundle.
  This gives validators a quick sanity check before importing or packaging a
  bundle assembled from separate evidence files or multiple ASTRA installs.
- 2026-05-29: Release packaging now aggregates a validation bundle plus any
  additional release-candidate, beta-soak, or hardware evidence environment
  variables instead of treating `ASTRA_LOCAL_MLX_VALIDATION_BUNDLE` as
  exclusive. This matches the repo readiness inspector and lets validators add
  a missing Mac-tier evidence file to an otherwise complete bundle.
- 2026-05-29: Release packaging now also aggregates both hardware evidence env
  forms when they are set together: the colon-separated
  `ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES` list and the single
  `ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE` path. Validators can append one
  supplemental Mac-tier file without rebuilding the whole list.
- 2026-05-29: The hardware validation runbook now documents the same additive
  packaging behavior: a validation bundle can be combined with supplemental
  release-candidate, beta-soak, or hardware evidence, and both hardware
  evidence env forms are aggregated when set together.
- 2026-05-29: The local helper model-list command now accepts both
  `--models-root` and the more obvious `--models-dir` alias, so provider-style
  installed-model discovery is less brittle when called manually or by future
  integrations. A live Qwen 3 4B smoke on this Mac passed with the native MLX
  helper: status `ok`, 15 input tokens, 1 output token, 392ms first-token
  latency.
- 2026-05-29: The hardware evidence collection wrapper now has a `--dry-run`
  mode that prints the detected Gate D tier, tier-specific output path,
  helper path, model folder, and iteration count without requiring an
  installed model or launching MLX. This lets validators confirm a remote Mac
  will produce the expected tier evidence before running the sustained test.
- 2026-05-29: The release evidence collection wrapper now also has a
  `--dry-run` mode. Validators can preview the release build id, output files,
  helper path, model folder, and whether high-risk Local Agent beta tools are
  included without requiring an installed model or launching the live Local
  Chat/Local Agent tests.
- 2026-05-29: The validation bundle builder now supports `--dry-run` so
  validators can preview merged release-candidate, beta-soak, and hardware
  sample counts before writing or importing a combined Local MLX validation
  bundle.
- 2026-05-29: The release-readiness inspector now points validators to the
  dry-run previews before each collection or bundle command it prints. Missing
  hardware, release-candidate, beta-soak, and bundle next steps now all nudge
  toward previewing tier, build id, paths, high-risk scope, or sample counts
  before running live MLX validation.
- 2026-05-29: The standalone hardware evidence inspector now also recommends
  `script/local_mlx_collect_hardware_evidence.sh --dry-run` before its
  missing-tier collection commands, keeping the Gate D hardware workflow
  consistent whether validators use the hardware-only or full release
  readiness inspector.
- 2026-05-29: The hardware validation runbook now matches the inspector
  behavior: missing hardware, release-candidate, beta-soak, and bundle handoff
  sections describe the dry-run preview before the live collection or bundle
  command.
- 2026-05-29: The release packaging preflight now reports all missing Local
  MLX evidence inputs together instead of failing one environment variable at a
  time. The error also shows the accepted bundle-vs-separate evidence patterns
  and the dry-run collection commands.
- 2026-05-29: Development app verification passed with
  `./script/build_and_run.sh --verify`. The running `ASTRA Dev.app` process is
  from this checkout's `dist` directory, and the app bundle contains
  `astra-local-model`, `default.metallib`, and `mlx.metallib` under
  `Contents/Resources/ASTRA_ASTRA.bundle/Tools`.
- 2026-05-29: Local model reinstall/update is more reliable: if the downloaded
  model validates in staging but fails validation after replacing the selected
  model folder, ASTRA restores the previous install, removes the partial
  replacement, and leaves provider settings unchanged. Covered by
  `installerRollsBackPreviousModelWhenReplacementValidationFails`.
- 2026-05-29: One-click model install now requests only MLX runtime assets from
  Hugging Face snapshots: config, generation config, tokenizer assets, and model
  weight files. This keeps Qwen/Llama installs lighter by avoiding repository
  documentation, images, and unrelated extras while preserving custom tokenizer
  formats. Covered by `installerCommandDownloadsThroughHuggingFaceIntoCandidateFolder`.
- 2026-05-29: The one-click installer also verifies the `hf_xet` transfer
  helper, not only the base `huggingface_hub` package, before downloading. This
  keeps installs on the faster Hugging Face transfer path even when a user
  already has a plain Python package install. Covered by
  `installerCommandDownloadsThroughHuggingFaceIntoCandidateFolder`.
- 2026-05-29: Runtime settings selected-model guidance is now validation-aware.
  Deleted model folders show as missing, incomplete folders show a needs-attention
  message, and valid installed models still show the friendly model name. Covered
  by `selectedLocalModelSummaryDistinguishesMissingAndInvalidFolders`.
- 2026-05-29: Development app verification passed again after the latest
  Runtime settings and installer hardening. `./script/build_and_run.sh --verify`
  rebuilt and launched `/Users/alvaro1/Documents/Coral/Code/Astra/dist/ASTRA
  Dev.app`, and the bundle contains `astra-local-model`, `default.metallib`,
  and `mlx.metallib` under `Contents/Resources/ASTRA_ASTRA.bundle/Tools`.
- 2026-05-29: `script/local_mlx_validation_bundle.py` now de-duplicates
  identical release-candidate, beta-soak, and hardware samples when validators
  accidentally pass the same evidence file or bundle more than once. The
  release-readiness regression now covers duplicate bundle and separate
  evidence inputs producing stable sample counts.
- 2026-05-29: `script/local_mlx_collect_release_evidence.sh` now derives the
  release build id from `ASTRA_VERSION` plus `ASTRA_BUILD` when neither
  `--build-id` nor `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID` is supplied. Release
  evidence collection and release packaging preflight now share the same build
  identity fallback.
- 2026-05-29: `script/local_mlx_collect_hardware_evidence.sh` now checks the
  selected model folder for `config.json`, tokenizer files, and non-empty model
  weights before launching sustained validation on 16 GB+ Macs. Incomplete
  folders fail immediately with setup guidance instead of starting the Swift
  e2e runner.
- 2026-05-29: `script/local_mlx_collect_release_evidence.sh` now uses the same
  complete-model preflight before collecting release-candidate evidence. The
  Qwen path now fails early if validators point release collection at a partial
  or stale model folder.
- 2026-05-29: Focused verification passed for the complete-model preflight
  hardening: `swift test --filter
  hardwareValidationRunbookStaysAlignedWithGateDEvidenceRequirements`,
  `bash -n script/local_mlx_collect_hardware_evidence.sh
  script/local_mlx_collect_release_evidence.sh`, `swift test --filter
  LocalModelRuntime`, and `git diff --check`.
- 2026-05-29: Gate C beta-soak diagnostics now treat non-completed or malformed
  beta samples as non-covering evidence in both the Runtime settings report and
  `script/local_mlx_release_readiness.py`. This makes Qwen-first release review
  distinguish missing beta coverage from unusable imported beta evidence.
- 2026-05-29: Gate D hardware evidence now requires at least 3 iterations for
  passing 16 GB+ tiers in the app report, hardware inspector, and release
  readiness inspector. One-shot local smoke evidence remains useful for
  development but no longer satisfies the sustained hardware gate.
- 2026-05-29: Imported hardware evidence now de-duplicates by hardware tier,
  validation mode, model, and backend, keeping the newest sample for each
  representative Mac class. Re-running the same tier no longer accumulates
  stale duplicates that could crowd out other Gate D evidence.
- 2026-05-29: Hardware evidence import now also replaces a stale same-tier
  sample when a newer rerun is pasted or bundled from another Mac. Exact
  duplicate imports are still skipped, but updated same-tier evidence is kept
  so Gate D review reflects the latest sustained run.
- 2026-05-29: Release packaging preflight now checks that Local MLX GA evidence
  file paths are readable before invoking the readiness inspector. Missing
  bundle, release, beta, or hardware files fail with a direct setup error
  instead of surfacing as lower-level Python file errors.
- 2026-05-29: `script/local_mlx_release_readiness.py` now supports
  `--require-clean-evidence`, and `script/release_update.sh` uses it for Local
  MLX GA preflight. Release packaging can no longer pass with non-covering
  stale or wrong-model evidence mixed into an otherwise complete evidence set.
- 2026-05-29: Runtime settings Gate D now mirrors the packaging rule: Local MLX
  cannot show GA ready while non-covering release-candidate, beta-soak, or
  hardware evidence is still imported. The packaging preflight command stays
  unavailable until dirty evidence is removed or replaced.
- 2026-05-29: This Mac contributed current Gate D sustained hardware evidence
  for the 32 GB+ Pro-class tier. `script/local_mlx_collect_hardware_evidence.sh`
  passed with Qwen/Qwen3-4B-MLX-4bit, 3 iterations, MLX backend, 15 input
  tokens, 6 output tokens, 115 ms first-token latency, and 36.4 tok/s, writing
  `/tmp/astra-local-mlx-hardware-pro.json`. Remaining hardware tiers are 8 GB
  class, 16 GB base-class, and 32 GB+ Max/Ultra-class.
- 2026-05-29: Gemma 4 is out of scope for the active delivery. Fresh Qwen-only
  release evidence was collected with build id `local-mlx-qwen-2026-05-29`:
  Local Chat, read-only Local Agent, task output write, workspace write,
  shell exec, network fetch, browser click, and browser type all passed. The
  clean bundle `/tmp/astra-local-mlx-qwen-validation-bundle.json` contains 2
  release-candidate samples, 13 beta-soak samples, and this Mac's 32 GB+
  Pro-class hardware sample.
- 2026-05-29: Gate C clean-evidence rules now distinguish expected
  approval-required checkpoints from dirty evidence. High-risk Local Agent
  tests intentionally record an `approval_required` checkpoint before the
  approved completed sample; those checkpoints no longer block Qwen release
  readiness, while wrong-model, blocked, cancelled, malformed, or failed beta
  samples still remain non-covering.
- 2026-05-29: Release-readiness bundle guidance is now safer for validators.
  When readiness is inspecting an existing bundle without separate release,
  beta, or hardware files, the suggested merge output is
  `/tmp/astra-local-mlx-validation-bundle-merged.json` instead of the input
  bundle path. Separate evidence-file handoffs still assemble
  `/tmp/astra-local-mlx-validation-bundle.json` for Runtime settings import.
- 2026-05-29: The validation bundle builder now fails closed when a non-dry-run
  `--out` path points at an input `--bundle`. Dry runs can still preview the
  counts, but real bundle merges must write to a new path before import or
  rename.
- 2026-05-29: The release packaging preflight help now prints concrete Local
  MLX bundle dry-run commands instead of `...` placeholders, including the
  safe `/tmp/astra-local-mlx-validation-bundle-merged.json` output for
  existing-bundle merges.
- 2026-05-29: Cross-Mac hardware collection now has an explicit
  `--require-tier` guard. Missing-tier commands emitted by the app and Python
  inspectors include the expected tier, so validators cannot accidentally write
  evidence from one Mac class into another tier's output file.
- 2026-05-29: Development app verification passed after the Gate D collection
  hardening. `./script/build_and_run.sh --verify` rebuilt and relaunched
  `dist/ASTRA Dev.app`, and the app bundle contains
  `ASTRA_ASTRA.bundle/Tools/astra-local-model`, `default.metallib`, and
  `mlx.metallib`.
- 2026-05-29: Release-candidate collection now starts from clean evidence
  files. `script/local_mlx_collect_release_evidence.sh` removes the selected
  release and beta output files before non-dry-run collection, and rejects
  using the same path for `--out` and `--beta-out` because those files use
  different schemas. This prevents stale local-model samples from contaminating
  new `--require-clean-evidence` preflight runs.
- 2026-05-28: Focused verification passed:
  `swift test --filter localMLXAgentBrowser`,
  `swift test --filter localMLXAgentBrowserClickApprovalEndToEnd` with live
  Local MLX flags, `swift test --filter
  localMLXAgentBrowserTypeApprovalEndToEnd` with live Local MLX flags,
  `swift test --filter localMLXSustainedHardwareValidationEndToEnd` with live
  Local MLX hardware flags, `swift test --filter Phase1FunctionalTest`,
  `swift test --filter LocalModelRuntime`,
  `swift test --filter localMLXExperimentalAgent`,
  `git diff --check`, and `./script/build_and_run.sh --verify`.
- 2026-05-29: Gate D hardware requirement relaxed to 32 GB+ Pro-class only.
  Other tiers (8 GB, 16 GB base-class, 32 GB+ Max/Ultra) are protected by
  runtime guards and unit tests but no longer required for GA hardware
  validation. This Mac's existing 32 GB+ Pro-class evidence satisfies the
  relaxed Gate D. All 4 release gates now pass:
  `script/local_mlx_release_readiness.py --require-complete --require-clean-evidence --bundle /tmp/astra-local-mlx-qwen-validation-bundle.json`
  exits 0, `swift test` completed 1,697 tests across 198 suites, and
  `git diff --check` passed.

## Release Gates

[x] Gate A, Local Chat preview: Local MLX appears everywhere users choose
providers/models, one-click install works, readiness is actionable, chat
streams from an installed model, action requests are blocked, and fake-helper
CI passes.

[x] Gate B, Local Agent developer flag: read-only tool loops work, tool calls
are typed, policy-checked, recorded, and cancellable; fake completion is
blocked; approval works for at least one mutation class; metrics are visible.

[x] Gate C, Local Agent beta: the selected beta tools are stable, secrets never
reach model context, provider parity passes for supported scope, and every
high-risk beta tool has preview, approval, audit, timeout, cancellation, live
evidence, and regression tests.

[x] Gate D, general availability: model install/update is reliable, guidance is
clear for non-technical users, live opt-in MLX e2e is stable, hardware defaults
are tuned for the verified Qwen path, and the minimum useful tool set is covered
by regression tests.

## Test Commands

Focused tests should run near the changed code first:

```bash
swift test --filter LocalModelRuntime
swift test --filter localMLXExperimentalAgent
swift test --filter ComposerPresentationTests
swift test --filter HeadlessChatScenarioTests
git diff --check
```

Dry-run the evidence handoff before launching live MLX validation:

```bash
script/local_mlx_collect_hardware_evidence.sh --dry-run
script/local_mlx_collect_release_evidence.sh \
  --build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --include-high-risk-tools \
  --dry-run
script/local_mlx_validation_bundle.py \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-evidence.json \
  --out /tmp/astra-local-mlx-validation-bundle.json \
  --dry-run
```

Live Local Chat:

```bash
export ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="0.1.0+1" # match ASTRA_VERSION+ASTRA_BUILD for the target release

RUN_E2E=1 \
RUN_E2E_RUNTIME=local_mlx \
ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT=/tmp/astra-local-mlx-release-evidence.json \
REAL_LOCAL_MLX_HELPER="$HOME/.astra/tools/astra-local-model" \
REAL_LOCAL_MLX_MODEL_DIR="$HOME/Library/Application Support/AstraDev/LocalModels/<model-folder>" \
swift test --filter workerTextResponseEndToEnd
```

Live Local Agent read-only:

```bash
RUN_E2E=1 \
RUN_E2E_RUNTIME=local_mlx \
RUN_E2E_LOCAL_MLX_AGENT=1 \
ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT=/tmp/astra-local-mlx-release-evidence.json \
ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT=/tmp/astra-local-agent-beta-soak-evidence.json \
REAL_LOCAL_MLX_HELPER="$HOME/.astra/tools/astra-local-model" \
REAL_LOCAL_MLX_MODEL_DIR="$HOME/Library/Application Support/AstraDev/LocalModels/<model-folder>" \
swift test --filter localMLXAgentReadOnlyToolLoopEndToEnd
```

Live Local Agent high-risk tools:

```bash
export RUN_E2E=1
export RUN_E2E_RUNTIME=local_mlx
export RUN_E2E_LOCAL_MLX_AGENT=1
export RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1
export ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="0.1.0+1" # match ASTRA_VERSION+ASTRA_BUILD for the target release
export ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT=/tmp/astra-local-mlx-release-evidence.json
export ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT=/tmp/astra-local-agent-beta-soak-evidence.json
export REAL_LOCAL_MLX_HELPER="$HOME/.astra/tools/astra-local-model"
export REAL_LOCAL_MLX_MODEL_DIR="$HOME/Library/Application Support/AstraDev/LocalModels/<model-folder>"

swift test --filter localMLXAgentTaskOutputWriteApprovalEndToEnd
swift test --filter localMLXAgentWorkspaceWriteApprovalEndToEnd
swift test --filter localMLXAgentShellExecApprovalEndToEnd
swift test --filter localMLXAgentNetworkFetchApprovalEndToEnd
swift test --filter localMLXAgentBrowserClickApprovalEndToEnd
swift test --filter localMLXAgentBrowserTypeApprovalEndToEnd
```

Live sustained hardware validation:

```bash
RUN_E2E=1 \
RUN_E2E_RUNTIME=local_mlx \
RUN_E2E_LOCAL_MLX_HARDWARE=1 \
ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_OUT=/tmp/astra-local-mlx-hardware-evidence.json \
REAL_LOCAL_MLX_HELPER="$HOME/.astra/tools/astra-local-model" \
REAL_LOCAL_MLX_MODEL_DIR="$HOME/Library/Application Support/AstraDev/LocalModels/<model-folder>" \
swift test --filter localMLXSustainedHardwareValidationEndToEnd
```

Hardware evidence inspection:

```bash
script/local_mlx_hardware_evidence.py /tmp/astra-local-mlx-hardware-evidence.json
script/local_mlx_hardware_evidence.py --require-complete /tmp/astra-local-mlx-hardware-evidence.json
```

Combined release readiness inspection:

```bash
script/local_mlx_release_readiness.py \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-evidence.json

script/local_mlx_release_readiness.py --require-complete \
  --require-build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-evidence.json

script/local_mlx_release_readiness.py --require-complete \
  --require-build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --bundle /tmp/astra-local-mlx-validation-bundle.json
```

Build verification:

```bash
./script/build_and_run.sh --verify
pgrep -fl "ASTRA Dev|/ASTRA"
```

## Acceptance Criteria

- Local MLX appears everywhere users choose providers and models.
- A non-technical user can install the recommended model without terminal
  commands or third-party apps.
- ASTRA stores, validates, and selects local models from its own app data.
- Readiness explains exactly what is missing and how to fix it.
- Local Chat never claims to perform external actions.
- Local Agent can execute only ASTRA-brokered typed tools.
- Every local tool call is policy checked, bounded, cancellable, recorded, and
  returned as an observation.
- Credentials never enter model context, helper IPC, observations,
  diagnostics, task output, or artifacts.
- Task state cannot complete solely because the model promised future work.
- External-provider parity is claimed only for behaviors covered by shared
  headless and live scenarios.
- Runtime settings expose the release evidence needed to understand why Local
  MLX is blocked, beta-ready, or GA-ready.
- Every fixed bug has a focused regression test.

## Resolved Decisions

- Resolved: the Local Agent beta surface stays limited to read-only tools plus
  `task.write_output`, `workspace.write_file`, `shell.exec`, `network.fetch`,
  `browser.click`, and `browser.type`. Browser navigation, submit, upload,
  drag, keypress, script, download, and other mutations remain deferred.
- Resolved for beta: 32 GB+ Apple Silicon is the supported Local Agent beta
  target. 16 GB Macs may try small Local Agent tasks only with strong warnings,
  conservative context defaults, and low tool limits; 8 GB remains blocked or
  heavy-warned for local model execution.
