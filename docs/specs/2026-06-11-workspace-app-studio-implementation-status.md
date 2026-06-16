# Workspace App Studio Implementation Status

**Date:** 2026-06-11
**Branch:** `alvaro/workspace-app-studio-spec`
**Parent spec:** `docs/specs/2026-06-05-workspace-app-studio-spec.md`
**PR:** https://github.com/susom/astra/pull/122

This document tracks implementation status against the Workspace App Studio
product and architecture spec. The spec remains the source of truth for the
target product. This document is the execution tracker: what exists now, what
is partially implemented, and what still needs to be built before the final
product direction is true.

## Current State Summary

The branch has moved beyond a documentation-only PR. It now contains a working
Workspace App foundation:

- Durable `WorkspaceApp` domain state and SwiftData indexes.
- File-backed app manifests under the workspace app folder.
- App-owned SQLite storage.
- Manifest validation.
- Workspace App detail, Studio, import review, and presentation surfaces.
- Contract registry and dependency binding primitives.
- Native source resolution for app storage, mocked capability sources, BigQuery
  reads, and REDCap reads/form schema/write validation paths.
- Action execution for app storage, task launch, capability read/write,
  artifact export, utility actions, gates, pipelines, and bounded loops.
- Automation scheduling and due automation execution.
- `.astra-app` style package export/import, portable data export, package
  validation, dependency mapping, digest, provenance, trust metadata, library
  discovery, and update checks.
- Regression coverage under `Tests/WorkspaceApp*`.

The largest remaining gap is not the low-level app model. The largest gap is
turning those primitives into the final user-facing product: a chat-built App
Studio that can inspect workspace context and capabilities, generate a useful
app, iterate through validation feedback, preview the app, publish it, and make
the resulting app feel complete for local database, connector-backed, REDCap,
and pipeline workflows.

## Evidence Files

Core implementation files:

- `Astra/Models/WorkspaceApp.swift`
- `Astra/Models/WorkspaceAppDependencyBinding.swift`
- `Astra/Models/WorkspaceAppAutomationState.swift`
- `Astra/Models/WorkspaceAppRun.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppManifest.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppManifestValidator.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppStorageService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppContractRegistry.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppSourceResolver.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppAutomationScheduler.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppAutomationExecutionService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppStudio.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppStudioIdeation.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageExporter.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageImportReview.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageLibraryService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppWebViewBridge.swift`
- `Astra/Views/WorkspaceAppDetailView.swift`
- `Astra/Views/WorkspaceAppStudioView.swift`
- `Astra/Views/WorkspaceAppPackageImportReviewView.swift`
- `Astra/Views/WorkspaceAppPresentation.swift`

Regression coverage:

- `Tests/WorkspaceAppManifestTests.swift`
- `Tests/WorkspaceAppStorageTests.swift`
- `Tests/WorkspaceAppContractRegistryTests.swift`
- `Tests/WorkspaceAppSourceResolverTests.swift`
- `Tests/WorkspaceAppActionExecutorTests.swift`
- `Tests/WorkspaceAppAutomationSchedulerTests.swift`
- `Tests/WorkspaceAppAutomationExecutionServiceTests.swift`
- `Tests/WorkspaceAppDetailDataLoaderTests.swift`
- `Tests/WorkspaceAppPackageTests.swift`

## Status By Roadmap Area

### 24.1 Foundation

Status: mostly implemented.

Implemented:

- Workspace App domain model.
- Manifest Codable types.
- Manifest validator.
- App detail/studio/import review presentation surfaces.
- SwiftData indexing of app metadata and app run state.
- Service-owned manifest writes and digest refresh.

Pending:

- URL route and App Intent coverage for opening apps, if not already wired in
  the broader app shell.
- More UI routing tests for opening Workspace Apps from every intended entry
  point: workspace home, sidebar, URL route, and App Intent.

### 24.2 App-Owned Storage

Status: mostly implemented.

Implemented:

- Per-app SQLite database location under the workspace app folder.
- Storage schema manifest.
- CRUD service.
- Migration planner.
- Portable typed record export/import through package flows.

Pending:

- End-to-end local database app polish. The current system can create and
  execute storage-backed manifests, but the user-facing grocery/database app
  should be a complete reference workflow with table/form editing, metrics,
  charts, and export controls.
- More renderer support for form-style data entry and inline editing.

### 24.3 Native Renderer

Status: partially implemented.

Implemented:

- Detail loader and presentation models.
- App detail shell.
- Storage/table-backed presentation basics.
- Run history and action entry points at the service level.

Pending:

- Production-grade native widgets for:
  - metrics
  - charts
  - diagrams
  - tables with sorting/filtering/selection
  - forms with validation state
  - markdown sections
  - approval controls
  - run history drill-in
- Layout collapse behavior for dense operational apps.
- View tests for the final lean presentation rules.

### 24.4 Capability Contracts

Status: partially implemented.

Implemented:

- Contract family and operation types.
- Built-in contract registry.
- Requirement resolution and provider hint ordering.
- Workspace dependency binding model.
- Package-declared implementation descriptors.
- Native app storage contract path.
- Native BigQuery read client path for `tabularQuery.read`.
- Native REDCap record/form/write validation paths.
- Source resolver and action executor.

Pending:

- Full App Studio use of the registry during generation. The builder should
  inspect available workspace capabilities, propose compatible app designs,
  and create dependency requirements without hardcoding provider-specific
  flows.
- More complete provider profile handling for REDCap projects, BigQuery
  datasets/tables, and future connectors.
- Task-backed fallback operations for capabilities that do not yet have native
  deterministic app operations.
- Later only: general package-declared HTTP, CLI, and MCP execution. The parent
  spec explicitly says not to ship those in the first milestone.

### 24.5 App Studio

Status: scaffolded, but this is the biggest remaining product gap.

Implemented:

- App Studio draft object.
- Deterministic builder for several known intent families.
- Structured manifest output validation.
- Manifest patch operation validation.
- Basic ideation from request/conversation-like excerpts.
- Studio view with intent, ideas, proposal, validation, and manifest inspector.

Pending:

- Model-backed app generation from real workspace context.
- Builder input assembly:
  - user prompt
  - relevant conversation excerpts
  - workspace files/artifacts
  - available capability contracts
  - existing app manifest when editing
  - policy constraints
- Validation feedback loop that returns structured errors to the builder and
  retries safely.
- Live preview of the app while editing.
- Publish workflow with version tracking.
- Undo/revert:
  - draft version
  - published version
  - last known good version
  - revert to previous published version
- Editing an existing app through App Studio.
- More complete ideation from actual conversation/task context, not just
  keyword-based deterministic suggestions.

### 24.6 Automation And Pipelines

Status: mostly implemented at the runtime primitive level; partial at product
level.

Implemented:

- `AppRun` models and event recording.
- Automation scheduler.
- Due automation execution service.
- Pipeline action type.
- Human approval gates.
- Expression gates.
- Agent recommendation gates with budget and approval policy.
- Bounded loop action type with max iterations, timeout, stop condition, and
  per-iteration audit events.

Pending:

- Task-backed agent steps that launch/continue ASTRA tasks and bind outputs
  back into app state.
- User-facing pipeline builder controls in App Studio.
- Pipeline run visualization in app detail.
- Approval queue UI for blocked runs.
- Schedule enable/disable review UI with clear governance.

### 24.7 Sharing

Status: substantially implemented.

Implemented:

- Package export/import service.
- Package shape and checksums.
- Dependency mapping.
- Logical dependency IDs and portable requirements.
- Export modes for template/sample/seed/full style data.
- Typed portable app-owned data export/import.
- Package install states and validation blockers.
- Package digest and provenance.
- Full export sensitive data warning.
- Package library discovery and update checks.
- Trust metadata validation.

Pending:

- End-to-end UI polish for export, import, mapping, approval, install state,
  and update flows.
- More manual validation of ASTRA-to-ASTRA sharing between separate workspaces.
- Stronger signed package support only if team/remote distribution is required.

### 24.8 Advanced Rendering

Status: early/guarded.

Implemented:

- WebView bridge request validation for declared widget actions.
- Manifest validation limits WebView widgets to ASTRA-known renderers.
- Package validation blocks unsafe arbitrary portable content.

Pending:

- Sandboxed WKWebView widgets for advanced diagrams/reports.
- Chart and diagram rendering improvements.
- Custom visual widgets through a narrow message bridge.
- CSP/network/filesystem restrictions before any imported custom WebView code.

### 24.9 Team Library

Status: partial.

Implemented:

- Package library discovery, including shared-folder style package discovery.
- Package update checks.
- Trust metadata model.

Pending:

- Complete local team library workflow.
- Clear UI for shared folder import paths.
- Team trust/source metadata policy.
- Package signing if remote/team distribution becomes part of the milestone.

## Status By Success Criteria

1. User can build a useful local database app from a natural-language prompt.
   - Status: partial.
   - Reason: deterministic builder can generate local database-style manifests,
     and storage/action primitives exist. The app is not yet a polished
     natural-language, preview-and-edit experience.

2. User can build a connector-backed app from workspace capabilities without
   separate setup.
   - Status: partial.
   - Reason: contract registry, dependency bindings, and native BigQuery/REDCap
     paths exist. App Studio still needs full capability-aware generation and
     dependency mapping during build.

3. User can build a REDCap data-entry or reconciliation app with visible
   governance.
   - Status: partial.
   - Reason: REDCap read/form/write validation primitives exist. Full form
     rendering, branching logic, data-entry replacement workflow, and visible
     governance UI remain.

4. User can turn a repeated conversation/task process into a reusable app.
   - Status: partial.
   - Reason: ideation scaffolding exists, but it does not yet consume real
     task/conversation context deeply enough or generate robust task-backed
     reusable apps.

5. Apps can display metrics, charts, diagrams, tables, forms, and actionable
   controls.
   - Status: partial.
   - Reason: tables/actions/presentation basics exist. Rich metrics, charts,
     diagrams, and forms need more renderer work.

6. Apps can create and run normal ASTRA tasks when agent work is needed.
   - Status: partial to mostly implemented.
   - Reason: task create draft and create-and-run actions exist. Task-backed
     pipeline steps and output binding remain.

7. Apps can be shared to another ASTRA workspace without sharing credentials.
   - Status: mostly implemented.
   - Reason: package export/import, dependency mapping, redaction, and portable
     data flows exist. Needs UI polish and cross-workspace manual validation.

8. Imported apps clearly declare dependencies and permissions before use.
   - Status: mostly implemented.
   - Reason: package import review and validation exist. Needs final UX polish.

9. New capability packages can make themselves app-usable by declaring
   compatible contract operations.
   - Status: partial.
   - Reason: package-declared implementation descriptors can extend the
     registry. General execution of package-declared HTTP/CLI/MCP operations is
     intentionally later.

10. Swift remains the trusted runtime for state, actions, credentials, and
    audit.
    - Status: implemented as an architectural invariant so far.
    - Reason: current state/actions/audit are Swift-owned; WebView is not a
      privileged runtime.

11. WebView or JavaScript, if used, remains sandboxed presentation rather than
    privileged runtime.
    - Status: partially implemented.
    - Reason: bridge validation and renderer restrictions exist. Full sandbox
      policy for richer custom visuals remains future work.

## Main-line Re-land Sequence (current fork)

This status doc and the slice list below were written against the
`alvaro/workspace-app-studio-spec` branch, where the full Workspace App runtime
already exists. The active line of development (`aandresalvarez/astra` `main`)
does **not** contain that runtime: there are zero `WorkspaceApp` model, view, or
service files on `main`. PR #58 (Slice 1, context builder) is the first
re-land, and it intentionally brought only the context builder.

Therefore the runtime must be re-landed onto `main` as review-sized slices
before any slice that depends on it (Slice 2+ and Slice 9 all do). Re-land
order, smallest dependency first:

- **F1 — Domain + manifest + validator.** `WorkspaceApp`, `WorkspaceAppRun`,
  `WorkspaceAppDependencyBinding`, `WorkspaceAppAutomationState` models;
  `WorkspaceAppManifest` Codable types; `WorkspaceAppManifestValidator`;
  `SchemaVersions` registration. Tests: `WorkspaceAppManifestTests`,
  `SchemaVersionTests`. No executor, no UI. Pure-data foundation.
- **F2 — App-owned storage.** `WorkspaceAppStorageService` (SQLite CRUD +
  migration planner) and the additive `WorkspaceFileLayout` app-path methods.
  Tests: `WorkspaceAppStorageTests`. NOTE: `WorkspaceAppService` was originally
  grouped here but depends on `WorkspaceAppContractRegistry` (F3) and the
  automation scheduler, so it re-lands in F3.5 (below), not F2.
- **F3 — Contract registry.** `WorkspaceAppContractRegistry` only (built-in
  contract families + requirement resolution). Self-contained on F1. Tests:
  `WorkspaceAppContractRegistryTests`. NOTE: `WorkspaceAppSourceResolver` and
  `WorkspaceAppNativeCapabilitySourceClient` were originally grouped here but
  share types (`WorkspaceAppActionInput`, `WorkspaceAppCapabilityWriteResult`,
  `WorkspaceAppActionExecutionError`) with the executor, so they move into the
  F4 action-runtime cluster.
- **F3.5 — App lifecycle service.** `WorkspaceAppService` (app create/duplicate/
  delete, manifest writes + digest, dependency-binding resolution via the
  contract registry, automation-state enable). Depends on F1+F2+F3. Tests: the
  service half of the susom `WorkspaceAppManifestTests` (createApp / remap /
  automation / lifecycle / duplicate / delete).
- **F4 — Action runtime.** `WorkspaceAppSourceResolver` +
  `WorkspaceAppNativeCapabilitySourceClient` + `WorkspaceAppActionExecutor`
  (the `task.createAndRun`, `gate.agentRecommendation`, `gate.humanApproval`,
  `loop.run`, `pipeline.run` dispatch). These land together because they share
  the action-input/result/error and capability-client types. Tests:
  `WorkspaceAppSourceResolverTests`, `WorkspaceAppActionExecutorTests`. Watch
  per-file line budgets (executor is ~1400 lines); split if needed.
- **F5a — App-detail data + presentation (DONE).** `WorkspaceAppDetailDataLoader`
  + `WorkspaceAppPresentation` (cards, inspector rows, run-history, storage form/
  draft builders). Tests: `WorkspaceAppDetailDataLoaderTests`.
- **F5b — App-detail view (DONE).** `WorkspaceAppDetailView` + extracted
  `WorkspaceAppStatusPill`. Compiles; not yet reachable from the UI.
- **F6 — Studio builder + automation + packaging + webview (DONE).**
  `WorkspaceAppStudio`(+`Ideation`), `WorkspaceAppAutomationExecutionService`,
  `WorkspaceAppPackage*`, `WorkspaceAppWebViewBridge`, `WorkspaceAppStudioView`,
  `WorkspaceAppPackageImportReviewView`. Tests: package + automation suites.

### F7 — UI entry-point wiring (CORE LANDED; visible list + live verify residual)

Core wiring landed (`ContentView` + `ContentSceneState`), compiling, with routing
logic unit-tested (`WorkspaceAppDetailPresentationTests`, 4) and no regressions
(ViewTests 44, ArchitectureFitnessTests 40):

- `ContentDetailPresentation` gains `.workspaceApp` / `.workspaceAppStudio` +
  `resolve(selectedWorkspaceApp:, isComposingWorkspaceApp:)` (defaulted) +
  `WorkspaceAppStudioEntryPresentation.shouldShowNewAppEntry`.
- `ContentView` renders `WorkspaceAppDetailView` / `WorkspaceAppStudioView` at the
  `detailArea` level (gated on `selectedWorkspaceApp` / `isComposingWorkspaceApp`),
  mutually exclusive with task selection. `onRunAction` wires
  `WorkspaceAppActionExecutor` (+ `ModelContext` + per-app bindings); publish wires
  `WorkspaceAppService.createApp` and auto-opens the new app. New App opens via a
  hidden ⌘⇧A hotkey (mirrors `searchHotkey`).

This gives a complete functional loop for Slice 9: ⌘⇧A -> App Studio -> publish ->
detail -> run governed agentic-workflow actions.

Visible re-open list — DONE (F7b): `onOpenWorkspaceApp` is threaded from
`ContentView` through `ContentDetailAreaView` / `ContentDetailContentView` into
`WorkspaceHomeContainerView`, which `@Query`s the workspace's `WorkspaceApp`s and
renders an Apps section in the home context card (tap to open). Re-open loop is
closed.

Residual (only live verification now — `/run` / `/verify`):
- Live verification of navigation/rendering/run behavior on the running app (unit
  tests can't cover SwiftUI runtime); confirm the Apps-section layout reads well.
- Optional: a `TaskSidebarView` app-rows surface (the home Apps list already
  re-opens apps), and porting the app-specific cases from susom `ViewTests` /
  `WorkspaceHomePresentationTests` / `TaskEventTimelineSidebarTests` under
  non-colliding names.

Original full checklist (for reference):

- `ContentSceneState`: add `.workspaceApp` / `.workspaceAppStudio` cases to
  `ContentDetailPresentation`, thread `selectedWorkspaceApp` through
  `resolve(...)` + `ContentWorkspaceSelectionCoordinator`/`...Update`, and add
  `WorkspaceAppStudioEntryPresentation.shouldShowNewAppEntry(for:)`.
- `ContentView`: add `@State selectedWorkspaceApp`, thread it into
  `ContentDetailAreaView`, and handle the two new cases in the detail switch
  (~line 3190) — render `WorkspaceAppDetailView` (wire `onRunAction` to
  `WorkspaceAppActionExecutor` + `ModelContext`, `onRefresh`, `onExportPackage`,
  `onOpenStudio`) and `WorkspaceAppStudioView`. Add a `startWorkspaceApp` create
  path (`WorkspaceAppStudioBuilder` -> `WorkspaceAppService.createApp`).
- `WorkspaceHomeView`: add an Apps section + `New App` action + the app-card
  presentation flags the susom `WorkspaceHomePresentationTests` assert.
- `TaskSidebarView`: app rows as workspace children (open / studio / duplicate /
  export / delete) + the `WorkspaceAppList` activity-sort presentation that
  `TaskEventTimelineSidebarTests` covers.
- Coupled tests to add (without clobbering existing same-named files): the
  app-specific cases from susom `ViewTests` / `WorkspaceHomePresentationTests` /
  `TaskEventTimelineSidebarTests` (`WorkspaceAppStudioEntryPresentation`,
  `ContentDetailPresentation.resolve` with apps, `WorkspaceAppsPresentation`).

Automation scheduler and packaging/sharing already re-landed in F6.

Each F-slice ports the corresponding susom-branch files onto current `main`,
fixes API drift (~355 commits of divergence), and lands with its tests green.
F1–F6 + Slice 9 Phase A are committed on `claude/loving-rhodes-87e735`.

## Recommended Next PR Slices

Keep the work reviewable. Each slice should include focused regression tests.

### Slice 1: App Studio Context Assembly And Builder Contract

Goal:

Make App Studio gather the real context it needs before generation.

Deliverables:

- `WorkspaceAppStudioContextBuilder` service.
- Inputs for prompt, selected workspace, existing app, available contracts,
  dependency bindings, recent task/conversation excerpts, and relevant
  artifacts.
- A compact builder prompt/contract object that can be tested deterministically.
- Tests proving context redaction, capability inclusion, and stable ordering.

### Slice 2: Model-backed Structured Generation Loop

Goal:

Replace deterministic-only generation with a structured manifest generation
loop that still keeps Swift validation authoritative.

Deliverables:

- Model output parser for manifest and patch responses.
- Validation feedback loop that rejects invalid manifests and preserves the
  last valid version.
- Builder result states: generated, rejected, needs user decision, publishable.
- Tests for invalid structured output, validation retry, and last-valid
  preservation.

### Slice 3: App Studio Preview And Versioning

Goal:

Make the Studio feel like a builder, not just a manifest inspector.

Deliverables:

- Preview panel using the same presentation models as published apps.
- Draft/published/last-known-good version model.
- Revert to previous published version.
- Tests for publish, edit, failed edit, and revert.

### Slice 4: Local Database Reference App

Goal:

Make the grocery/local database use case complete enough to judge the product.

Deliverables:

- Natural-language prompt to app manifest flow.
- Table and form views.
- Add/edit/delete records.
- Metrics/chart widgets for app-owned data.
- Export action.
- View and action tests.

### Slice 5: REDCap Form And Reconciliation Reference App

Goal:

Prove the regulated connector-backed workflow.

Deliverables:

- REDCap metadata-backed form manifest generation.
- Field type, required field, choice list, and validation handling.
- Safe branching logic subset.
- Unsupported branching warnings and submit blocking/review behavior.
- Reconciliation dashboard with BigQuery/REDCap mocked sources.
- Tests for safe and unsupported REDCap metadata.

### Slice 6: Pipeline App Builder And Run Visualization

Goal:

Turn repeated task/conversation processes into reusable app workflows.

Deliverables:

- App Studio pipeline recipe selection.
- Pipeline/loop/gate visual preview.
- Task-backed step support.
- Run history drill-in and approval queue UI.
- Tests for blocked, approved, completed, and failed pipeline runs.

### Slice 7: Sharing UX Hardening

Goal:

Make ASTRA-to-ASTRA sharing usable by non-developers.

Deliverables:

- Export UI.
- Import review UI polish.
- Dependency mapping UI polish.
- Install state surfacing.
- Update flow UI.
- Manual cross-workspace package round trip.

### Slice 8: Advanced Rendering Guardrails

Goal:

Add richer visuals without weakening the trusted runtime model.

Deliverables:

- ASTRA-known diagram/chart WebView renderers.
- CSP and bridge policy tests.
- No arbitrary imported custom JavaScript widgets in the first milestone.

### Slice 9: Agentic Workflow Apps

Goal:

Let a user describe a problem and get a reusable app that orchestrates a
workflow of governed ASTRA agents to solve it. This is a new archetype recipe,
not a new runtime: it composes existing task, agent team, gate, loop, run, and
audit primitives. The execution rule in spec 16.5 is binding (see also spec
24.10). Most of Phase A is expressible on primitives that already ship today;
the product gap is await/binding/visualization, not the agent engine.

Phase A (buildable on current primitives):

- Add the Agentic Workflow archetype to App Studio: recipe plus builder hint.
- Generate manifests that chain `task.createDraft` / `task.createAndRun` steps
  with `gate.agentRecommendation`, `gate.humanApproval`, and bounded `loop.run`.
- Surface per-step status, linked task IDs, and run history in app detail.
- Tests for manifest validation, gate blocking/approval, and bounded-loop exit.

Phase B (new plumbing):

- [DONE — B1] Bind a step's structured output into later step inputs and app
  storage. `WorkspaceAppActionInput.boundRows`/`effectiveRecord`/`bindingForward`;
  executePipeline/executeLoop thread prior-step rows; appStorage.insert/update
  consume the bound row. Unit-tested (WorkspaceAppActionExecutorTests 21/21).
- [DONE — B2 core+service] Await long-running agent steps and resume the workflow.
  - `WorkspaceAppRun` gained `.waiting` + `pendingActionID` + `pendingStepIndex`
    (absorbed into schema V7's fresh tables — no new version).
  - `executePipeline` is resumable (startIndex/initialBoundRows) and SUSPENDS on a
    `task.createAndRun` step: launches the queued task, persists the resume point,
    throws a suspension the top-level `execute()` catches -> run `.waiting`.
  - `WorkspaceAppActionExecutor.resume(run:taskOutputRows:)` continues from the
    saved step, binding the task output forward (reuses B1).
  - `WorkspaceAppRunResumptionService.resumeRuns(awaitingTaskID:)` finds the waiting
    runs for a completed task, loads each manifest, and resumes them.
  - Unit-tested (WorkspaceAppActionExecutorTests 23/23): suspend->resume->complete +
    the resumption service.
- [DONE — B2 live] `WorkspaceAppRunResumptionService.resumeCompletedRuns(modelContext:)`
  sweeps waiting runs whose linked task is `.completed`, resolves workspace + manifest,
  binds a task-output row, and resumes — wired into `TaskLifecycleCoordinator` after
  `processQueue` + `executeTask` (in-session + on-open cross-session). Also fixed: a
  pipeline step's permission is enforced BEFORE launching the agent task. Unit-tested.
- [DONE — B3] `WorkspaceAppWorkflowBudget` (declared budget = sum of agent-gate token
  budgets); `WorkspaceAppRun.consumedTokens` accumulates awaited-task usage; `resume()`
  blocks (`.blocked`, not failed) the run on overrun. Unit-tested.
- [DONE — B4] Run history exposes `attentionRows` (`.waiting`/`.blocked`); the detail
  view renders a "Needs attention" approval/attention queue. Partition unit-tested;
  the live visual is verifiable in the app.

Phase B is complete (B1–B4 + B2-live), all unit-tested. Slice 9 Phase C (parallel
fan-out / branching / aggregation) remains as the explicit "later" tier.
- Tests for output binding (done), resume-after-await, and run-level budget.

Phase C (DONE — designed via a judge-panel workflow, adversarially reviewed):

- [C1] `task.fanOut`: launches one queued agent task per upstream bound row and
  suspends the run on a BARRIER over the SET of task ids (`WorkspaceAppPipelineSuspension`
  grew `taskID` -> `taskIDs`; B2 single-task is the one-element barrier;
  `WorkspaceAppRun.awaitedTaskIDsJSON` absorbed into V7). The run resumes only when
  EVERY awaited task completes, the N task rows bound forward (the fan-in into reduce).
- [C2] `gate.branch`: synchronous predicate over upstream output -> runs thenStep/elseStep
  inline (validator blocks targets that can transitively reach an async task).
- [C3] `rows.reduce`: folds the prior step's bound rows into one row (count/sum/concat/
  first/last).
- Hardening from the adversarial review: a failed/cancelled/deleted fan-out task FAILS the
  run (no infinite `.waiting`); task.fanOut rejected as a loop step / automation action.
- Tests: fan-out suspend/all-complete-resume + partial-failure, branch then/else +
  transitive-async rejection, reduce fold + validation. WorkspaceApp suite 124 green.

The full Workspace App Studio is now landed: runtime (F1-F6) + agentic workflows
(Slice 9 Phase A linear, Phase B async orchestration, Phase C parallel/branching/reduce),
all unit-tested; F7 UI wiring live-verified.

Out of scope for the first milestone:

- General package-declared HTTP/CLI/MCP execution inside workflow steps.
- Any agent runtime outside `TaskLifecycleCoordinator`.

## Verification Policy

For each implementation slice:

- Add or update regression tests for every new feature and every bug fix.
- Run the narrowest relevant test first.
- Run `swift test --filter WorkspaceApp` before pushing Workspace App changes.
- Run `git diff --check`.
- Run `./script/build_and_run.sh --verify` for user-visible changes.
- Broaden to full `swift test` when changing schema, persistence, package,
  runtime, capability, or scheduling behavior.

Current useful commands:

```bash
swift test --filter WorkspaceApp
swift test --filter WorkspaceAppManifestTests
swift test --filter WorkspaceAppActionExecutorTests
swift test --filter WorkspaceAppPackageTests
git diff --check
./script/build_and_run.sh --verify
```

## Working Definition Of Done

The Workspace App Studio implementation should not be considered complete until
all of the following are true:

- A local database app can be built, previewed, published, used, edited, and
  exported from a natural-language prompt.
- A connector-backed app can be built from available workspace capabilities,
  with dependency mapping and no credential leakage.
- A REDCap data-entry or reconciliation app can be generated and used with
  visible governance and safe unsupported-rule handling.
- A repeated task/conversation workflow can be turned into a pipeline app with
  gates, task-backed steps, run history, and approvals.
- Apps render operationally useful metrics, charts, diagrams, tables, forms,
  and actions.
- Package import/export works across workspaces and clearly presents
  dependencies, permissions, trust, and data inclusion choices.
- Swift remains the only trusted owner of state, credentials, actions, and
  audit.
- WebView remains sandboxed presentation only.
- The final implementation is covered by focused unit, integration, and view
  tests and passes the standard Workspace App verification commands.
