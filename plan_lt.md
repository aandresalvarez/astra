# ASTRA Long-Term Plan: Evidence-Gated Missions

## Plain-English Summary

ASTRA should become the place where a person can safely delegate meaningful work
to agents without babysitting every message.

The core improvement is simple:

- Today, ASTRA can often show that an agent worked.
- The goal is for ASTRA to show what the agent was supposed to prove, what
  evidence was collected, what passed, what failed, and what the next safe
  action is.

For a simple analogy: if an agent is a student doing a project, ASTRA should not
only record "the student said it is done." ASTRA should keep the rubric, the
work, the test results, the teacher review, the remaining mistakes, and the
next assignment.

This is the spirit of the change: move from agent transcripts to auditable
mission evidence.

## Current State After PR #96

PR #96 added important foundations that change the implementation strategy:

- `current_state.json` is now Context Capsule v2, the compact source of task
  truth.
- The context capsule tracks objective, constraints, acceptance criteria,
  changed files, artifacts, verification state, and source pointers.
- Prompt assembly has deterministic section budgets and prompt manifests.
- Context Preview can show what will be sent to a provider.
- Checkpoints preserve fork history and make branch history more inspectable.
- Empty successful provider runs and missing artifact cases are handled more
  carefully than before.

These are strong foundations. The next work should not create a separate
mission-state system beside them. It should extend Context Capsule v2 and the
existing plan/runtime services so mission truth stays in one place.

## Current Gaps

ASTRA still has several gaps that prevent reliable long-running missions:

- Goal Mode plans have steps and `doneSignal`, but no first-class validation
  contract.
- Validation is task-level only: manual review, one test command, or AI
  self-check.
- Provider success can still become plan completion without assertion-level
  proof.
- Worker output is not yet captured as a structured handoff.
- Failed validation does not automatically become a narrow corrective work item.
- There is no mission-level control view that combines plan, evidence, blockers,
  budget, handoffs, and corrections.
- The queue still supports parallel writes by default through multiple workers.
- Planner, worker, verifier, and UI tester roles are not independently modeled.

## Full Scope at a Glance

| Area | What ASTRA has now | What this plan adds | Practical value |
| --- | --- | --- | --- |
| Planning | Steps, acceptance criteria, and done signals | A validation contract attached to the plan | "Done" becomes measurable before work starts |
| Validation | Manual review, one test command, or AI self-check | Assertion-level evidence and pass/fail records | ASTRA cannot finish important work on claims alone |
| Context | Context Capsule v2 and prompt manifests | Contract, handoff, correction, and verifier source pointers | Later runs can resume from compact, trustworthy state |
| Handoffs | Transcript summaries and current state | Structured worker handoff events | Long tasks become easier to resume and audit |
| Review | Worker can self-check | Independent verifier role | A second role can catch mistakes the worker missed |
| Failure handling | Failed or pending-review task state | Corrective steps or child tasks tied to failed assertions | Failures turn into specific next actions |
| Supervision | Usage dashboard and task/run views | Mission Control view | Users see status, evidence, blockers, and next action together |
| Concurrency | Multiple workers can run from the queue | Serial writes and parallel reads | Faster research without unsafe simultaneous edits |
| Model choice | Provider settings | Role-specific model profiles | Planner, worker, verifier, and tester can use the right model |
| Behavior checks | Mostly code/test validation | Browser and UI behavior evidence | ASTRA can prove visible results, not only file changes |

For a 17-year-old version: ASTRA should work less like a chat where someone
says "trust me, I finished" and more like a school project dashboard with the
rubric, submitted work, test results, teacher review, corrections, and final
grade all saved.

## Product Principle

Do not make ASTRA feel like "more chat."

Make ASTRA feel like an operational console where every important task has:

- a goal
- a plan
- a contract
- evidence
- verification
- handoffs
- checkpoints
- audit logs
- clear next action

## Design Principles

- Evidence over claims: provider output is a claim; validation artifacts are
  proof.
- Context Capsule v2 is canonical: contracts, verification summaries, and source
  pointers should flow through it.
- Tests are part of the feature: every new bug fix or new feature needs
  targeted regression coverage.
- Human control remains explicit: ASTRA can recommend corrective work, but the
  user should understand what is being resumed, retried, approved, or dismissed.
- Serial writes, parallel reads: research and review can run in parallel, but
  writes to the same resource should be coordinated.
- Logs must be audit-ready: later we should be able to reconstruct why ASTRA
  marked work complete, blocked, failed, or needing review.
- Provider-native memory is helpful but not authoritative. ASTRA state wins.

## Stage 0 - Baseline and Safety Invariants

### Goal

Lock down how the current system works before adding contract behavior.

### Work

- Document the current path:
  - Goal Mode prompt emits `ASTRA_PLAN`.
  - `TaskPlanService` parses and stores plan events.
  - Plan shelf edits step detail and `doneSignal`.
  - `AgentPromptBuilder` injects approved plan JSON.
  - `AgentEventRecorder` records `ASTRA_EVENT plan.step.*`.
  - `AgentRuntimeWorker` finalizes plan and task state.
  - `ValidationService` runs existing task-level validation.
  - `TaskContextStateManager` records Context Capsule v2 verification state.
- Add missing regression tests around current plan completion semantics.
- Confirm that Context Capsule v2 remains the canonical compact state.

### Value

This prevents accidental regressions while changing completion semantics.

### Verification

- A reviewer can trace current Goal Mode to plan completion using code
  references.
- Existing Goal Mode tests still pass.
- Existing Context Capsule v2 tests still pass.
- Regression tests cover current fallback completion behavior.

### Suggested Checks

```bash
swift test --filter TaskPlanServiceTests
swift test --filter TaskContextStateTests
swift test --filter AgentRuntimeWorkerTests
swift test --filter HeadlessChatScenarioTests
git diff --check
```

## Stage 1 - Validation Contract v1

### Goal

Turn a plan from "steps plus done signals" into "steps plus required proof."

### Work

- Add optional `validationContract` to `TaskPlanPayload`.
- Define validation assertions:
  - `id`
  - `scope`: plan or step
  - `description`
  - `method`: command, artifact, manual, text evidence
  - `required`
  - method-specific fields such as command, path, expected artifact type, or
    manual review label
- Keep decoding backward compatible for old plans.
- Update Goal Mode instructions to ask for validation assertions when useful.
- Show contract assertions in the Plan shelf near the existing Acceptance field.
- Include contract assertions in approved-plan prompts.
- Include contract status in Context Capsule v2.

### Value

ASTRA can say exactly what "done" means before the worker starts. This reduces
fake completion, vague review, and forgotten test expectations.

### Audit Events

Add durable task events:

- `validation.contract.created`
- `validation.contract.updated`
- `validation.assertion.defined`

Add audit log fields:

- task ID
- plan ID
- assertion ID
- assertion method
- required flag
- scope

### Verification

- Old plans without `validationContract` decode correctly.
- New plans with contract assertions parse and round-trip.
- Plan shelf displays assertions.
- Context Preview includes the contract in the assembled prompt.
- Context Capsule v2 summarizes contract status.

### Suggested Checks

```bash
swift test --filter TaskPlanServiceTests
swift test --filter TaskContextStateTests
swift test --filter PromptContextPreviewPresentationTests
swift test --filter ViewTests
git diff --check
```

## Stage 2 - Evidence-Gated Completion

### Goal

Stop marking plan execution complete until required validation assertions have
evidence.

### Work

- Add `ValidationService.runContract(...)`.
- Implement deterministic assertion methods first:
  - command exits 0
  - artifact exists
  - artifact is run-scoped and not stale
  - manual assertion is explicitly approved
  - text evidence exists in a structured event
- Record assertion results as task events.
- Block `plan.execution.completed` if required assertions fail or have not run.
- Keep non-required assertion failures visible without blocking completion.
- Update Context Capsule v2 verification state from contract evidence.

### Value

This is the main trust upgrade. Provider success becomes insufficient by
itself. Completion requires proof.

### Audit Events

Add durable task events:

- `validation.assertion.started`
- `validation.assertion.passed`
- `validation.assertion.failed`
- `validation.assertion.skipped`
- `validation.contract.passed`
- `validation.contract.failed`

Add audit log fields:

- task ID
- run ID
- plan ID
- assertion ID
- assertion method
- command
- exit code
- artifact path
- elapsed milliseconds
- failure reason
- required flag

### Verification

- A passing required command assertion allows completion.
- A failing required command assertion blocks completion.
- A missing required artifact blocks completion.
- A non-required failed assertion is shown but does not block completion.
- Context Capsule v2 records passed and failed evidence with source pointers.
- The task UI shows whether completion is verified.

### Suggested Checks

```bash
swift test --filter ValidationServiceTests
swift test --filter AgentRuntimeWorkerTests
swift test --filter TaskContextStateTests
swift test --filter TaskRunLifecycleServiceTests
swift test --filter ViewTests
git diff --check
```

## Stage 3 - Structured Worker Handoffs

### Goal

Make every worker run leave a structured summary that future runs and humans can
trust.

### Work

- Add a structured handoff event, for example `handoff.created`.
- Define handoff fields:
  - completed work
  - unfinished work
  - commands run
  - exit codes
  - files changed
  - artifacts created
  - validation evidence claimed
  - blockers
  - risks
  - suggested next action
- Ask workers to emit handoff information near the end of a run.
- Treat worker handoff as useful context, not proof.
- Store handoff source pointers in Context Capsule v2.
- Show latest handoff in run activity or task detail.

### Value

Long-running work becomes resumable. A later worker does not need to reread an
entire transcript to understand what happened.

### Audit Events

Add durable task events:

- `handoff.created`
- `handoff.updated`
- `handoff.missing`

Add audit log fields:

- task ID
- run ID
- provider
- handoff field counts
- changed file count
- command count
- blocker count

### Verification

- A run with a handoff stores a structured event.
- Context Capsule v2 references the latest handoff.
- Prompt assembly includes the handoff in follow-up context within budget.
- Missing handoff is visible but does not break normal execution.

### Suggested Checks

```bash
swift test --filter AgentRuntimeWorkerTests
swift test --filter AgentEventRecorderTests
swift test --filter TaskContextStateTests
swift test --filter PromptContextPreviewPresentationTests
git diff --check
```

## Stage 4 - Independent Verifier Role

### Goal

Separate builder and reviewer so ASTRA can detect defects the worker is biased
to miss.

### Work

- Add verifier role configuration:
  - verifier runtime
  - verifier model
  - verifier budget
  - verifier policy
- Create a verifier prompt that receives:
  - validation contract
  - worker handoff
  - file changes
  - artifacts
  - test output
  - relevant Context Capsule v2 state
- Require structured verifier output:
  - pass
  - fail
  - needs manual review
  - assertion result mapping
  - evidence pointers
- Start with verifier as optional or required per contract assertion.
- Keep deterministic checks authoritative when available.

### Value

The builder and verifier see the work differently. This reduces confirmation
bias and catches issues that a self-check may miss.

### Audit Events

Add durable task events:

- `verifier.started`
- `verifier.completed`
- `verifier.failed`
- `validation.assertion.reviewed`

Add audit log fields:

- task ID
- run ID
- plan ID
- worker runtime
- verifier runtime
- verifier model
- assertion IDs reviewed
- verifier result

### Verification

- Verifier can fail an assertion even when worker claimed success.
- Verifier pass can satisfy verifier-based assertions.
- Verifier output is tied to source pointers.
- Different provider/model configuration is persisted and shown.

### Suggested Checks

```bash
swift test --filter ValidationServiceTests
swift test --filter AgentUtilityRuntimeTests
swift test --filter RuntimeProviderSettingsStoreTests
swift test --filter TaskContextStateTests
git diff --check
```

## Stage 5 - Corrective Work Loop

### Goal

Turn failed validation into focused repair work instead of vague task failure.

### Work

- When a required assertion fails, create a corrective plan step or child task.
- Tie the correction to:
  - failed assertion ID
  - failure evidence
  - suggested repair scope
  - files/artifacts involved
- Keep the user in control:
  - user can approve correction
  - user can dismiss
  - user can edit the correction
- Record correction lifecycle in task events and Context Capsule v2.

### Value

Failures become actionable. The user does not need to translate logs into the
next instruction.

### Audit Events

Add durable task events:

- `corrective.step.created`
- `corrective.step.approved`
- `corrective.step.dismissed`
- `corrective.task.created`

Add audit log fields:

- task ID
- source run ID
- failed assertion ID
- corrective step ID
- corrective task ID
- approval state

### Verification

- Failed assertion creates exactly one proposed corrective item.
- Re-running the correction updates the same assertion status.
- Dismissing a correction is auditable.
- Corrective items survive app restart and workspace export/import.

### Suggested Checks

```bash
swift test --filter TaskPlanServiceTests
swift test --filter AgentRuntimeWorkerTests
swift test --filter WorkspacePersistenceTests
swift test --filter TaskContextStateTests
git diff --check
```

## Stage 6 - Mission Control View

### Goal

Create a mission-level view that lets the user supervise outcomes instead of
reading raw transcripts.

### Work

- Add a Mission Control surface for the selected task or workspace.
- Show:
  - mission objective
  - current plan
  - active step
  - validation contract status
  - assertion pass/fail table
  - artifacts
  - latest handoff
  - blockers
  - checkpoints
  - budget and cost
  - next recommended action
- Keep it operational and dense, following ASTRA's lean UI system.

### Value

This is where the product becomes visibly more powerful. The user can manage
longer work without scanning every model response.

### Audit Events

Mission Control mostly reads existing events, but user actions from this view
should log:

- `mission.action.approved`
- `mission.action.dismissed`
- `mission.action.retry_requested`
- `mission.action.correction_created`

### Verification

- Mission Control accurately reflects task events and Context Capsule v2.
- It does not invent state that is not backed by source pointers.
- It handles no-contract, partial-contract, passing, failing, and blocked
  states.
- It remains usable on narrow and wide windows.

### Suggested Checks

```bash
swift test --filter ViewTests
swift test --filter TaskContextStateTests
swift test --filter PromptContextPreviewPresentationTests
./script/build_and_run.sh --verify
git diff --check
```

## Stage 7 - Serial Writes and Parallel Reads

### Goal

Allow parallel research and review while preventing multiple workers from
writing to the same repo or resource at the same time.

### Work

- Add resource/write classification for tasks and plan steps.
- Add workspace or execution-root locks for write-capable work.
- Let read-only research, verifier review, and context inspection run in
  parallel.
- Block or queue write-capable work when another write is active for the same
  resource.
- Show the lock reason in the queue UI and logs.

### Value

This protects codebases from merge conflicts, duplicate edits, and architecture
drift while still allowing useful parallelism.

### Audit Events

Add durable task events:

- `resource.lock.requested`
- `resource.lock.acquired`
- `resource.lock.waiting`
- `resource.lock.released`

Add audit log fields:

- task ID
- workspace ID
- execution root
- lock key
- lock mode
- wait time
- holder task ID

### Verification

- Two write tasks for the same execution root do not run concurrently.
- Read-only tasks can run while a write task is active.
- Verifier tasks can run in read-only mode.
- Lock release happens on completion, failure, cancellation, and app restart
  recovery.

### Suggested Checks

```bash
swift test --filter TaskQueueTests
swift test --filter AgentRuntimeWorkerTests
swift test --filter TaskRunLifecycleServiceTests
git diff --check
```

## Stage 8 - Role-Specific Model Profiles

### Goal

Let ASTRA choose the right provider/model for each mission role.

### Work

- Add role profiles:
  - planner
  - worker
  - verifier
  - browser or UI tester
  - summarizer or handoff writer
- Store runtime, model, budget, and policy per role.
- Surface role choices in settings and task creation only where helpful.
- Keep sensible defaults so normal users do not need to configure everything.
- Prefer different verifier provider/model when available to reduce shared bias.

### Value

Different tasks need different strengths. Planning, coding, verifying, and
summarizing are not the same job.

### Audit Events

Add durable task events:

- `role.profile.selected`
- `role.profile.changed`

Add audit log fields:

- task ID
- role
- runtime
- model
- budget
- policy level
- source of selection: default, workspace, task override

### Verification

- Role defaults load correctly.
- Task overrides do not corrupt global settings.
- Verifier can use a different runtime/model than worker.
- Prompt and validation logs show which role made each decision.

### Suggested Checks

```bash
swift test --filter RuntimeProviderSettingsStoreTests
swift test --filter AgentRuntimeAdapterTests
swift test --filter AgentRuntimeWorkerTests
swift test --filter ViewTests
git diff --check
```

## Stage 9 - Behavioral and Browser Validation

### Goal

Validate real user-facing behavior, not just code and files.

### Work

- Add behavioral assertion methods:
  - open generated HTML and inspect rendered page
  - run browser bridge action
  - verify Google Docs safe edit result
  - inspect app UI state where supported
- Store screenshots, DOM summaries, or browser action outputs as evidence.
- Keep browser validation scoped and permission-aware.
- Never use unsafe external UI automation as a fallback when ASTRA has a safer
  bridge-specific path.

### Value

Some work only matters if it actually behaves correctly in the app or browser.
This catches failures that unit tests miss.

### Audit Events

Add durable task events:

- `validation.behavior.started`
- `validation.behavior.passed`
- `validation.behavior.failed`
- `validation.behavior.evidence.attached`

Add audit log fields:

- task ID
- assertion ID
- browser/session ID
- URL or artifact path
- action count
- screenshot path
- failure reason

### Verification

- Browser assertion can pass with deterministic evidence.
- Browser assertion failure blocks required contract completion.
- Evidence artifacts are visible in Context Capsule v2.
- Browser action budget and safety guardrails still apply.

### Suggested Checks

```bash
swift test --filter BrowserControlSafetyTests
swift test --filter BrowserFailureDebugCaptureTests
swift test --filter ValidationServiceTests
./script/build_and_run.sh --verify
git diff --check
```

## Stage 10 - Long-Running Mission Hardening

### Goal

Make multi-hour or multi-day work durable and auditable.

### Work

- Add mission milestones above plan steps.
- Add mission summary rollups from events, handoffs, and validation evidence.
- Add automatic periodic checkpoint creation for long runs.
- Add budget and elapsed-time reporting per mission.
- Add recovery behavior for interrupted app sessions.
- Add exportable mission audit bundles.

### Value

This is the long-term payoff: ASTRA can supervise serious work over time, not
just one-off tasks.

### Audit Events

Add durable task events:

- `mission.milestone.created`
- `mission.milestone.completed`
- `mission.checkpoint.created`
- `mission.audit_bundle.created`

Add audit log fields:

- mission ID or task ID
- milestone ID
- checkpoint ID
- elapsed time
- token/cost usage
- contract status
- open blockers

### Verification

- A mission can be stopped and resumed without losing contract state.
- Exported audit bundle contains plan, contract, evidence, handoffs, logs, and
  source pointers.
- Checkpoints map to actual runs and copied events.
- Context Capsule v2 remains the authoritative compact state.

### Suggested Checks

```bash
swift test
./script/build_and_run.sh --verify
git diff --check
```

## Cross-Cutting Logging and Audit Requirements

Every stage must add enough evidence to answer these questions later:

- What was ASTRA trying to accomplish?
- What plan was approved?
- What contract did ASTRA require?
- Which provider/model did the work?
- Which files changed?
- Which artifacts were created?
- Which checks ran?
- What passed?
- What failed?
- Who or what approved completion?
- Why did ASTRA mark the task complete, blocked, failed, or needing review?

Use three layers:

1. Task events for durable task history.
2. Context Capsule v2 for compact current truth and source pointers.
3. `AppLogger.audit(...)` for operational debugging and release validation.

## Suggested Event Naming

Use predictable event names so compaction, UI, diagnostics, and exports can
reason about them:

- `validation.contract.created`
- `validation.contract.updated`
- `validation.assertion.defined`
- `validation.assertion.started`
- `validation.assertion.passed`
- `validation.assertion.failed`
- `validation.assertion.skipped`
- `validation.contract.passed`
- `validation.contract.failed`
- `handoff.created`
- `handoff.updated`
- `handoff.missing`
- `verifier.started`
- `verifier.completed`
- `verifier.failed`
- `corrective.step.created`
- `corrective.task.created`
- `resource.lock.acquired`
- `resource.lock.released`
- `mission.checkpoint.created`

## Definition of Done for Each Stage

A stage is not complete until all of these are true:

- The user-visible behavior exists in ASTRA Dev.
- The behavior is backed by structured task events.
- Context Capsule v2 reflects the new state.
- Operational logs include enough audit fields.
- Prompt Context Preview shows the relevant prompt/context changes.
- Focused regression tests cover the new behavior.
- `git diff --check` passes.
- For UI or workflow changes, `./script/build_and_run.sh --verify` passes.

## Recommended Implementation Order

Start here:

1. Stage 0: baseline and tests.
2. Stage 1: Validation Contract v1.
3. Stage 2: evidence-gated completion.

Then add:

4. Stage 3: structured handoffs.
5. Stage 5: corrective work loop.
6. Stage 6: Mission Control view.

Then harden scale:

7. Stage 4: independent verifier.
8. Stage 7: serial writes and parallel reads.
9. Stage 8: role-specific model profiles.
10. Stage 9: behavioral/browser validation.
11. Stage 10: long-running mission hardening.

This order makes the first visible impact early: ASTRA stops trusting "done" and
starts requiring proof. The later stages make that proof loop easier to operate
for longer, more complex work.
