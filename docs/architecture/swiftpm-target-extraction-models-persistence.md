# SwiftPM target extraction — Models & Persistence (investigation, PR 13 follow-up)

**Status: investigated, extraction deferred.** This documents why `Astra/Models/*.swift`
and `Astra/Services/Persistence/*.swift` were **not** split into new SwiftPM
targets in this PR, with exact evidence, so a future PR can unblock them
deliberately instead of re-discovering the same walls.

Source task: PR 13 ("Extract First SwiftPM Leaf Targets") in
`docs/superpowers/plans/2026-07-01-architectural-review-pr-split.md`, which
itself hedges: *"Choose the smallest first extraction: models/contracts plus
file-reading architecture tests, or persistence contracts if model extraction
is too disruptive."* The working hypothesis going in was that `Models` is pure
data (`Foundation`/`SwiftData`/`ASTRACore` only) and could become `ASTRAModels`
depending only on `ASTRACore`, with `Persistence` as a second target on top of
it. That hypothesis does not survive a full symbol-level dependency sweep.

## Method

The whole `ASTRA` target is one Swift module today (~599 files across
`Views`/`Services`/`Models`/`AppIntents`), so there are no per-file `import`
statements between subsystems to grep — any type can reference any other type
with zero declared dependency. To find the *real* dependency graph:

1. Listed every top-level type defined in each Services subsystem folder
   (`Runtime`, `Capabilities`, `Tasks`, `Settings`, `WorkspaceApps`, `Security`,
   `Validation`, `Packs`, `Diagnostics`, ~650+ type names total).
2. Grepped `Astra/Models/*.swift` and `Astra/Services/Persistence/*.swift` for
   every one of those names, plus `AppLogger` and `WorkspaceExecutionEnvironment`
   specifically (both called out in the original task brief as likely hazards).
3. Manually confirmed every hit is a real call site (not a comment or a
   coincidental substring) and traced each referenced symbol back to its
   defining file.
4. Checked the reverse direction for the types Models needs, to see whether
   the dependency is one-directional (extractable with a bigger target) or
   circular (not extractable without breaking the cycle).

## Finding 1 — `Astra/Models/` is not clean

`import` statements alone (`Foundation`, `SwiftData`, `ASTRACore` only) suggested
a clean split. Symbol-level references tell a different story — 9 of the 27
files reach outside Models:

| File | External symbol(s) used | Defined in |
|---|---|---|
| `AgentTask.swift:100-102,149` | `TaskExecutionDefaults` | `Astra/Services/Settings/AppearancePreference.swift` |
| `AgentTask.swift:173` | `AgentTaskForkService` | `Astra/Services/Tasks/AgentTaskForkService.swift` |
| `AgentTask.swift:218` | `TaskPresentationState` | `Astra/Services/Tasks/TaskPresentationState.swift` |
| `AgentTask.swift:139-140` | `ExecutionEnvironmentStore` | `Astra/Services/Runtime/ExecutionEnvironment.swift` |
| `Artifact.swift:69-71` | `TaskGeneratedFiles` | `Astra/Services/Tasks/TaskGeneratedFiles.swift` |
| `Connector.swift:174` | `ConnectorSecurityPolicy` | `Astra/Services/Runtime/SecurityPolicies.swift` |
| `Connector.swift:121,269,358` | `ConnectorHTTPTransport`, `URLSessionConnectorHTTPTransport` | `Astra/Services/Capabilities/JiraConnectorAuthTester.swift` |
| `Connector.swift:242,257` | `ConnectorRequestBuilder` | `Astra/Services/Capabilities/JiraConnectorAuthTester.swift` |
| `Connector.swift:77-112` | `ConnectorSecretPersistence` | `Astra/Services/Capabilities/ModelSecretPersistence.swift` |
| `Connector.swift:214` | `JiraConnectorAuthTester` | `Astra/Services/Capabilities/JiraConnectorAuthTester.swift` |
| `Connector.swift:139` | `StanfordOutlookMailGraphService` | `Astra/Services/Capabilities/StanfordOutlookMail.swift` |
| `Connector.swift:17,133-409 (17x)` | `AppLogger` | `Astra/Services/Diagnostics/Logger.swift` |
| `Skill.swift:199` | `ConnectorRuntimeProjection` | `Astra/Services/Capabilities/ConnectorRuntimeProjection.swift` |
| `Skill.swift:121-173` | `SkillSecretPersistence` | `Astra/Services/Capabilities/ModelSecretPersistence.swift` |
| `TaskRoleProfile.swift:57` | `AgentRuntimeAdapterRegistry` | `Astra/Services/Runtime/AgentRuntimeAdapter.swift` |
| `TaskRun.swift:153` | `WorkspaceExecutionEnvironment` | `Astra/Services/Runtime/ExecutionEnvironment.swift` |
| `TaskRun.swift:49-89` | `ExecutionEnvironmentStore`, `ExecutionEnvironmentPathMapper` | `Astra/Services/Runtime/ExecutionEnvironment.swift` |
| `TaskSchedule.swift:88-119` | `TaskExecutionDefaults` | `Astra/Services/Settings/AppearancePreference.swift` |
| `TaskTemplate.swift:65-67` | `TaskExecutionDefaults` | `Astra/Services/Settings/AppearancePreference.swift` |
| `WorkspaceAppDependencyBinding.swift:39-67` | `WorkspaceAppContractTransport` | `Astra/Services/WorkspaceApps/WorkspaceAppContractTransport.swift` |

The other 18 files (`Workspace.swift`, `WorkspaceApp.swift`, `TaskEvent.swift`,
`SchemaVersions.swift`, `GoogleOAuthAccountProfile.swift`, `LocalTool.swift`,
etc.) genuinely have zero external references — but see Finding 3 for why that
doesn't let them split off alone.

## Finding 2 — the `AgentTask` ↔ `Runtime` dependency is a real cycle, not a layering problem

This is the load-bearing finding. `Astra/Services/Runtime/ExecutionEnvironment.swift`
(1,513 lines; defines `WorkspaceExecutionEnvironment`, `ExecutionEnvironmentStore`,
`ExecutionEnvironmentPathMapper`) and `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
(2,849 lines; defines `AgentRuntimeAdapterRegistry`) both take `AgentTask` — a
`@Model` type defined only in `Astra/Models/AgentTask.swift` — as a function
parameter and stored property throughout (e.g.
`AgentRuntimeAdapter.swift:103,137-138,628,692-693` — `func defaultStartEventPayload(task: AgentTask)`,
`let task: AgentTask`, `let run: TaskRun`; `ExecutionEnvironment.swift:693,707,930,982` —
`static func resolveEnvironment(for task: AgentTask) -> WorkspaceExecutionEnvironment`).

So: `Models/AgentTask.swift` needs `Runtime/ExecutionEnvironment.swift`, and
`Runtime/ExecutionEnvironment.swift` needs `Models/AgentTask.swift`, in the
same direction of the same two files. A SwiftPM target graph is a DAG —
`ASTRAModels` cannot depend on a `Runtime`-containing target that itself
depends back on `ASTRAModels`. Untangling this requires real seam work
(e.g. an `AgentTaskExecutionFacts` protocol that `AgentTask` conforms to and
`Runtime` consumes instead of the concrete model type) across ~4,300 lines in
two of the largest files in the app. That is exactly the "more invasive,
protocol/interface-seamed" path the task brief says to avoid forcing into this
PR.

## Finding 3 — SwiftData relationships tie all 15 `@Model` types (and thus all 27 Models files) into one unit

`Astra/Models/SchemaVersions.swift` defines `ASTRASchemaV1`…`V11`
(`VersionedSchema` conformances enumerating every `@Model` type together) plus
`ASTRAMigrationPlan`. `Workspace.swift` (one of the 18 "clean" files) declares
`@Relationship` properties directly against several of the 9 "entangled" files
— `tasks: [AgentTask]` (`inverse: \AgentTask.workspace`), plus relationships to
`Skill`, `Connector`, `LocalTool`, `TaskTemplate`, `TaskSchedule`. So there is
no line to cut inside `Astra/Models/`: the relationship graph pulls the "clean"
18 files and the "entangled" 9 files together regardless of which files you'd
prefer to move. Practically, `Astra/Models/` is one all-or-nothing compilation
unit, and that unit inherits the Runtime cycle from Finding 2 and one-directional
dependencies on `Capabilities`, `Tasks`, `Settings`, and `WorkspaceApps` from
Finding 1.

**Blast radius if forced anyway:** `Runtime` (94 files) + `Capabilities` (69) +
`Tasks` (42) + `Settings` (19) + `WorkspaceApps` (72) = 296 additional files
would need to come along transitively — on top of the Runtime cycle that makes
it impossible outright without the seam work in Finding 2. That is most of the
non-View app (599 files total under `Astra/`), not a leaf target.

## Finding 4 — `Astra/Services/Persistence/` is at least as entangled

Grepped all ~650 type names from `Runtime`, `Capabilities`, `Tasks`, `Settings`,
`WorkspaceApps`, `Security`, `Validation`, `Packs` against all 40 Persistence
files (`Diagnostics`/`AppLogger` checked separately). Representative findings
(not exhaustive — the point is breadth, not a complete table):

- **`AppLogger`** (`Astra/Services/Diagnostics/Logger.swift`) — referenced in
  14 of 40 files: `KeychainService.swift` (11x), `ObjectiveAssessmentService.swift`
  (8x), `WorkspacePersistenceCoordinator.swift` (8x, its *only* external dep),
  `WorkspaceRecoveryService.swift` (15x), `WorkspaceConfigManager.swift` (3x),
  `WorkspaceImportOrchestrator.swift` (4x), plus `SSHConnectionManager.swift`,
  `StartupCredentialMigrationService.swift`, `TaskArtifactPersistenceService.swift`,
  `TaskContextStateManager.swift`, `TaskContextStateRecovery.swift`,
  `TaskWorkspaceAccess.swift`, `WorkspaceFileLayout.swift`, `TaskStoreMaintenance.swift`.
- **`Services/Runtime`** — `ObjectiveAssessmentService.swift` alone pulls in
  `AgentRuntimeAdapterRegistry`, `AgentRuntimeRunPersistence`, `AgentRuntimeWorker`,
  `AgentUtilityRunResult`, `AgentUtilityRuntimeConfiguration`,
  `AgentUtilityRuntimeRunner`, `CopilotCLIRuntime`, `RuntimeModelAvailability`,
  `RuntimePathResolver`; `WorkspaceConfigManager.swift` pulls in
  `ConnectorSecurityPolicy`, `ExecutionEnvironmentStore`, `ExecutionSandbox`,
  `LocalToolSecurityPolicy`; `TaskObjectiveAssessmentPivotReconciler.swift` pulls
  in `AgentRuntimeRunPersistence`.
- **`Services/Capabilities`** — `WorkspaceImportOrchestrator.swift` uses
  `CapabilityApprovalStore`, `CapabilityCatalogPolicyContext`,
  `CapabilityInstaller`, `PluginCatalog`; `WorkspaceCapabilities.swift` uses
  `CapabilityApprovalRecord`, `CapabilityRuntimeResourceMatcher`;
  `WorkspaceConfigManager.swift` uses `TaskCapabilitySnapshotter`.
- **`Services/Security`** — `HostFileAccessBroker` / `HostFileAccessIntent`
  used across 12 files: `SessionHistoryManager.swift`, `SessionScanner.swift`,
  `SSHConnectionManager.swift`, `TaskContextStateRecovery.swift`,
  `TaskContextStateOutputFiles.swift`, `TaskContextStateManager.swift`,
  `TaskOutputWorkspaceDiscovery.swift`, `WorkspaceFileLayout.swift`,
  `WorkspaceConfigManager.swift`, `WorkspaceFileIndexService.swift`,
  `WorkspaceImportDiscovery.swift`, `WorkspaceRecoveryService.swift`.
- **`Services/Settings`** — `AppChannel` used in `AstraSecureKeychainStore.swift`,
  `KeychainSecretStore.swift`, `KeychainService.swift`,
  `WorkspaceImportOrchestrator.swift`, `WorkspaceRecoveryService.swift`;
  `AppStorageKeys`/`TaskExecutionDefaults`/`RuntimeProviderSettingsStore` used in
  `ObjectiveAssessmentService.swift`, `TaskObjectiveAssessmentPivotReconciler.swift`,
  `SessionScanner.swift`.
- **`Services/Tasks`** — `TaskLifecycleCoordinator`, `TaskPlanService`,
  `TaskStateMachine`, `TaskQueue`, `TaskForkManifestService`,
  `TaskWorkerHandoffService`, and 8 more `Task*` types referenced across
  `ObjectiveAssessmentService.swift`, `TaskContextStateManager.swift`,
  `OriginalGoalDeliveryClassifier.swift`, `SessionScanner.swift`,
  `WorkspaceImportOrchestrator.swift`, `WorkspaceImportPanel.swift`,
  `TaskActiveObjectiveResolver.swift`, `WorkspaceFileIndexService.swift`,
  `TaskStoreMaintenance.swift`.
- **`Services/Validation`** — `TaskCorrectiveWorkService`, `TaskDeliverableCheck`,
  `TaskDeliverableVerificationService`, `ValidationCommandPolicy`,
  `ValidationOutcomeMarker` used in `TaskContextStateManager.swift`,
  `OriginalGoalDeliveryClassifier.swift`, `WorkspaceConfigManager.swift`.
- **No View-layer coupling found**: zero `import SwiftUI`/`import Combine`,
  zero `: View` conformances, zero `@State`/`@Binding`/`NSViewRepresentable` in
  any Persistence file. `AppKit` is used narrowly (pasteboard/keychain-adjacent
  APIs), not for UI. This part of the original hypothesis holds.

**Only a handful of files are actually clean**: `CapsuleSelectionPressure.swift`,
`KeychainCredentialPolicy.swift`, `ObjectiveAssessmentTrigger.swift`,
`RealFileSystem.swift`, `TaskArtifactPathNormalizer.swift`,
`TaskContextStateArtifactVisibility.swift`, `TaskObjectiveAssessment.swift`,
`WorkspaceGeneratedStateExcluder.swift`, `WorkspacePathPresentation.swift` — but
these are small, incidental files, not the subsystems this PR's task actually
named (`WorkspaceConfigManager`, `TaskContextStateManager`,
`WorkspacePersistenceCoordinator`, `WorkspaceRecoveryService` are all heavily
entangled). Extracting only the clean handful while leaving the real
subsystems behind would not be a meaningful win and was rejected per the task
brief's explicit guidance not to force a partial extraction that doesn't carry
real weight.

## Why physical file moves were also avoided

Even where a clean extraction *were* possible, `Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift`
(1,673 lines) asserts against dozens of hardcoded paths like
`"Astra/Services/Persistence/WorkspaceConfigManager.swift"` (line-budget
tests, CODEOWNERS checks, raw-save allowlists, stop-reason boundary checks —
see e.g. lines 198, 239, 295-296, 432-434, 632-963, 1242-1243, 1400,
1479-1484, 1529-1555). A `path:`/`exclude:`-based split — mirroring how
`ArchitectureFitnessTests` itself was extracted in commit `83d41bc` — would
have kept these paths stable, but doesn't change the underlying module-graph
conclusion above. No files were moved and no `Package.swift` target changes
were made in this PR, since there is nothing safe to extract yet.

## What would unblock this, in order

1. **Extract `Astra/Services/Diagnostics/Logger.swift` (`AppLogger`) as its own
   leaf target first.** It only imports `Foundation`/`os` and has zero
   back-dependency on Models or Persistence (confirmed). This alone would
   remove the single most common external dependency from both directions
   (9/27 Models files, 14/40 Persistence files touch `AppLogger`) and is a
   genuinely small, real, mechanical PR.
2. **Break the `AgentTask` ↔ `Runtime` cycle** (Finding 2) — introduce a
   protocol seam (e.g. `AgentTaskExecutionFacts`) that `Runtime` consumes
   instead of the concrete `AgentTask`/`TaskRun` types, so `Runtime` no longer
   needs to import Models. This is the load-bearing unblock for `ASTRAModels`
   and is inherently invasive (~4,300 lines across `ExecutionEnvironment.swift`
   + `AgentRuntimeAdapter.swift`) — its own dedicated PR with its own test plan.
3. **Only after (1) and (2)**, revisit whether `Astra/Models/` can depend on
   `ASTRACore` + the new Diagnostics leaf + the new Runtime-facing seam, and
   whether `Capabilities`/`Tasks`/`Settings`/`WorkspaceApps` references from
   Models (Finding 1) are removable or need their own seams.
4. **`Astra/Services/Persistence/` extraction should follow, not precede,
   Models**, since Persistence already depends on Models-adjacent types plus
   Runtime/Capabilities/Security/Settings/Tasks/Validation — it inherits every
   blocker above and adds its own (Security's `HostFileAccessBroker`,
   Capabilities' `PluginCatalog`/`CapabilityInstaller`, etc.).

## Verification for this PR

No `Package.swift` or source changes were made (investigation- and
documentation-only). Baseline build/test state was confirmed green before and
after adding this document:

```
swift build                              # Build complete! (~52s), zero errors
swift test --filter ArchitectureFitnessTests
swift test --filter WorkspacePersistenceTests
script/prepush.sh
```
