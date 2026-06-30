# ASTRA Architecture Debt Tracker

Date created: 2026-06-04
Last reviewed: 2026-06-05

This document supersedes the original architecture debt PR plan after the
merged architecture cleanup stack. The app is in better shape: services are
foldered, runtime adapter roles are more explicit, task-event names are typed,
completion policy is centralized, prompt assembly has a provider contract,
artifact reconciliation exists, architecture docs were added, and the largest
test files were decomposed.

The remaining debt is now narrower and easier to attack. The biggest risks are
still at durable storage boundaries, oversized owner files, direct settings
access, and main-actor IO. The ordering below is by combined impact and urgency.

## Current Baseline

### Completed Architecture Improvements

- `Astra/Services` has no direct Swift files. Service code is grouped under:
  `Browser`, `Capabilities`, `Diagnostics`, `Git`, `Persistence`, `Runtime`,
  `Settings`, `Tasks`, and `Validation`.
- `TaskEventType` and `TaskEventTypes` wrap persisted event strings, and
  `TaskEvent.decodePayload(...)` exposes explicit decode failures.
- `TaskCompletionPolicy` centralizes validation-contract, deliverable,
  inferred-validation, and manual artifact completion gates.
- `TaskArtifactPersistenceService` reconciles discovered task output artifacts
  and gives run finalization, deliverable verification, and context state a
  shared promotion path.
- `AgentRuntimeAdapter` is split into smaller protocol responsibilities, with
  the registry remaining the provider composition point.
- `PromptContextSectionProvider` exists and prompt sections are ordered through
  provider lists.
- `ContentSceneState` and workspace import/orchestration helpers removed some
  routing logic from `ContentView`.
- The headless and view test suites are split into smaller files with focused
  regression coverage.
- Architecture docs now exist for runtime adapters, task events, prompt
  assembly, artifact persistence, and validation/completion policy.

### Current Debt Signals

These counts are not targets by themselves. They identify where repeated
change pressure still lives.

- Large source files:
  - `Astra/Views/TaskMainView.swift`: 6,743 lines.
  - `Astra/Services/Browser/ShelfBrowserSession.swift`: 5,676 lines.
  - `Astra/Views/ContentView.swift`: 4,811 lines.
  - `Astra/Views/WorkspaceRightRailView.swift`: 3,332 lines.
  - `Astra/Views/ChatPanelView.swift`: 3,053 lines.
  - `Astra/Services/Runtime/AgentRuntimeAdapter.swift`: 2,776 lines.
  - `Astra/Views/PluginCatalogView.swift`: 2,723 lines.
  - `Astra/Views/ShelfMarkdownPanelView.swift`: 2,715 lines.
  - `Astra/Views/WorkspaceGitSectionView.swift`: 2,504 lines.
  - `Astra/Views/ConfigureView.swift`: 2,414 lines.
  - `Astra/Services/Diagnostics/LogDiagnosticsService.swift`: 2,392 lines.
  - `Astra/Views/TaskSidebarView.swift`: 2,300 lines.
  - `Astra/Views/ShelfQueryPanelView.swift`: 2,239 lines.
  - `Astra/Services/Persistence/TaskContextStateManager.swift`: 2,138 lines.
  - `Astra/Services/Runtime/AgentPromptBuilder.swift`: 2,125 lines.
  - `Astra/Views/OnboardingWizardView.swift`: 2,122 lines.
  - `Astra/Services/Runtime/AgentProcessSupport.swift`: 1,981 lines.
  - `Astra/Services/Runtime/AgentRuntimeWorker.swift`: 1,971 lines.
  - `Astra/Services/Browser/BrowserAnalysis.swift`: 1,963 lines.
  - `Astra/Services/Git/GitService.swift`: 1,953 lines.
  - `Astra/Services/Browser/ControlledBrowserController.swift`: 1,926 lines.
  - `Astra/Views/ShelfBrowserPanelView.swift`: 1,923 lines.
- Repeated source patterns:
  - `@AppStorage`: 125 source occurrences.
  - `FileManager.default`: 182 source occurrences.
  - `try?`: 447 source occurrences.
  - `JSONSerialization`: 73 source occurrences.
  - `Process()`: 19 source occurrences.
  - `@MainActor`: 267 source occurrences.
- Package boundary:
  - `Package.swift` still builds most app code as one `ASTRA` target. The new
    service folders improve ownership but do not enforce dependencies at compile
    time.

### Automated Drift Guardrails

`ArchitectureFitnessTests` now protects the highest-value architecture
invariants without requiring every remaining debt item to be fixed in one PR:

- `Astra/Services` may only contain known subsystem folders and no direct Swift
  files.
- Prompt section provider IDs must stay unique and explicit for initial and
  follow-up prompt assembly modes.
- Typed task-event constants must remain explicitly categorized.
- Raw stop-reason assignments must stay inside runtime, completion, and
  persistence boundaries.
- Git status parsing must stay behind the `ASTRAGitContracts` SwiftPM boundary.
- Capability side effects must stay out of `PluginCatalogView`.
- Workspace rail and catalog import presentation contracts must stay outside
  their large SwiftUI owner files.
- Current large owner files and direct `@AppStorage` usage have realistic
  budgets so new work shrinks or extracts instead of quietly growing them.

## Guiding Rules

- Keep each PR reviewable and behavior-preserving unless the contract change is
  explicit.
- Add or update regression tests for every bug fix, new abstraction, or debt
  reduction.
- Keep persisted SwiftData storage compatible unless the PR includes a tested
  migration.
- Prefer typed wrappers, Codable payloads, and presentation snapshots over raw
  strings and ad hoc parsing in views.
- Keep SwiftData mutations on the main actor, but move pure parsing, file IO,
  process execution, and presentation construction off the main actor when
  practical.
- For runtime, persistence, validation, migration, or provider contract changes,
  run full `swift test` before merge.

## Next PR 1 - Durable Event Payload and Stop-Reason Typing

Impact: Critical
Urgency: High

### Problem

`TaskEvent.type` now has a typed namespace, but `TaskEvent.payload` remains a
mixed plain-text/JSON string boundary. Completion and review logic also still
uses raw stop-reason strings such as `no_usable_result`,
`validation_contract_failed`, and `deliverable_verification_failed`.

This is the highest cross-cutting risk because runtime recording, validation,
task snapshots, mission control, pending-review policy, and UI rendering all
depend on the same durable event and stop-reason strings.

### Scope

- Add typed factories or envelopes for high-value structured event families:
  - validation contracts and assertions
  - deliverable verification
  - plan lifecycle and plan step progress
  - handoff and corrective work
  - mission checkpoints and audit bundles
  - permission approval requests
- Introduce `TaskRunStopReason` as a typed wrapper around persisted stop-reason
  strings.
- Keep raw SwiftData storage fields for compatibility, but make new code write
  through typed constructors.
- Add explicit decode diagnostics where currently a failed payload decode is
  treated as absence.
- Document which event families are allowed to remain plain text.

### Primary Files

- `Astra/Models/TaskEvent.swift`
- `Astra/Models/TaskEventTypes.swift`
- `Astra/Models/TaskRun.swift`
- `Astra/Models/TaskValidationContract.swift`
- `Astra/Services/Tasks/AgentEventRecorder.swift`
- `Astra/Services/Tasks/PendingTaskReviewPolicy.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Views/TaskThreadSnapshot.swift`
- `Astra/Views/RunActivityPresentation.swift`

### Tests

- Add or expand `TaskEventTypesTests`.
- Add `TaskRunStopReasonTests`.
- Update `ValidationServiceTests`.
- Update `TaskPlanServiceTests`.
- Update `TaskRuntimeHealthTests`.
- Update `TaskDecisionDockPresentationTests`.
- Update headless completion-blocking scenarios.

## Next PR 2 - Artifact and File-Change Storage Hardening

Impact: Critical
Urgency: High

### Problem

Artifact reconciliation exists, but durable artifact and file-change storage is
still partly stringly:

- `Artifact.type` is a raw string.
- `TaskRun.fileChangesJSON` stores a JSON blob.
- `StoredFileChange.changeType` is a raw string.
- `TaskContextState` mirrors changed files and artifact references with string
  statuses and types.

The app is safer than before, but there is still room for disk artifacts,
SwiftData artifacts, run file changes, and current state to drift.

### Scope

- Introduce typed `ArtifactKind` and `StoredFileChangeKind` persistence helpers.
- Keep compatibility readers for historic artifact and file-change strings.
- Make artifact/file-change normalization report typed reconciliation outcomes.
- Define one generated-output index that can feed shelf presentation,
  validation, context state, and run finalization.
- Ensure stale artifact detection and duplicate detection use the same normalized
  path rules.
- Keep `TaskArtifactPersistenceService` as the single write/promotion boundary.

### Primary Files

- `Astra/Models/Artifact.swift`
- `Astra/Models/TaskRun.swift`
- `Astra/Services/Persistence/TaskArtifactPersistenceService.swift`
- `Astra/Services/Persistence/TaskContextStateManager.swift`
- `Astra/Services/Persistence/TaskOutputDiscovery.swift`
- `Astra/Services/Tasks/TaskGeneratedFiles.swift`
- `Astra/Services/Validation/TaskDeliverableExpectation.swift`
- `Astra/Services/Validation/TaskDeliverableVerificationService.swift`
- `Astra/Services/Runtime/AgentRuntimeRunPersistence.swift`

### Tests

- Expand `TaskArtifactPersistenceServiceTests`.
- Expand `TaskContextStateTests`.
- Expand `TaskDeliverableVerificationServiceTests`.
- Expand `TaskFileShelfSnapshotTests`.
- Add regressions for:
  - historic `Write` and `Edit` file-change strings
  - unknown artifact kinds
  - duplicate normalized paths
  - stale SwiftData artifact rows
  - disk file discovered after a run but before UI refresh

## Next PR 3 - Browser Session Command Router Split

Impact: Critical
Urgency: High

### Problem

`ShelfBrowserSession` is still the largest remaining service owner. It combines
WebKit lifecycle, controlled Chromium lifecycle, bridge health and command
routing, page reads, snapshots, browser actions, Google Drive and Google Docs
workflows, flight recording, debug capture, and run-guard decisions.

The browser subsystem has better support files now, but the main session class
is still too broad for safe changes.

### Scope

- Keep `ShelfBrowserSession` focused on observable session state and browser
  lifecycle.
- Extract bridge command dispatch to a `BrowserBridgeCommandRouter`.
- Extract page read and snapshot behavior to a `BrowserPageSnapshotService`.
- Extract click/type/fill/control-ID actions to a `BrowserControlActionService`.
- Extract Google Drive and Google Docs workflows to
  `GoogleWorkspaceBrowserService`.
- Extract debug capture and flight recording orchestration to a small service
  that can be tested without a full session.
- Preserve the public bridge response contract.

### Primary Files

- `Astra/Services/Browser/ShelfBrowserSession.swift`
- `Astra/Services/Browser/BrowserBridgeServer.swift`
- `Astra/Services/Browser/BrowserPageReadService.swift`
- `Astra/Services/Browser/BrowserAnalysis.swift`
- `Astra/Services/Browser/BrowserFlightRecorder.swift`
- `Astra/Services/Browser/BrowserFailureDebugCapture.swift`
- `Astra/Services/Browser/BrowserSiteAdapters.swift`
- `Astra/Services/Browser/ControlledBrowserController.swift`

### Tests

- Expand `BrowserBridgeSecurityTests`.
- Expand `BrowserPageReadServiceTests`.
- Expand `BrowserAnalysisTests`.
- Expand `BrowserControlSafetyTests`.
- Expand `BrowserFlightRecorderTests`.
- Expand `BrowserFailureDebugCaptureTests`.
- Add command-router tests that do not require WebKit.

## Next PR 4 - Central Settings Snapshot Injection

Impact: High
Urgency: High

### Problem

Typed settings snapshots and stores exist, but views still read and write many
of the same defaults directly through `@AppStorage`. This repeats default
values, revision triggers, provider path rules, model-cache dependencies, and
runtime selection behavior across multiple views.

### Scope

- Introduce a narrow app-level settings environment or observable store that
  exposes:
  - runtime defaults
  - provider paths and provider-specific settings
  - model cache and revisions
  - budget and policy defaults
  - UI preferences that affect layout
- Replace repeated provider/model/path `@AppStorage` reads in task/composer
  surfaces with snapshot injection.
- Keep `SettingsView` as the primary editing surface for persisted defaults.
- Preserve existing storage keys.
- Centralize storage-key constants for legacy keys that are still string
  literals, such as `defaultRuntimeID`, `defaultModel`, `claudePath`,
  `copilotPath`, `workspacesRoot`, `timeoutSeconds`, and `validationModel`.

### Primary Files

- `Astra/Services/Settings/RuntimeSettingsSnapshot.swift`
- `Astra/Services/Settings/RuntimeProviderSettingsStore.swift`
- `Astra/Services/Settings/AppearancePreference.swift`
- `Astra/Views/ContentView.swift`
- `Astra/Views/TaskMainView.swift`
- `Astra/Views/ChatPanelView.swift`
- `Astra/Views/NewTaskView.swift`
- `Astra/Views/ScheduleEditorView.swift`
- `Astra/Views/Components/ComposerToolbar.swift`
- `Astra/Views/SettingsView.swift`

### Tests

- Expand `RuntimeSettingsSnapshotTests`.
- Expand `RuntimeProviderSettingsStoreTests`.
- Expand `SettingsViewPrivacyTests`.
- Update composer and new-task presentation tests.
- Add regression coverage for model normalization after default runtime changes.

## Next PR 5 - Prompt Provider Extraction and IO Snapshot Boundary

Impact: High
Urgency: High

### Problem

`PromptContextSectionProvider` exists, but most provider implementations are
still nested inside `AgentPromptBuilder`. The builder is also main-actor
isolated and still performs file reads and directory listing while assembling
prompts.

This keeps prompt changes concentrated in a 2,180-line file and makes it harder
to reason about what work runs on the main actor.

### Scope

- Move prompt section providers out of `AgentPromptBuilder` into focused files.
- Keep provider ordering explicit and tested.
- Introduce a prompt IO snapshot that is loaded before prompt assembly:
  - current state paths
  - session history presence
  - recent turn output paths
  - generated task-folder files
  - readfile availability
- Keep SwiftData/task reads where needed, but make pure prompt assembly
  deterministic over the snapshot.
- Keep Context Capsule and Context Source Index wording unchanged unless tests
  intentionally update it.

### Primary Files

- `Astra/Services/Runtime/AgentPromptBuilder.swift`
- `Astra/Services/Tasks/PromptContextSectionProvider.swift`
- `Astra/Services/Persistence/TaskContextStateManager.swift`
- `Astra/Services/Persistence/SessionHistoryManager.swift`
- `Astra/Services/Tasks/TaskGeneratedFiles.swift`
- `Astra/Views/PromptContextPreviewView.swift`

### Tests

- Expand `AgentRuntimeWorkerTests`.
- Expand `ContextInjectionTests`.
- Expand `TaskContextStateTests`.
- Expand `PromptContextPreviewPresentationTests`.
- Add provider-ordering tests for initial and follow-up prompt modes.
- Add tests that prompt assembly uses a supplied IO snapshot.

## Next PR 6 - TaskMainView Composer and Runtime Coordinator Split

Impact: High
Urgency: Medium

### Problem

`TaskMainView` is still the largest source file. It mixes chat rendering,
composer state, runtime readiness, permission decisions, plan state, verification
loading, generated-file actions, schedule creation, recap generation, and
toolbar behavior.

Some presentation helpers now exist, but the owner file still receives too many
unrelated changes.

### Scope

- Extract composer state and actions into a testable coordinator.
- Extract runtime readiness and permission presentation wiring.
- Extract generated-file opening and files-popover state.
- Extract schedule creation and recap side effects.
- Keep the visible layout stable.
- Preserve `TaskThreadViewModel`, `TaskDecisionDockPresentation`, and
  `MissionControlPresentation` as the primary presentation boundaries.

### Primary Files

- `Astra/Views/TaskMainView.swift`
- `Astra/Views/TaskThreadViewModel.swift`
- `Astra/Services/Tasks/TaskDecisionDockContextBuilder.swift`
- `Astra/Services/Tasks/TaskDecisionDockPresentation.swift`
- `Astra/Services/Tasks/MissionControlPresentation.swift`
- `Astra/Services/Tasks/TaskGeneratedFileOpenRouter.swift`
- `Astra/Services/Tasks/TaskVerificationPresentationLoader.swift`

### Tests

- Expand `TaskDecisionDockContextBuilderTests`.
- Expand `TaskDecisionDockPresentationTests`.
- Expand `MissionControlPresentationTests`.
- Expand `TaskGeneratedFileOpenRouterTests`.
- Expand `TaskThreadConversationSnapshotTests`.
- Keep `ViewTests` for integration-only behavior.

## Next PR 7 - ContentView App Shell and Workspace Action Split

Impact: High
Urgency: Medium

### Problem

`ContentView` still owns app shell layout, workspace selection, onboarding,
workspace setup, workspace import, shelf panel state, external routing,
provider-settings propagation, runtime model refreshes, and generated preview
loading.

`ContentSceneState` and import helpers reduced some risk, but the shell still
has too much responsibility.

### Scope

- Move workspace setup form and validation to dedicated files.
- Extract shelf panel state and preview auto-load behavior into a coordinator.
- Extract runtime model refresh orchestration out of the shell view.
- Keep `ContentDetailPresentation` as the routing contract.
- Keep user-visible shell behavior unchanged.

### Primary Files

- `Astra/Views/ContentView.swift`
- `Astra/Views/ContentSceneState.swift`
- `Astra/Services/Persistence/WorkspaceImportOrchestrator.swift`
- `Astra/Services/Settings/AstraExternalRouteStore.swift`
- `Astra/Services/Runtime/RuntimeProviderAvailabilityService.swift`
- `Astra/Services/Runtime/RuntimeModelAvailability.swift`
- `Astra/Services/Browser/ShelfSessionStores.swift`

### Tests

- Expand `ViewTests`.
- Expand `OnboardingWizardTests`.
- Expand `WorkspaceHomePresentationTests`.
- Expand `RuntimeProviderListPresentationTests`.
- Add focused tests for shelf panel state transitions and preview auto-load.

## Next PR 8 - Main-Actor IO Boundary Reduction

Impact: High
Urgency: Medium

### Problem

Many services are `@MainActor` because they touch SwiftData or UI-observed
state, but several of those same services also perform file IO, JSON parsing,
directory scans, and process-adjacent work. This increases UI responsiveness
risk and makes concurrency behavior harder to reason about.

### Scope

- Identify main-actor services that mix SwiftData mutation with pure IO.
- Move pure file reads, directory enumeration, and JSON parsing behind async
  loaders or nonisolated helpers.
- Expand `FileSystem` or introduce narrower file-reader protocols where tests
  need deterministic IO.
- Keep SwiftData object mutation on the main actor.
- Replace `DispatchQueue.main.async` patterns with structured Swift concurrency
  where safe.

### Primary Files

- `Astra/Services/Runtime/AgentPromptBuilder.swift`
- `Astra/Services/Persistence/TaskContextStateManager.swift`
- `Astra/Services/Persistence/TaskOutputDiscovery.swift`
- `Astra/Services/Tasks/TaskVerificationPresentationLoader.swift`
- `Astra/Views/TaskThreadViewModel.swift`
- `Astra/Views/TaskMainView.swift`
- `Astra/Views/ContentView.swift`
- `ASTRACore/Protocols.swift`
- `Astra/Services/Persistence/RealFileSystem.swift`

### Tests

- Expand `ConcurrencyTests`.
- Expand `TaskContextStateTests`.
- Expand `TaskThreadSnapshotTests`.
- Expand `TaskVerificationPresentationLoader` coverage.
- Expand `QueueLockTests` for injected filesystem behavior.
- Run full `swift test`.

## Next PR 9 - Git Service Decomposition

Impact: Medium
Urgency: Medium

### Problem

Git is now foldered and authoring has its own service, but `GitService` still
combines repository discovery, status parsing, worktree management, GitHub PR
lookup, comments, checks, command execution, and timeout handling.

This is a moderate-risk boundary because it is user-facing and process-heavy,
but it is less cross-cutting than task events and runtime completion.

### Scope

- Split pure parsing from process execution.
- Extract `GitStatusService`.
- Extract `GitWorktreeService`.
- Extract `GitHubPullRequestService`.
- Extract comments and check summary lookup into focused components.
- Keep the current UI-facing structs stable unless tests update them.
- Route git subprocesses through a single runner abstraction.

### Primary Files

- `Astra/Services/Git/GitService.swift`
- `Astra/Services/Git/GitAuthoringService.swift`
- `Astra/Views/WorkspaceGitViewModel.swift`
- `Astra/Views/WorkspaceGitSectionView.swift`
- `ASTRACore/BinaryRunner.swift`

### Tests

- Expand `GitWorktreeTests`.
- Expand `GitRepositoryPanelIntegrationTests`.
- Expand `GitPullRequestTests`.
- Expand `GitPushEnablementTests`.
- Expand `GitAuthoringRegressionTests`.
- Add tests for parser-only components with no subprocess execution.

## Next PR 10 - Process Execution and Timeout Contract

Impact: Medium
Urgency: Medium

### Problem

Direct `Process()` usage is relatively contained, but process launch, timeout,
cancellation, stdout/stderr collection, and failure diagnostics still appear in
multiple services. Several services also use `DispatchQueue.asyncAfter` for
timeouts.

### Scope

- Define one process execution result shape with:
  - exit code
  - stdout
  - stderr
  - launch error
  - timeout flag
  - cancellation flag
  - elapsed time
- Route Git, validation commands, runtime helper probes, database shell commands,
  and browser helper processes through shared process primitives where practical.
- Preserve provider-specific launch planning in runtime adapters.
- Standardize timeout messages and audit fields.

### Primary Files

- `ASTRACore/BinaryRunner.swift`
- `Astra/Services/Runtime/AgentProcessSupport.swift`
- `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`
- `Astra/Services/Git/GitService.swift`
- `Astra/Services/Validation/ValidationService.swift`
- `Astra/Services/Validation/TaskDeliverableVerificationService.swift`
- `Astra/Services/Tasks/SpecEngine.swift`
- `Astra/Services/Tasks/DatabaseQueryService.swift`
- `Astra/Services/Browser/ControlledBrowserController.swift`

### Tests

- Expand `AsyncProcessTests`.
- Expand `ProcessMonitorTests`.
- Expand `GitAuthoringRegressionTests`.
- Expand `ValidationServiceTests`.
- Expand `TaskDeliverableVerificationServiceTests`.
- Expand runtime adapter process-launch tests.

## Next PR 11 - Structured JSON Decode and Diagnostic Results

Impact: Medium
Urgency: Medium

### Problem

`JSONSerialization` and `try?` are still used in many source paths. Some uses are
fine for generic bridge objects, but critical runtime, browser, validation, and
diagnostic paths should return typed decode errors rather than collapsing
failures into empty results.

### Scope

- Audit `JSONSerialization` in runtime, browser, diagnostics, and validation.
- Replace high-value bridge and runtime payload parsing with Codable structs.
- Keep generic `[String: Any]` only at true dynamic bridge boundaries.
- Convert silent `try?` in critical state-loading paths to typed result values.
- Add logging or user-facing diagnostics for malformed provider/runtime payloads.

### Primary Files

- `Astra/Services/Browser/ShelfBrowserSession.swift`
- `Astra/Services/Browser/ControlledBrowserCDPTransport.swift`
- `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- `Astra/Services/Runtime/AgentProcessSupport.swift`
- `Astra/Services/Diagnostics/LogDiagnosticsService.swift`
- `Astra/Services/Persistence/TaskContextStateManager.swift`
- `Astra/Services/Validation/ValidationService.swift`
- `ASTRACore/StreamEventParser.swift`
- `ASTRACore/CopilotStreamEventParser.swift`

### Tests

- Expand `StreamParserTests`.
- Expand `CopilotRuntimeTests`.
- Expand `BrowserBridgeSecurityTests`.
- Expand `BrowserPageReadServiceTests`.
- Expand `LogDiagnosticsTests`.
- Expand `TaskContextStateTests`.
- Add malformed-payload regressions for each converted boundary.

## Next PR 12 - SwiftPM Module Boundary Pilot

Impact: Medium
Urgency: Low

### Problem

Service folders improved ownership, but the compiler still sees most app code as
one `ASTRA` module. That means views can still reach directly into lower-level
runtime, persistence, and browser internals.

This should wait until the higher-impact storage and owner-file splits land,
because moving modules too early can create broad mechanical churn.

### Scope

- Pilot one small compile-time boundary before splitting the whole app.
- Candidate module boundaries:
  - task domain/event payload contracts
  - runtime adapter contracts
  - persistence path and file-index contracts
  - git parser contracts
- Keep SwiftUI views in the app target.
- Avoid circular dependencies by moving only pure or low-dependency types first.

### Primary Files

- `Package.swift`
- `ASTRACore`
- `Astra/Models`
- `Astra/Services/Runtime`
- `Astra/Services/Persistence`
- `Astra/Services/Git`
- `Tests`

### Tests

- Run full `swift test`.
- Run `swift build`.
- Add import-boundary tests only if the new module exposes public contracts.
- Verify `./script/build_and_run.sh --verify` for app packaging.

## Next PR 13 - Capability Catalog and Plugin UI Boundary

Impact: Medium
Urgency: Low

### Problem

Capabilities are organized in their own folder, but the capability/plugin area
still has broad owner files. `PluginCatalogView` is almost 3,000 lines and
capability services contain many related but distinct concerns: package
validation, activation, catalog inventory, install/uninstall, sharing,
runtime integrity, and UI projection.

### Scope

- Separate capability catalog data from UI presentation state.
- Extract plugin catalog sections into focused views or presentation models.
- Keep package validation and runtime integrity as service boundaries.
- Keep install/uninstall side effects out of view code.
- Preserve existing package schema behavior.

### Primary Files

- `Astra/Views/PluginCatalogView.swift`
- `Astra/Services/Capabilities/PluginCatalog.swift`
- `Astra/Services/Capabilities/CapabilityCatalogInventory.swift`
- `Astra/Services/Capabilities/CapabilityPackageValidator.swift`
- `Astra/Services/Capabilities/CapabilityInstaller.swift`
- `Astra/Services/Capabilities/CapabilityUninstaller.swift`
- `Astra/Services/Capabilities/CapabilityRuntimeIntegrityService.swift`

### Tests

- Expand `PluginCatalogTests`.
- Expand `CapabilityCatalogPolicyTests`.
- Expand `CapabilityPackageValidatorTests`.
- Expand `CapabilityInstallerTests`.
- Expand `CapabilityUninstallerTests`.
- Expand `CapabilityRuntimeIntegrityServiceTests`.

## Next PR 14 - Workspace Rail and Catalog View Decomposition

Impact: Medium
Urgency: Low

### Problem

Some large SwiftUI surfaces remain large primarily because of presentation
composition rather than core correctness risk. `WorkspaceRightRailView`,
`PluginCatalogView`, `ChatPanelView`, and shelf views are still likely merge
conflict points.

### Scope

- Extract presentation models before extracting view fragments.
- Split repeated row/card/section UI into focused components.
- Keep the lean design-system rules intact.
- Avoid new nested card chrome or marketing-style composition.
- Keep integration tests narrow and move pure decisions to presentation tests.

### Primary Files

- `Astra/Views/WorkspaceRightRailView.swift`
- `Astra/Views/PluginCatalogView.swift`
- `Astra/Views/ChatPanelView.swift`
- `Astra/Views/ShelfMarkdownPanelView.swift`
- `Astra/Views/ShelfQueryPanelView.swift`
- `Astra/Views/ShelfBrowserPanelView.swift`
- `docs/design-system/lean-ui-system.md`

### Tests

- Expand `CapabilityRailPresentationTests`.
- Expand `WorkspaceCanvasPanelPresentationTests`.
- Expand `ComposerPresentationTests`.
- Expand `QuerySessionPresentationTests`.
- Expand shelf panel layout tests.

## Next PR 15 - Architecture Fitness Tests and Debt Metrics

Impact: Low
Urgency: Low

### Problem

The architecture cleanup improved the tree, but there are few automated guard
rails preventing drift back to root service files, hidden event strings, broad
direct settings reads, or unbounded owner files.

### Scope

- Add lightweight architecture fitness tests or scripts for:
  - no direct Swift files under `Astra/Services`
  - all new task-event constants registered in category mapping
  - no new raw stop-reason strings outside the typed boundary
  - prompt provider IDs remain unique and ordered
  - service folders remain known and intentional
- Add non-blocking debt metrics documentation for:
  - large files
  - direct `@AppStorage`
  - direct `FileManager.default`
  - `JSONSerialization`
  - direct `Process()`
- Keep thresholds realistic so the tests stop regressions without forcing a
  giant cleanup PR.

### Primary Files

- `Tests`
- `docs/specs/2026-06-04-architecture-debt-pr-plan.md`
- `Astra/Models/TaskEventTypes.swift`
- `Astra/Services/Tasks/PromptContextSectionProvider.swift`
- `Package.swift`

### Tests

- Add `ArchitectureFitnessTests`.
- Run `git diff --check`.
- Run focused architecture tests.
- Run full `swift test` when a rule touches runtime, persistence, or event
  contracts.

## Suggested Execution Order

1. Next PR 1: Durable Event Payload and Stop-Reason Typing.
2. Next PR 2: Artifact and File-Change Storage Hardening.
3. Next PR 3: Browser Session Command Router Split.
4. Next PR 4: Central Settings Snapshot Injection.
5. Next PR 5: Prompt Provider Extraction and IO Snapshot Boundary.
6. Next PR 6: TaskMainView Composer and Runtime Coordinator Split.
7. Next PR 7: ContentView App Shell and Workspace Action Split.
8. Next PR 8: Main-Actor IO Boundary Reduction.
9. Next PR 9: Git Service Decomposition.
10. Next PR 10: Process Execution and Timeout Contract.
11. Next PR 11: Structured JSON Decode and Diagnostic Results.
12. Next PR 12: SwiftPM Module Boundary Pilot.
13. Next PR 13: Capability Catalog and Plugin UI Boundary.
14. Next PR 14: Workspace Rail and Catalog View Decomposition.
15. Next PR 15: Architecture Fitness Tests and Debt Metrics.

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
## Definition of Done for Each PR

- The PR states which architecture boundary it tightens.
- The PR preserves behavior unless the contract change is explicit.
- Regression tests cover the changed boundary.
- For source-only docs or fitness-test changes, `git diff --check` is enough.
- For runtime, persistence, validation, provider, process, or SwiftData changes,
  run focused tests plus full `swift test`.
- For UI shell or SwiftUI surface changes, run focused presentation/view tests
  and rebuild `ASTRA Dev.app` with `./script/build_and_run.sh --verify`.
