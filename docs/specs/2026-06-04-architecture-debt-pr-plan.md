# ASTRA Architecture Debt Reduction PR Plan

Date: 2026-06-04

This plan groups the architecture debt reduction work into PR-sized changes.
The ordering is by combined impact and urgency: correctness and future-change
drag first, cosmetic or lower-risk cleanup later.

## Guiding Rules

- Keep each PR narrow enough to review independently.
- Preserve current behavior unless a PR explicitly changes a contract.
- Add or update regression tests for every bug fix, debt reduction, and new
  abstraction.
- Prefer typed wrappers and presentation snapshots over ad hoc string parsing in
  views.
- For runtime, persistence, validation, or migration changes, run full
  `swift test` before merge.

## PR 1 - Typed Task Event API

Impact: Critical
Urgency: Critical

### Problem

`TaskEvent` stores `type` and `payload` as raw strings. Those strings are used
across runtime recording, task review policy, validation, task snapshots,
mission control, and SwiftUI rendering. This makes refactors fragile because
misspelled event names or mismatched payload schemas compile cleanly.

### Scope

- Add a typed task-event namespace around the existing persisted string format.
- Introduce factories for common event families:
  - task lifecycle
  - conversation
  - tool activity
  - permission approval and denial
  - plan lifecycle and plan step progress
  - validation contract and validation assertion events
  - deliverable verification
  - corrective work
- Add typed payload decode helpers that return explicit failures instead of
  silent `nil` where the caller needs diagnostics.
- Keep `TaskEvent.type` and `TaskEvent.payload` in SwiftData for compatibility.

### Primary Files

- `Astra/Models/TaskEvent.swift`
- `Astra/Models/TaskValidationContract.swift`
- `Astra/Services/TaskPlanService.swift`
- `Astra/Services/ValidationService.swift`
- `Astra/Services/TaskLifecycleCoordinator.swift`
- `Astra/Views/TaskThreadSnapshot.swift`
- `Astra/Views/RunActivityPresentation.swift`

### Tests

- Add `TaskEventTypesTests`.
- Update `ValidationServiceTests`.
- Update `TaskPlanServiceTests`.
- Update `TaskRuntimeHealthTests`.
- Update `TaskDecisionDockPresentationTests` where event type inputs are
  currently raw strings.

## PR 2 - Durable Artifact and File-Change Source of Truth

Impact: Critical
Urgency: Critical

### Problem

ASTRA currently has several related surfaces for generated output:

- files on disk under `.astra/tasks/<id>`
- SwiftData `Artifact` rows
- `TaskRun.fileChangesJSON`
- `current_state.json`
- generated-file discovery in views

Past bugs have appeared when these surfaces disagree. The app should have a
single promotion/reconciliation path that every completion and refresh flow
uses.

### Scope

- Define one artifact reconciliation service contract.
- Ensure run finalization, context refresh, generated-file shelf presentation,
  and deliverable verification call the same reconciliation path.
- Make duplicate detection explicit and tested.
- Add typed file-change kind instead of raw `changeType: String`.
- Make reconciliation idempotent.

### Primary Files

- `Astra/Services/TaskArtifactPersistenceService.swift`
- `Astra/Services/AgentRuntimeRunPersistence.swift`
- `Astra/Services/TaskContextStateManager.swift`
- `Astra/Services/TaskGeneratedFiles.swift`
- `Astra/Services/TaskDeliverableVerificationService.swift`
- `Astra/Models/Artifact.swift`
- `Astra/Models/TaskRun.swift`

### Tests

- Add regression tests for:
  - disk file exists but no SwiftData artifact exists
  - SwiftData artifact exists but stale disk path is gone
  - duplicate discovered files do not create duplicate artifacts
  - generated file appears in both task detail and file shelf after refresh
- Update `TaskContextStateTests`.
- Update `TaskDeliverableVerificationServiceTests`.
- Update `HeadlessChatScenarioTests` for no-usable-result coverage.

## PR 3 - Extract TaskMainView Decision and Runtime Surfaces

Impact: Critical
Urgency: High

### Problem

`TaskMainView.swift` is the largest owner file and mixes task rendering,
composer state, runtime permission handling, plan state, generated-file
presentation, decision dock wiring, and lifecycle actions. This increases merge
conflicts and makes UI behavior hard to reason about.

### Scope

- Extract task decision state construction into a coordinator or presentation
  builder.
- Extract runtime permission state and action handling.
- Extract generated-file opening and artifact affordance wiring.
- Extract plan/mission/verification snapshot loading out of the main view body.
- Keep user-visible layout unchanged in this PR.

### Primary Files

- `Astra/Views/TaskMainView.swift`
- `Astra/Views/TaskDecisionDockView.swift`
- `Astra/Services/TaskDecisionDockPresentation.swift`
- `Astra/Services/MissionControlPresentation.swift`
- `Astra/Services/TaskPresentationState.swift`

### Tests

- Update `TaskDecisionDockPresentationTests`.
- Update `MissionControlPresentationTests`.
- Update `ViewTests` only for integration behavior that cannot move to a
  narrower presentation test.
- Add focused tests for the extracted coordinator.

## PR 4 - Split ContentView into App Shell, Routing, and Workspace Actions

Impact: High
Urgency: High

### Problem

`ContentView.swift` owns app shell layout, workspace routing, onboarding,
workspace creation/import, shelf sessions, query/browser/markdown panels, and
settings propagation. This causes unrelated changes to touch the same file.

### Scope

- Extract workspace routing into a small `ContentSceneCoordinator`.
- Extract workspace creation/import/onboarding finalization into a service or
  coordinator.
- Extract shelf session stores into dedicated files.
- Keep the `ContentDetailPresentation` routing contract as the tested boundary.

### Primary Files

- `Astra/Views/ContentView.swift`
- `Astra/Views/ContentSceneState.swift`
- `Astra/Services/WorkspaceImportOrchestrator.swift`
- `Astra/Services/AstraExternalRouteStore.swift`
- `Astra/Services/ShelfBrowserSession.swift`
- `Astra/Services/ShelfMarkdownSession.swift`
- `Astra/Services/ShelfQuerySession.swift`

### Tests

- Update `OnboardingWizardTests`.
- Update `WorkspaceHomePresentationTests`.
- Update `ViewTests` routing coverage.
- Add focused tests for workspace creation/import routing if needed.

## PR 5 - Runtime Adapter Contract Split

Impact: High
Urgency: High

### Problem

The runtime adapter direction is strong, but `AgentRuntimeAdapter` combines too
many responsibilities: readiness, policy, launch planning, process event
parsing, worker event recording, utility prompts, post-processing, and
telemetry.

### Scope

- Split the adapter responsibilities into smaller protocols:
  - descriptor and readiness
  - policy rendering
  - process launch planning
  - process event parsing
  - worker event recording
  - utility runtime
  - post-run diagnostics
- Keep `AgentRuntimeAdapterRegistry` as the composition point.
- Add default protocol extensions to avoid a large mechanical migration in one
  commit.

### Primary Files

- `Astra/Services/AgentRuntimeAdapter.swift`
- `Astra/Services/AgentRuntimeProcessRunner.swift`
- `Astra/Services/AgentRuntimeWorker.swift`
- `Astra/Services/ClaudeModelAvailabilityService.swift`
- `Astra/Services/CopilotModelAvailabilityService.swift`
- `Astra/Services/RuntimeReadinessService.swift`

### Tests

- Update `AgentRuntimeAdapterTests`.
- Update `RuntimeReadinessServiceTests`.
- Update `AgentRuntimeWorkerTests`.
- Update provider-specific runtime tests.

## PR 6 - Central Runtime and App Settings Snapshot

Impact: High
Urgency: High

### Problem

Runtime and app settings are read directly through repeated `@AppStorage`
properties in many views. This spreads defaults, revision triggers, and provider
configuration rules across UI files.

### Scope

- Introduce typed settings snapshots:
  - `RuntimeSettingsSnapshot`
  - `ProviderSettingsSnapshot`
  - `AppUIPreferencesSnapshot`
- Add a store that reads from `UserDefaults` and exposes these snapshots.
- Replace repeated provider/model/path `@AppStorage` reads in task/composer
  views with snapshot injection.
- Preserve existing storage keys.

### Primary Files

- `Astra/Services/AppearancePreference.swift`
- `Astra/Services/RuntimeProviderSettingsStore.swift`
- `Astra/Services/AgentRuntimeConfiguration.swift`
- `Astra/Views/SettingsView.swift`
- `Astra/Views/ContentView.swift`
- `Astra/Views/TaskMainView.swift`
- `Astra/Views/ChatPanelView.swift`
- `Astra/Views/NewTaskView.swift`
- `Astra/Views/Components/ComposerToolbar.swift`

### Tests

- Add `RuntimeSettingsSnapshotTests`.
- Update `RuntimeProviderSettingsStoreTests`.
- Update `RuntimeProviderListPresentationTests`.
- Update composer/new-task presentation tests.

## PR 7 - Main-Actor Boundary Reduction

Impact: High
Urgency: Medium

### Problem

Many services are marked `@MainActor`, including runtime and task state paths.
Some main-actor usage is required by SwiftData, but file scanning, provider
parsing, process monitoring, diagnostics, and git status reads should not
inherit UI-thread constraints.

### Scope

- Identify functions that only read immutable snapshots and move them off main.
- Introduce snapshot structs for task/workspace data needed by background work.
- Keep SwiftData mutation points on main.
- Use actors for shared mutable runtime state where appropriate.

### Primary Files

- `Astra/Services/AgentRuntimeWorker.swift`
- `Astra/Services/TaskQueue.swift`
- `Astra/Services/TaskContextStateManager.swift`
- `Astra/Services/ValidationService.swift`
- `Astra/Services/AgentEventRecorder.swift`
- `Astra/Services/GitService.swift`

### Tests

- Update `ConcurrencyTests`.
- Update `QueueLockTests`.
- Update `AgentRuntimeWorkerTests`.
- Add tests proving background snapshot work does not require `@MainActor`.

## PR 8 - IO and Process Injection Expansion

Impact: High
Urgency: Medium

### Problem

The repo already has `FileSystem`, `SecretStore`, and `BinaryRunner`, but many
services still call `FileManager.default`, `Process()`, `URLSession.shared`, or
`NSWorkspace.shared` directly. This makes focused tests harder and hides failure
modes.

### Scope

- Introduce small protocols for:
  - file IO
  - process execution
  - URL loading
  - workspace opening/selecting files
- Replace direct usage in high-value services first.
- Do not abstract every AppKit call in one PR.

### Primary Files

- `ASTRACore/Protocols.swift`
- `ASTRACore/BinaryRunner.swift`
- `Astra/Services/RealFileSystem.swift`
- `Astra/Services/ValidationService.swift`
- `Astra/Services/RuntimeReadinessService.swift`
- `Astra/Services/GitService.swift`
- `Astra/Services/TaskWorkspaceAccess.swift`
- `Astra/Services/TaskDeliverableVerificationService.swift`

### Tests

- Extend `MockFileSystem`.
- Extend `StubBinaryRunner`.
- Update `ValidationServiceTests`.
- Update `GitRepositoryPanelIntegrationTests` only where direct git calls are
  still intended.

## PR 9 - Structured Error and Diagnostic Results

Impact: Medium
Urgency: Medium

### Problem

Core code uses many `try?` paths. Silent failure is acceptable for best-effort
UI niceties, but persistence, validation, provider launch, and diagnostics need
explicit failure reasons.

### Scope

- Introduce typed diagnostic result structs for:
  - context-state load/save
  - workspace import/export
  - validation assertion execution
  - artifact reconciliation
  - provider launch preflight
- Keep UI best-effort paths quiet, but have services record audit fields.

### Primary Files

- `Astra/Services/TaskContextStateManager.swift`
- `Astra/Services/WorkspaceConfigManager.swift`
- `Astra/Services/ValidationService.swift`
- `Astra/Services/AgentRuntimeLaunchPreflight.swift`
- `Astra/Services/LogDiagnosticsService.swift`
- `Astra/Services/Logger.swift`

### Tests

- Update `TaskContextStateTests`.
- Update `WorkspacePersistenceTests`.
- Update `ValidationServiceTests`.
- Update `LogDiagnosticsTests`.

## PR 10 - Browser Subsystem Split

Impact: Medium
Urgency: Medium

### Problem

Browser control is valuable but concentrated in large files. `ShelfBrowserSession`
and `ControlledBrowserController` combine transport, state, interaction policy,
debug capture, bridge environment, and presentation-facing session state.

### Scope

- Split browser logic into:
  - CDP transport
  - page/session state
  - interaction safety policy
  - debug capture
  - bridge environment registration
  - UI-facing session model
- Preserve current browser behavior.

### Primary Files

- `Astra/Services/ShelfBrowserSession.swift`
- `Astra/Services/ControlledBrowserController.swift`
- `Astra/Services/ShelfBrowserBridgeRegistry.swift`
- `Astra/Services/BrowserFailureDebugCapture.swift`
- `Astra/Services/BrowserKeypressSafety.swift`
- `Astra/Views/ShelfBrowserPanelView.swift`

### Tests

- Update `BrowserControlSafetyTests`.
- Update `BrowserFailureDebugCaptureTests`.
- Update `BrowserBridgeSecurityTests`.
- Update `ShelfBrowserPanelLayoutTests`.

## PR 11 - Prompt Assembly Section Providers

Impact: Medium
Urgency: Medium

### Problem

`AgentPromptBuilder` has good typed concepts, but the file owns too many
section sources and assembly details. Prompt behavior is central enough to need
smaller, testable section providers.

### Scope

- Define `PromptContextSectionProvider`.
- Extract providers for:
  - current task
  - thread state
  - workspace instructions
  - memories
  - recent tasks
  - skills/connectors/tools
  - browser
  - task output folder
  - ASTRA run protocol instructions
- Keep `PromptAssemblyManifest` as the public result.

### Primary Files

- `Astra/Services/AgentPromptBuilder.swift`
- `Astra/Services/TaskCapabilityResolver.swift`
- `Astra/Services/TaskContextStateManager.swift`
- `Astra/Views/PromptContextPreviewView.swift`

### Tests

- Update `ContextInjectionTests`.
- Update `PromptContextPreviewPresentationTests`.
- Update `AgentRuntimeWorkerTests` where prompt behavior is asserted.

## PR 12 - Validation Contract Result Typing and Shared Completion Policy

Impact: Medium
Urgency: Medium

### Problem

Validation contract metadata is now a strong direction, but completion policy is
still spread across approved-plan execution, validation service, task lifecycle,
deliverable verification, and no-usable-result handling.

### Scope

- Add typed validation result enums for assertion and contract outcomes.
- Introduce `TaskCompletionPolicy` that decides whether a run can complete.
- Route approved-plan, normal-run, corrective-run, and inferred-verification
  completion checks through that policy.
- Preserve current behavior unless an existing bug is explicitly fixed.

### Primary Files

- `Astra/Services/ValidationService.swift`
- `Astra/Services/TaskDeliverableVerificationService.swift`
- `Astra/Services/TaskRunLifecycleService.swift`
- `Astra/Services/AgentRuntimeWorker.swift`
- `Astra/Services/TaskCorrectiveWorkService.swift`
- `Astra/Models/TaskValidationContract.swift`

### Tests

- Update `ValidationServiceTests`.
- Update `TaskRunLifecycleServiceTests`.
- Update `TaskDeliverableVerificationServiceTests`.
- Update `HeadlessChatScenarioTests`.

## PR 13 - Git Service Boundary and Testability

Impact: Medium
Urgency: Low

### Problem

`GitService.shared` is used heavily from `WorkspaceGitViewModel`. It mixes git
status, worktree management, diffing, staging, PR lookup, PR checks, and
authoring. This makes the repository panel hard to test without real git state.

### Scope

- Split git responsibilities into smaller clients:
  - status
  - diff
  - worktree
  - branch
  - authoring
  - pull request metadata
- Inject a git client into `WorkspaceGitViewModel`.
- Keep a live `GitService` facade for app wiring.

### Primary Files

- `Astra/Services/GitService.swift`
- `Astra/Views/WorkspaceGitViewModel.swift`
- `Astra/Views/WorkspaceGitSectionView.swift`
- `Astra/Services/GitAuthoringService.swift`

### Tests

- Update `GitRepositoryPanelIntegrationTests`.
- Update `GitAuthoringServiceTests`.
- Update `GitPullRequestTests`.
- Update `GitPushEnablementTests`.

## PR 14 - Test Suite Decomposition

Impact: Medium
Urgency: Low

### Problem

Some tests are now large integration buckets. That makes failures harder to
triage and increases the chance of hidden async side effects.

### Scope

- Split `ViewTests` into focused presentation and integration suites.
- Split `HeadlessChatScenarioTests` by runtime and scenario family where
  practical.
- Move shared fixtures into small helpers.
- Mark real-provider and smoke tests clearly.

### Primary Files

- `Tests/ViewTests.swift`
- `Tests/HeadlessChatScenarioTests.swift`
- `Tests/TaskPromptFixtures.swift`
- `Tests/E2ETestSupport.swift`

### Tests

- This PR is itself test-structure work. Run full `swift test`.

## PR 15 - Package and Folder Architecture Cleanup

Impact: Low
Urgency: Low

### Problem

`Astra/Services` is very flat. As the app grows, finding the owner for a change
gets harder.

### Scope

- Move files into grouped folders without behavior changes:
  - `Runtime`
  - `Tasks`
  - `Persistence`
  - `Validation`
  - `Capabilities`
  - `Browser`
  - `Git`
  - `Settings`
  - `Diagnostics`
- Keep SwiftPM target paths working.
- Avoid mixing moves with logic changes.

### Primary Files

- `Package.swift`
- `Astra/Services/**`
- `Tests/**` imports only if needed

### Tests

- Run full `swift test`.
- Run `git diff --check`.

## PR 16 - Architecture Contract Documentation

Impact: Low
Urgency: Low

### Problem

The architecture has strong implicit contracts, but they are scattered across
code and tests.

### Scope

- Add concise docs for:
  - runtime adapter responsibilities
  - task-event schema
  - artifact persistence lifecycle
  - prompt assembly and context capsule
  - validation and completion gates
  - workspace storage boundaries

### Primary Files

- `docs/architecture/runtime-adapters.md`
- `docs/architecture/task-events.md`
- `docs/architecture/artifact-persistence.md`
- `docs/architecture/prompt-assembly.md`
- `docs/architecture/validation-completion-policy.md`
- `docs/security/security-boundaries.md`

### Tests

- No runtime tests required unless docs expose an inaccurate behavior and code
  is corrected in the same PR.
- Run `git diff --check`.

## Suggested Merge Sequence

1. PR 1 - Typed Task Event API
2. PR 2 - Durable Artifact and File-Change Source of Truth
3. PR 3 - Extract TaskMainView Decision and Runtime Surfaces
4. PR 4 - Split ContentView into App Shell, Routing, and Workspace Actions
5. PR 5 - Runtime Adapter Contract Split
6. PR 6 - Central Runtime and App Settings Snapshot
7. PR 7 - Main-Actor Boundary Reduction
8. PR 8 - IO and Process Injection Expansion
9. PR 9 - Structured Error and Diagnostic Results
10. PR 10 - Browser Subsystem Split
11. PR 11 - Prompt Assembly Section Providers
12. PR 12 - Validation Contract Result Typing and Shared Completion Policy
13. PR 13 - Git Service Boundary and Testability
14. PR 14 - Test Suite Decomposition
15. PR 15 - Package and Folder Architecture Cleanup
16. PR 16 - Architecture Contract Documentation

## Validation Baseline

Every PR should run:

```bash
git diff --check
swift test --filter <RelevantSuiteOrTestName>
```

PRs touching runtime, persistence, validation, migration, task lifecycle, or
shared presentation should also run:

```bash
swift test
```

UI PRs should additionally launch the development app:

```bash
./script/build_and_run.sh --verify
```

