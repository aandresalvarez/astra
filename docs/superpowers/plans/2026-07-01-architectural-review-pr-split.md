# ASTRA Architectural Review PR Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the 2026-07-01 ASTRA architectural review into a sequence of focused pull requests that fix live defects first, then remove the root causes that let those defects reappear.

**Architecture:** Every pull request below has one durable owner boundary: task lifecycle, event recording, persistence, runtime policy, credential egress, WorkspaceApps execution, browser routing, or build/test governance. The plan avoids one mega-refactor by landing small correctness fixes first, adding tests around each invariant, and only then extracting shared abstractions where repeated code is already proven to be risky.

**Tech Stack:** SwiftPM macOS app, SwiftData, SwiftUI, Swift Testing, ASTRACore, existing ASTRA services under `Astra/Services`, repo guardrails in `script/precommit.sh`, `script/prepush.sh`, and `.github/workflows/ci.yml`.

---

## Source Review

Source: `ASTRA Architectural Review - 2026-07-01`

Baseline from review: `origin/main` at `39d91a7`.

The review found five repeated root causes:

1. Good owner patterns exist, but they are not propagated.
2. Important invariants are mirrored by comments instead of construction.
3. Shared mutable state has too many direct writers.
4. Slow compile/test feedback lets architectural drift survive.
5. Parallel derivations are hand-synchronized across policy, event, schema, and launch paths.

This split treats those as engineering constraints, not just findings. If a proposed PR only patches one symptom while preserving the duplicate owner or mirrored invariant, it is not complete.

## PR Ordering Rules

- Start each PR from current `main` unless intentionally stacking on a just-merged predecessor.
- Keep each branch narrow enough that the focused test named in the PR can fail before the implementation and pass after it.
- Run the focused test first, then the affected adjacent suite, then `git diff --check`.
- Run `script/precommit.sh` before every PR.
- Run `script/prepush.sh` before every PR that touches runtime, persistence, capabilities, WorkspaceApps, scripts, package metadata, or tests.
- Run full `swift test` before merging persistence, schema, Package.swift, process execution, or cross-runtime policy changes.
- If multiple PRs must be validated together, use a disposable integration-validation branch before proposing a rollup.

## Pull Request Index

| PR | Priority | Owner Boundary | Findings | Merge Before |
| --- | --- | --- | --- | --- |
| 1 | P0 | Task continuation admission | P0-1 | Any broad task state-machine work |
| 2 | P0 | Event recording correctness | P0-2, P0-3 | Event-pipeline convergence |
| 3 | P0 | ContentView browser session cache | P0-4 | Browser/session refactors |
| 4 | P0 | SwiftData schema freeze and recovery | P0-5 | Any model/schema changes |
| 5 | P0 | Workspace JSON mirror hygiene | P0-6 | Persistence write funnel |
| 6 | P1 | Runtime policy render as launch source | P1-7 | Credential egress and process executor work |
| 7 | P1 | Task status state machine | P1-8 status half | Typed continuation properties |
| 8 | P1 | Scene selection owner model | P1-8 selection half | Large ContentView edits |
| 9 | P1 | CI and test target feedback loop | P1-10 | Long refactor stack |
| 10 | P1 | Credential egress gate | P1-11 | Runtime process hardening |
| 11 | P1 | Typed continuation and approval state | P1-12 | Event-pipeline deletion |
| 12 | P1 | Utility launch sandboxing | P1-13 | HardenedProcessExecutor |
| 13 | P2 | SwiftPM target extraction phase 1 | P2-14 | Full module split |
| 14 | P2 | Shared chat transcript | P2-15 | App Studio chat feature work |
| 15 | P2 | Browser command handler registry | P2-16 | Browser bridge feature work |
| 16 | P2 | WorkspaceApps gate and read pipeline | P2-17 | WorkspaceApps approvals and reads |
| 17 | P2 | MCPServerKit | P2-18 | New MCP stdio server features |
| 18 | P2 | HardenedProcessExecutor | P2-19 | More process-spawn sites |
| 19 | P2 | Persistence write funnel | P2-20 | Mirror decoupling and schema work |
| 20 | P2 | Capability resolution snapshot | P2-21 | Runtime launch-policy rewrites |
| 21 | P2 | Policy vocabulary and runtime protocol cleanup | P2-22, P2-23 | Provider expansion |
| 22 | Hygiene | Dead code, docs, line budgets, source-text tests | Hygiene | Opportunistic after P0s |

---

## PR 1: Own Continuation Admission in `TaskQueue`

**Root cause:** The UI optimistically writes `task.status = .running`, then ignores whether `TaskQueue.continueSession` actually admitted the follow-up. The status transition and admission result have different owners.

**First-principles solution:** Make `TaskQueue.continueSession` the single boundary that moves a task into `.running` for continuation launch and reverts it if no worker or lock admission is available. UI and coordinator callers should ask for continuation, not pre-write lifecycle state.

**Scope:**

- Remove the optimistic status write from `Astra/Views/TaskMainView.swift`.
- Remove `@discardableResult` from `TaskQueue.continueSession` unless every production caller must explicitly consume the result.
- Move the launch/revert behavior currently split through `TaskLifecycleCoordinator.finishContinuationLaunch` into the continuation admission boundary, or expose one non-optional continuation lifecycle helper used by all callers.
- Preserve existing user-message recording behavior.

**Primary files:**

- `Astra/Services/Tasks/TaskQueue.swift`
- `Astra/Services/Tasks/TaskLifecycleCoordinator.swift`
- `Astra/Views/TaskMainView.swift`
- `Astra/Views/TaskThreadSnapshot.swift`

**Tests:**

- Extend `Tests/TaskLifecycleResumeTests.swift` so the most-used `TaskMainView`-style continuation path leaves the task non-running when a zero-size worker pool rejects admission.
- Extend `Tests/HeadlessChatContinuationScenarioTests.swift` or `Tests/HeadlessChatScenarioTests.swift` for the successful continuation path.
- Keep `Tests/TaskThreadSnapshotTests.swift` aligned with the new lifecycle owner.

**Validation:**

```bash
swift test --filter TaskLifecycleResumeTests
swift test --filter HeadlessChatContinuationScenarioTests
swift test --filter TaskThreadSnapshotTests
git diff --check
script/precommit.sh
```

## PR 2: Fix Follow-Up Usage and Transcript Recording

**Root cause:** Follow-up accounting and transcript finalization are implemented by parallel event recorders. Claude accumulates token deltas in one path, Codex ignores mode in another path, and Claude transcript output still keeps the first result rather than the last completed result.

**First-principles solution:** Make the existing recorders agree on follow-up semantics before the larger event-pipeline convergence. Follow-up mode must accumulate usage deltas, and completed transcript output must have one provider-neutral rule.

**Scope:**

- Fix `Astra/Services/Tasks/AgentEventRecorder.swift` so provider-agnostic usage recording honors follow-up mode.
- Fix Claude `.result` handling so final completed output is not permanently first-wins.
- Fix `Astra/Services/Runtime/CodexCLIRuntimeAdapter.swift` to pass meaningful recording mode through the adapter boundary.
- Add tests that fail on reset-to-delta and first-wins transcript behavior.

**Primary files:**

- `Astra/Services/Tasks/AgentEventRecorder.swift`
- `Astra/Services/Runtime/CodexCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `ASTRACore/AgentRuntimeEventPipeline.swift`

**Tests:**

- `Tests/AgentEventRecorderTests.swift`
- `Tests/CodexCLIRuntimeTests.swift`
- `Tests/HeadlessChatContinuationScenarioTests.swift`

**Validation:**

```bash
swift test --filter AgentEventRecorderTests
swift test --filter CodexCLIRuntimeTests
swift test --filter HeadlessChatContinuationScenarioTests
git diff --check
script/precommit.sh
```

## PR 3: Cache ContentView Browser Policy Inputs

**Root cause:** `ContentView.currentBrowserSession` performs policy, approval-store, package-definition, and event-scan work during body evaluation. That repeats disk IO and event walks whenever unrelated view state changes.

**First-principles solution:** Treat browser policy context as derived presentation state with an explicit signature and refresh path. The body should read a cached value keyed by task ID plus capability/policy revision, not compute filesystem-backed policy on demand.

**Scope:**

- Introduce a focused browser-session policy cache value near existing ContentView cache patterns.
- Key the cache on selected task ID, capability approval revision, package-definition fingerprint, and the latest relevant task-event revision.
- Keep the cache invalidation explicit in `ContentView` observers or a tiny helper type; do not hide state changes in view-body computed properties.
- Preserve the existing fail-closed browser policy result when the cache cannot refresh.

**Primary files:**

- `Astra/Views/ContentView.swift`
- `Astra/Views/ContentViewObservers.swift`
- `Astra/Services/Capabilities/CapabilityRuntimeResourceMatcher.swift`
- `Astra/Services/Capabilities/CapabilityApprovalStore.swift`
- `Astra/Services/Browser/ShelfBrowserSession.swift`

**Tests:**

- Add or extend `Tests/WorkspaceRightRailPerformanceTests.swift` with a fake approval store/resource matcher that proves repeated body-like reads do not hit disk after the signature is stable.
- Add a focused unit test for the new cache signature if it lives outside `ContentView`.

**Validation:**

```bash
swift test --filter WorkspaceRightRailPerformanceTests
swift test --filter BrowserBenchmarkTests
git diff --check
script/precommit.sh
```

## PR 4: Freeze Historic Schemas and Add Store-Recovery Safety Nets

**Root cause:** Historic SwiftData schemas reference live model classes. A future field edit can mutate the declared shape of older schemas, cause container initialization failure, and push recovery into move-aside-and-empty behavior.

**First-principles solution:** Historic schemas must be immutable by construction, and recovery must attempt data-preserving export before destructive fallback.

**Scope:**

- Add an `ArchitectureFitnessTests` rule: no non-latest `VersionedSchema` may reference a model type declared outside `Astra/Models/SchemaVersions.swift`.
- Add an export/import round-trip fixture containing WorkspaceApps, OAuth profiles, fork metadata, schedule origin, execution root path, queue position, task runs, and representative events.
- Extend the workspace mirror or per-app manifests so WorkspaceApp family and OAuth profile state are not lost during recovery.
- Change container failure recovery to try a read-only open plus fresh export before moving the store aside.

**Primary files:**

- `Astra/Models/SchemaVersions.swift`
- `Astra/ASTRAApp.swift`
- `Astra/Services/Persistence/WorkspaceRecoveryService.swift`
- `Astra/Services/Persistence/WorkspaceConfigManager.swift`
- `Astra/Models/WorkspaceApp.swift`
- `Astra/Models/GoogleOAuthAccountProfile.swift`

**Tests:**

- `Tests/ArchitectureFitnessTests.swift`
- `Tests/SchemaVersionTests.swift`
- `Tests/WorkspaceStoreRepairTests.swift`
- `Tests/WorkspacePersistenceTests.swift`
- `Tests/WorkspaceAppStorageTests.swift`

**Validation:**

```bash
swift test --filter ArchitectureFitnessTests
swift test --filter SchemaVersionTests
swift test --filter WorkspaceStoreRepairTests
swift test --filter WorkspacePersistenceTests
swift test --filter WorkspaceAppStorageTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 5: Bound and Relocate the Workspace JSON Mirror

**Root cause:** The workspace mirror serializes all runs, full output, and all events synchronously to `.astra-workspace.json` at the workspace root. It is expensive on every save and easy to commit accidentally.

**First-principles solution:** The mirror is a recovery/export surface, not the primary durable store. It should be bounded, excluded, and stored under ASTRA-owned workspace metadata.

**Scope:**

- Move the generated mirror from workspace root to `.astra/` while preserving import of legacy `.astra-workspace.json`.
- Cap mirrored runs, events, and output length with deterministic truncation markers.
- Add `.gitignore` or `.git/info/exclude` management for generated ASTRA state.
- Keep user-authored workspace config files importable.
- Add migration/read compatibility tests.

**Primary files:**

- `Astra/Services/Persistence/WorkspaceConfigManager.swift`
- `Astra/Services/Persistence/WorkspaceFileLayout.swift`
- `Astra/Services/Persistence/WorkspaceImportOrchestrator.swift`
- `Astra/Services/Persistence/TaskContextStateManager.swift`

**Tests:**

- `Tests/WorkspacePersistenceTests.swift`
- `Tests/WorkspaceImportDiscoveryTests.swift`
- `Tests/TaskContextStateTests.swift`
- `Tests/DataIntegrityTests.swift`

**Validation:**

```bash
swift test --filter WorkspacePersistenceTests
swift test --filter WorkspaceImportDiscoveryTests
swift test --filter TaskContextStateTests
swift test --filter DataIntegrityTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 6: Derive Launch Arguments from `ProviderPolicyRender`

**Root cause:** Provider policy is rendered, validated, and then separately translated into actual process arguments. The persisted manifest can agree with policy while the launch plan was assembled by a parallel path.

**First-principles solution:** `ProviderPolicyRender` must be the single source used by runtime launch assembly. Provider-specific argument helpers may exist only behind the render step or as render-owned helpers.

**Scope:**

- Move provider permission argument construction behind the provider render value.
- Remove or narrow direct calls to `*PermissionArguments` from launch plan builders.
- Add a fitness or runtime contract test that persisted launch manifest render and actual launch plan policy flags are equivalent.
- Preserve provider-specific ask/allow/deny behavior, including Claude ask-first withholding.

**Primary files:**

- `ASTRACore/AgentPolicyTypes.swift`
- `Astra/Services/Runtime/AgentPolicyAdapters.swift`
- `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- `Astra/Services/Runtime/AgentRuntimeExecutionPolicy.swift`
- `Astra/Services/Runtime/CodexCLIRuntime.swift`
- `Astra/Services/Runtime/CopilotCLIRuntime.swift`
- `Astra/Services/Runtime/CursorCLIRuntime.swift`
- `Astra/Services/Runtime/AntigravityCLIRuntime.swift`

**Tests:**

- `Tests/AgentPolicyTests.swift`
- `Tests/AgentRuntimeAdapterTests.swift`
- `Tests/AgentRuntimeExecutionPolicyTests.swift`
- `Tests/CodexCLIRuntimeTests.swift`
- `Tests/CopilotRuntimeTests.swift`
- `Tests/CursorCLIRuntimeTests.swift`
- `Tests/CapabilityCoverageGapTests.swift`

**Validation:**

```bash
swift test --filter AgentPolicyTests
swift test --filter AgentRuntimeAdapterTests
swift test --filter AgentRuntimeExecutionPolicyTests
swift test --filter CodexCLIRuntimeTests
swift test --filter CopilotRuntimeTests
swift test --filter CursorCLIRuntimeTests
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 7: Introduce `TaskStateMachine`

**Root cause:** `task.status` has many direct writers across UI, runtime, queue, validation, and recovery layers. Each writer carries local heuristics instead of one transition contract.

**First-principles solution:** Introduce one transition boundary that validates legal status changes, records audit events, and performs save coordination. Direct writes should become test failures outside allowed model initialization or migration code.

**Scope:**

- Add `Astra/Services/Tasks/TaskStateMachine.swift`.
- Route queue admission, completion, cancellation, validation, and recovery transitions through intent methods.
- Add a fitness test that forbids raw `task.status =` outside the state-machine boundary, model constructors, tests, and migrations.
- Migrate call sites in small batches inside this PR only if focused tests can stay clear; otherwise split migration into follow-up PRs by subsystem after the boundary lands.

**Primary files:**

- `Astra/Models/AgentTask.swift`
- `Astra/Services/Tasks/TaskQueue.swift`
- `Astra/Services/Tasks/TaskLifecycleCoordinator.swift`
- `Astra/Services/Tasks/TaskRunLifecycleService.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Services/Validation/*`
- `Astra/Views/TaskMainView.swift`
- `Astra/Views/TaskSidebarView.swift`

**Tests:**

- New `Tests/TaskStateMachineTests.swift`
- `Tests/TaskRunLifecycleServiceTests.swift`
- `Tests/QueueLockTests.swift`
- `Tests/TaskRuntimeHealthTests.swift`
- `Tests/ArchitectureFitnessTests.swift`

**Validation:**

```bash
swift test --filter TaskStateMachineTests
swift test --filter TaskRunLifecycleServiceTests
swift test --filter QueueLockTests
swift test --filter TaskRuntimeHealthTests
swift test --filter ArchitectureFitnessTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 8: Introduce `SceneSelectionModel`

**Root cause:** Scene selection is maintained by a hand-synchronized quintuple of optional UI state. Multiple places can open a task, workspace, app, compose sheet, or clear selection by writing different subsets.

**First-principles solution:** Apply the `SidebarPresentationModel` pattern: one presentation model exposes intent methods, owns invariants, and uses pure coordinators from `ContentSceneState`.

**Scope:**

- Add `Astra/Views/SceneSelectionModel.swift` or extend `ContentSceneState` with a stateful owner.
- Replace scattered selection writes in `ContentView` with intent methods: `openTask`, `openWorkspace`, `openApp`, `composeTask`, `composeApp`, and `clear`.
- Keep pure routing and restoration logic in `ContentSceneState`.
- Add tests that conflicting intents leave exactly one selected scene.

**Primary files:**

- `Astra/Views/ContentView.swift`
- `Astra/Views/ContentSceneState.swift`
- `Astra/Views/SidebarPresentationModel.swift`
- `Astra/Views/TaskSidebarView.swift`
- `Astra/Views/WorkspaceAppDetailView.swift`

**Tests:**

- New `Tests/SceneSelectionModelTests.swift`
- `Tests/SidebarPresentationModelTests.swift`
- `Tests/SidebarSurfaceTests.swift`
- `Tests/SidebarWorkspaceAppFilterTests.swift`

**Validation:**

```bash
swift test --filter SceneSelectionModelTests
swift test --filter SidebarPresentationModelTests
swift test --filter SidebarSurfaceTests
swift test --filter SidebarWorkspaceAppFilterTests
git diff --check
script/precommit.sh
```

## PR 9: Fix CI and Test Target Feedback Loops

**Root cause:** CI and precommit compile a large app and flat test target while running only a small focused filter. Some dedicated test targets compile but are not matched by the focused filter.

**First-principles solution:** Make feedback proportional to the changed boundary. Keep focused PR checks fast, add a cached full-suite signal, and move file-reading architecture tests into a tiny target that does not compile the whole app.

**Scope:**

- Add SwiftPM build cache to GitHub Actions.
- Add a scheduled or explicit full `swift test` job.
- Ensure `MCPGatewaySupportTests` and `MailToolSupportTests` are included by focused guardrails when relevant.
- Split `ArchitectureFitnessTests` into a standalone file-reading target if feasible in one PR; otherwise land the CI/cache/filter fixes first and split the target in PR 13.
- Replace hand-picked filters with changed-path-aware selection where stable.

**Primary files:**

- `.github/workflows/ci.yml`
- `Package.swift`
- `script/precommit.sh`
- `script/prepush.sh`
- `Tests/ArchitectureFitnessTests.swift`
- `Tests/MCPGatewaySupportTests/RemoteMCPGatewaySupportTests.swift`
- `Tests/MailToolSupportTests/StanfordAppleMailToolTests.swift`

**Tests:**

- Add script-level smoke checks if helper scripts are introduced.
- Exercise `script/precommit.sh` and `script/prepush.sh` locally.

**Validation:**

```bash
script/precommit.sh
script/prepush.sh
swift test --target MCPGatewaySupportTests
swift test --target MailToolSupportTests
git diff --check
```

## PR 10: Gate Credential Egress

**Root cause:** Credential storage is isolated, but runtime projection injects broad connector secrets into provider environments while network egress is generally available. The `.credential` permission request path exists but grants nothing.

**First-principles solution:** Secrets should leave the host only through an explicit, auditable capability path. Prefer host-side injection or first-use asks over ambient environment variables.

**Scope:**

- Scope environment injection in `ConnectorRuntimeProjection` to the pruned capability set.
- Add per-credential-label first-use ask plumbing through `PermissionBroker` and runtime permission actions.
- Keep a minimal compatibility path for non-HTTP connectors while labeling every exposed credential.
- Consider a host-side HTTP header-injection proxy as the follow-up design if direct env projection remains too broad.

**Primary files:**

- `Astra/Services/Capabilities/ConnectorRuntimeProjection.swift`
- `Astra/Services/Runtime/PermissionBroker.swift`
- `Astra/Services/Runtime/TaskRuntimePermissionActionHandler.swift`
- `Astra/Services/Runtime/TaskRuntimePermissionGrants.swift`
- `Astra/Services/Runtime/AgentRuntimeProcessLaunchPlan+Credentials.swift`
- `Astra/Services/Persistence/KeychainCredentialPolicy.swift`

**Tests:**

- `Tests/CapabilityProjectionRobustnessTests.swift`
- `Tests/ConnectorPreflightServiceTests.swift`
- `Tests/TaskRuntimePermissionActionHandlerTests.swift`
- `Tests/AstraSecureKeychainTests.swift`
- `Tests/SettingsViewPrivacyTests.swift`

**Validation:**

```bash
swift test --filter CapabilityProjectionRobustnessTests
swift test --filter ConnectorPreflightServiceTests
swift test --filter TaskRuntimePermissionActionHandlerTests
swift test --filter AstraSecureKeychainTests
swift test --filter SettingsViewPrivacyTests
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 11: Promote Continuation and Approval State to Typed Properties

**Root cause:** Resume, open-ask, and approval-grant state is recovered by scanning task events, decoding JSON payloads, and in one case matching regex over payload strings. Durable decisions depend on incidental audit text shape.

**First-principles solution:** Put workflow state on `TaskRun` or `AgentTask`; keep events as an audit trail only. Runtime decisions should read typed properties, not reconstruct state from every event.

**Scope:**

- Add typed fields or sidecar value objects for provider launch signature, open approval request, and approved grants.
- Migrate writes from event-only storage to typed storage plus audit event.
- Add compatibility readers for existing event-backed tasks.
- Remove regex-based approval grant recovery after compatibility is covered.

**Primary files:**

- `Astra/Models/AgentTask.swift`
- `Astra/Models/TaskRun.swift`
- `Astra/Models/SchemaVersions.swift`
- `Astra/Services/Tasks/TaskLifecycleCoordinator.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Services/Runtime/AgentInteractivePermissionChannel.swift`
- `Astra/Services/Runtime/TaskLaunchResourceManifestStore.swift`

**Tests:**

- `Tests/SessionResumeTests.swift`
- `Tests/HeadlessChatLiveApprovalScenarioTests.swift`
- `Tests/HeadlessChatPermissionScenarioTests.swift`
- `Tests/TaskThreadConversationSnapshotTests.swift`
- `Tests/SchemaVersionTests.swift`

**Validation:**

```bash
swift test --filter SessionResumeTests
swift test --filter HeadlessChatLiveApprovalScenarioTests
swift test --filter HeadlessChatPermissionScenarioTests
swift test --filter TaskThreadConversationSnapshotTests
swift test --filter SchemaVersionTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 12: Run Utility Prompts Through a Sandboxed Launch Plan

**Root cause:** Runtime utility prompts use raw `Process` spawn paths in multiple adapters. The verifier can execute with weaker confinement than the run it judges.

**First-principles solution:** Utility prompts are runtime processes with different recording semantics, not a separate execution class. They should use the same sandbox, timeout, output caps, and diagnostics as normal runs.

**Scope:**

- Add `UtilityLaunchPlan` as a slim process-launch value.
- Route adapter `runUtilityPrompt` implementations through `AgentRuntimeProcessRunner` or a shared wrapper with recording disabled.
- Preserve existing utility-prompt output format and failure diagnostics.
- Add tests proving sandbox/readable-path constraints apply to utility prompts.

**Primary files:**

- `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- `Astra/Services/Runtime/CodexCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/CursorCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/OpenCodeCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`
- `Astra/Services/Runtime/AgentUtilityRuntime.swift`

**Tests:**

- `Tests/AgentUtilityRuntimeTests.swift`
- `Tests/ExecutionSandboxRunnerTests.swift`
- `Tests/ExecutionSandboxTests.swift`
- `Tests/AgentRuntimeAdapterTests.swift`

**Validation:**

```bash
swift test --filter AgentUtilityRuntimeTests
swift test --filter ExecutionSandboxRunnerTests
swift test --filter ExecutionSandboxTests
swift test --filter AgentRuntimeAdapterTests
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 13: Extract First SwiftPM Leaf Targets

**Root cause:** Folder boundaries are policed by tests but not enforced by the compiler. Most service code imports no UI, yet the app target and flat test target still pay whole-app compile costs.

**First-principles solution:** Move stable, UI-free contracts and services into leaf targets in dependency order. Start with models/contracts or persistence helpers that already have low UI coupling.

**Scope:**

- Choose the smallest first extraction: models/contracts plus file-reading architecture tests, or persistence contracts if model extraction is too disruptive.
- Update `Package.swift` target dependencies without moving unrelated code.
- Move matching tests into target-specific test targets when it reduces compile scope.
- Keep imports explicit and avoid cycles.

**Primary files:**

- `Package.swift`
- `Astra/Models/*`
- `Astra/Services/Persistence/*`
- `ASTRACore/*`
- `Tests/ArchitectureFitnessTests.swift`
- New target-specific test folders as needed.

**Tests:**

- Existing tests for moved files must move with them or remain passing in `ASTRATests`.
- `Tests/ArchitectureFitnessTests.swift`
- `Tests/SchemaVersionTests.swift`
- `Tests/WorkspacePersistenceTests.swift`

**Validation:**

```bash
swift test --filter ArchitectureFitnessTests
swift test --filter SchemaVersionTests
swift test --filter WorkspacePersistenceTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 14: Extract a Shared Chat Transcript Component

**Root cause:** Task chat, App Studio chat, and related transcript surfaces reimplement message rendering, paste handling, provider settings snapshots, and streaming behavior with drift.

**First-principles solution:** Chat transcript rendering should be a shared presentation component over a small message protocol. Domain-specific sessions can own data, but rendering and attachment intake should not fork.

**Scope:**

- Add shared `ChatTranscriptRole`, `ChatTranscriptUserBubble`, and `ChatTranscriptCompactBubble` presentation primitives.
- Extract duplicate `smartPaste` text/file/image intake into `ComposerPasteIntake`.
- Keep task-specific and App Studio-specific session ownership outside the shared view.
- Preserve markdown rendering and streaming where task chat already supports it.

**Primary files:**

- `Astra/Views/ChatPanelView.swift`
- `Astra/Views/WorkspaceAppStudioChatView.swift`
- `Astra/Views/TaskThreadSnapshot.swift`
- `Astra/Views/TaskMainView.swift`
- New `Astra/Views/Components/ChatTranscriptView.swift`
- New `Astra/Services/Tasks/ComposerPasteIntake.swift`

**Tests:**

- `Tests/ComposerPresentationTests.swift`
- `Tests/WorkspaceAppStudioSessionTests.swift`
- `Tests/WorkspaceAppStudioUXTests.swift`
- `Tests/HeadlessChatScenarioTests.swift`

**Validation:**

```bash
swift test --filter ComposerPresentationTests
swift test --filter WorkspaceAppStudioSessionTests
swift test --filter WorkspaceAppStudioUXTests
swift test --filter HeadlessChatScenarioTests
git diff --check
script/precommit.sh
```

**Implementation evidence (2026-07-02):**

- Added `ChatTranscriptUserBubble` for ChatPanel and TaskMain user messages, preserving ChatPanel copy/reuse context actions and TaskMain markdown text.
- Added `ChatTranscriptCompactBubble` for App Studio chat rows while leaving Studio session state and scroll sentinels local.
- Added `ComposerPasteIntake` and routed ChatPanel/TaskMain paste monitors through it; long text attaches as `.txt` or `.json`, short text still falls through to native text paste.
- Validation passed: `swift test --filter ComposerPresentationTests`; `swift test --filter 'TaskPresentationModelTests|TaskThreadConversationSnapshotTests|WorkspaceAppStudioSessionTests|WorkspaceAppStudioUXTests|HeadlessChatScenarioTests'`; `git diff --check`; `script/precommit.sh`; `script/prepush.sh`.

## PR 15: Replace Browser Command Switches with a Handler Registry

**Root cause:** `ShelfBrowserSession` carries several mirrored command interpreters over the same browser command surface. Adding or changing one command requires updating multiple switches and lists.

**First-principles solution:** Browser bridge commands should register once with a route handler that can support direct action and batch execution. Engine differences should be hidden behind a protocol.

**Scope:**

- Define a per-route handler protocol around existing `ShelfBrowserBridgeCommandRouter`/registry pieces.
- Move one cluster of commands first, then migrate the remaining command cases in the same PR only if tests stay readable.
- Promote the embedded-vs-controlled browser engine descriptor to a protocol for the command handlers.
- Move Google Docs/Drive orchestration behind the existing site-adapter seam if it is already naturally separable.

**Primary files:**

- `Astra/Services/Browser/ShelfBrowserSession.swift`
- `Astra/Services/Browser/ShelfBrowserBridgeCommandRouter.swift`
- `Astra/Services/Browser/ShelfBrowserBridgeCommands.swift`
- `Astra/Services/Browser/ShelfBrowserBridgeRegistry.swift`
- `Astra/Services/Browser/BrowserAutomationEngine.swift`
- `Astra/Services/Browser/BrowserSiteAdapters.swift`

**Tests:**

- `Tests/BrowserAutomationEngineTests.swift`
- `Tests/BrowserBridgeSecurityTests.swift`
- `Tests/BrowserControlActionServiceTests.swift`
- `Tests/BrowserMCPServerTests.swift`

**Validation:**

```bash
swift test --filter BrowserAutomationEngineTests
swift test --filter BrowserBridgeSecurityTests
swift test --filter BrowserControlActionServiceTests
swift test --filter BrowserMCPServerTests
git diff --check
script/precommit.sh
script/prepush.sh
```

**Implementation evidence (2026-07-02):**

- Added `ShelfBrowserBridgeCommandSpec` as the single route catalog for method/path lookup, published `/actions` metadata, and batch aliases.
- Routed GitHub read-only batch policy and `ShelfBrowserSession.runBatch` through `ShelfBrowserBridgeCommandRouter.route(batchAction:)`, removing mirrored alias switches from those surfaces.
- Added `BrowserAutomationEngineDescribing` plus `ShelfBrowserBridgeVerificationCommandHandler` and moved the `verifyText`, `waitSaved`, `waitForText`, and `waitForSelector` direct/batch cluster behind it.
- Added `BrowserBridgeSecurityTests` coverage for route-spec ownership, batch alias policy coverage, and direct/batch verification handler execution.
- Validation passed: `swift test --filter BrowserBridgeSecurityTests`; `swift test --filter BrowserAutomationEngineTests`; `swift test --filter BrowserControlActionServiceTests`; `swift test --filter BrowserMCPServerTests`; `git diff --check`; `script/precommit.sh`; `script/prepush.sh`.

## PR 16: Single-Source WorkspaceApps Permission Gate and Read Pipeline

**Root cause:** WorkspaceApps permission enforcement and capability-read execution are mirrored across executor async, executor sync, preview, and view wiring. A security-relevant rate limiter already had to be patched because one mirror missed it.

**First-principles solution:** Permission and read execution should be services with typed bridge-surface inputs. Preview, published, sync, and async paths should call the same gate and pipeline.

**Scope:**

- Add `WorkspaceAppPermissionGate`.
- Add `WorkspaceAppCapabilityReadPipeline`.
- Add a `BridgeSurface` enum for preview, published, and executor contexts.
- Centralize read caps in `WorkspaceAppReadPolicy`.
- Include the approval-resume bound-rows rule: if human approval suspends after rows are bound, `resumeWithApproval` must restore those rows before later write/export steps.

**Primary files:**

- `Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPreviewRunner.swift`
- `Astra/Views/WorkspaceAppPreviewView.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppConnectorReadRateLimiter.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppCapabilityReadExecution.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppApprovalResumeContext.swift`

**Tests:**

- `Tests/WorkspaceAppActionExecutorTests.swift`
- `Tests/WorkspaceAppDataBridgeTests.swift`
- `Tests/WorkspaceAppGenericCapabilityReadTests.swift`
- `Tests/WorkspaceAppPreviewRunnerTests.swift`
- `Tests/WorkspaceAppPermissionCoverageTests.swift`
- `Tests/WorkspaceAppWorkflowBindingTests.swift`

**Validation:**

```bash
swift test --filter WorkspaceAppActionExecutorTests
swift test --filter WorkspaceAppDataBridgeTests
swift test --filter WorkspaceAppGenericCapabilityReadTests
swift test --filter WorkspaceAppPreviewRunnerTests
swift test --filter WorkspaceAppPermissionCoverageTests
swift test --filter WorkspaceAppWorkflowBindingTests
git diff --check
script/precommit.sh
script/prepush.sh
```

**Implementation evidence (2026-07-02):**

- Added `WorkspaceAppBridgeSurface`, `WorkspaceAppPermissionGate`, `WorkspaceAppReadPolicy`, and `WorkspaceAppCapabilityReadPipeline` as small service owners for surface context, permission enforcement, connector-read limits, rate admission, source normalization, sync/async resolution, and audit payload construction.
- Routed `WorkspaceAppActionExecutor` sync and async `capability.read` paths through the shared pipeline while preserving the async rule that rate-limited reads are rejected before a run row is created.
- Routed `WorkspaceAppPreviewRunner` top-level and nested composite permission checks through `WorkspaceAppPermissionGate` with `.preview` surface context.
- Routed live App Studio preview reads through `WorkspaceAppCapabilityReadPipeline` and marked published WebView reads with `.published` when they enter `WorkspaceAppActionExecutor.executeAsync`.
- Moved bridge connector-read limits behind `WorkspaceAppReadPolicy.connectorLimit(_:)`; `WorkspaceAppDataBridge` now aliases those policy constants instead of owning its own cap math.
- Kept the approval-resume bound-rows rule in `WorkspaceAppApprovalResumeContext`; `WorkspaceAppActionExecutorTests.approvalResumePreservesBoundRowsFromAsyncTaskOutput` remains green.
- Added regression coverage for preview permission-gate delegation and read-pipeline-owned rate admission/source normalization.
- Validation passed: `swift test --filter WorkspaceAppActionExecutorTests`; `swift test --filter WorkspaceAppDataBridgeTests`; `swift test --filter WorkspaceAppGenericCapabilityReadTests`; `swift test --filter WorkspaceAppPreviewRunnerTests`; `swift test --filter WorkspaceAppPermissionCoverageTests`; `swift test --filter WorkspaceAppWorkflowBindingTests`; extra `swift test --filter WorkspaceAppConnectorReadTests`; `git diff --check`; `script/precommit.sh`; `script/prepush.sh`.

## PR 17: Add `MCPServerKit` for Stdio Server Boundaries

**Root cause:** Workspace, host-control, gateway, and browser MCP servers hand-roll JSON-RPC framing, envelope handling, dispatch, and diagnostics. Protocol fixes must be copied into every server.

**First-principles solution:** Stdio JSON-RPC server mechanics should live in one support module. Individual servers should provide typed tool definitions and handlers only.

**Scope:**

- Add a small shared `MCPServerKit` target or support folder.
- Extract framing, request/response envelope, JSON-RPC error formatting, dispatch, and diagnostics.
- Migrate one server first, then migrate the others once shared tests are green.
- Keep tool-specific policies in their current support targets.

**Primary files:**

- `Package.swift`
- `Tools/WorkspaceToolSupport/*`
- `Tools/HostControlToolSupport/*`
- `Tools/MCPGatewaySupport/*`
- `ASTRACore/BrowserMCPServer.swift`
- New `Tools/MCPServerKit/*` or `ASTRACore/MCPServerKit/*`

**Tests:**

- New `Tests/MCPServerKitTests.swift` or target-specific equivalent.
- `Tests/WorkspaceToolSupportTests.swift`
- `Tests/HostControlToolSupportTests.swift`
- `Tests/MCPGatewaySupportTests/RemoteMCPGatewaySupportTests.swift`
- `Tests/BrowserMCPServerTests.swift`

**Validation:**

```bash
swift test --filter MCPServerKitTests
swift test --filter WorkspaceToolSupportTests
swift test --filter HostControlToolSupportTests
swift test --filter MCPGatewaySupportTests
swift test --filter BrowserMCPServerTests
git diff --check
script/precommit.sh
script/prepush.sh
```

**Implementation evidence (2026-07-02):**

- Added `MCPServerKit` as a small SwiftPM support target owning JSON-RPC line parsing, initialize/tools-list/tools-call dispatch, shared result/error envelope encoding, id normalization, notification suppression, and protocol diagnostics.
- Migrated `WorkspaceMCPServer.handleLine(_:)` to delegate protocol mechanics to `MCPServerKit.MCPServer`; Workspace now provides only tool schemas and typed tool-call handling for `workspace_shell` and durable job tools.
- Removed Workspace's local `encodeResult`, `encodeError`, `normalizedID`, and raw method switch, reducing duplicated protocol mechanics without moving Workspace command/job policy out of `WorkspaceToolSupport`.
- Added `Tests/MCPServerKitTests.swift` with red-green coverage proving the kit owns protocol flow, errors, id behavior, notifications, diagnostics, and tool delegation.
- Validation passed: `swift test --filter MCPServerKitTests`; `swift test --filter WorkspaceToolSupportTests`; `swift test --filter HostControlToolSupportTests`; `swift test --filter RemoteMCPGatewaySupportTests`; `swift test --filter MCPGatewaySupportTests`; `swift test --filter BrowserMCPServerTests`; `git diff --check`; `script/precommit.sh`; `script/prepush.sh`.
- Note: `swift test --target MCPGatewaySupportTests` failed because this SwiftPM CLI does not support `--target`; the equivalent supported selector is `swift test --filter MCPGatewaySupportTests`.

## PR 18: Add a Shared `HardenedProcessExecutor`

**Root cause:** ASTRA has several process-spawn stacks, each with its own timeout, kill, output-cap, environment, and read-only behavior. Security and cancellation fixes have to be repeated.

**First-principles solution:** Process execution should be an explicit capability. Read-only, workspace shell, host-control, mail, and runtime utility execution should share the same hardened mechanics with policy-specific launch values.

**Scope:**

- Add `HardenedProcessExecutor` with timeout, process-group kill, bounded output, environment filtering, and diagnostics.
- Migrate one non-runtime caller first, then runtime utility prompts if PR 12 has landed.
- Preserve special host-control and mail behavior through typed options rather than parallel executors.

**Primary files:**

- `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppGenericCLIReadClient.swift`
- `Tools/HostControlToolSupport/*`
- `Tools/MailToolSupport/*`
- `ASTRACore/BinaryRunner.swift`

**Tests:**

- `Tests/ProcessMonitorTests.swift`
- `Tests/AgentExecutionScopedProcessTests.swift`
- `Tests/WorkspaceAppGenericCapabilityReadTests.swift`
- `Tests/HostControlToolSupportTests.swift`
- `Tests/MailToolSupportTests/StanfordAppleMailToolTests.swift`

**Validation:**

```bash
swift test --filter ProcessMonitorTests
swift test --filter AgentExecutionScopedProcessTests
swift test --filter WorkspaceAppGenericCapabilityReadTests
swift test --filter HostControlToolSupportTests
swift test --filter MailToolSupportTests
git diff --check
script/precommit.sh
script/prepush.sh
```

**Implementation evidence:**

- Added `ASTRACore/HardenedProcessExecutor.swift` with a typed `HardenedProcessRequest` for executable, argv, stdin, timeout, explicit environment, current directory, output byte cap, and process-group termination policy.
- Extended `ProcessBinaryRunner`/`RunResult` so shared process execution can report stdout/stderr truncation, enforce bounded collectors, and optionally terminate a best-effort child process group through the same timeout/cancellation path.
- Migrated `WorkspaceAppHardenedCLIRunner` away from its private `Process`/`CLIOutputBox` implementation; it now supplies workspace read policy values and delegates launch mechanics to `HardenedProcessExecutor`.
- Migrated `Tools/MailToolSupport.runProcess` away from its private `LockedDataBuffer`/`Process` implementation while preserving PATH lookup, stdin, timeout errors, stdout/stderr, and exit-code behavior.
- Added regression coverage in `Tests/BinaryRunnerTests.swift`, `Tests/WorkspaceAppGenericCapabilityReadTests.swift`, and `Tests/MailToolSupportTests/StanfordAppleMailToolTests.swift` proving the shared executor path owns output caps and the migrated callers no longer carry private process runners.
- Validation passed: `swift test --filter ProcessBinaryRunnerTests`; `swift test --filter WorkspaceAppGenericCapabilityReadTests`; `swift test --filter MailToolSupportTests`; `swift test --filter ProcessMonitorTests`; `swift test --filter AgentExecutionScopedProcessTests`; `swift test --filter HostControlToolSupportTests`; `git diff --check`; `script/precommit.sh`; `script/prepush.sh`.

## PR 19: Funnel SwiftData Saves Through Persistence Boundaries

**Root cause:** Raw `modelContext.save()` calls bypass the coordinator and therefore bypass mirror/update side effects. Persistence behavior depends on which layer happened to save.

**First-principles solution:** SwiftData writes should go through service boundaries that own save, mirror update, error handling, and test seams. If mirror updates move to save notifications, that subscription belongs in persistence.

**Scope:**

- Add a fitness test that forbids raw `modelContext.save()` outside persistence, migrations, and explicitly allow-listed services.
- Move high-risk call sites first: WorkspaceApps executor, ContentView, TaskMainView, launch preflight, and interactive permission channel.
- Decide whether `WorkspacePersistenceCoordinator` remains explicit save boundary or whether the mirror subscribes to save notifications.
- Preserve model-context actor constraints.

**Primary files:**

- `Astra/Services/Persistence/WorkspacePersistenceCoordinator.swift`
- `Astra/Services/Persistence/WorkspaceConfigManager.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppService.swift`
- `Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift`
- `Astra/Services/Runtime/AgentInteractivePermissionChannel.swift`
- `Astra/Views/ContentView.swift`
- `Astra/Views/TaskMainView.swift`

**Tests:**

- `Tests/ArchitectureFitnessTests.swift`
- `Tests/WorkspacePersistenceTests.swift`
- `Tests/WorkspaceAppActionExecutorTests.swift`
- `Tests/TaskRunLifecycleServiceTests.swift`
- `Tests/HeadlessChatPermissionScenarioTests.swift`

**Validation:**

```bash
swift test --filter ArchitectureFitnessTests
swift test --filter WorkspacePersistenceTests
swift test --filter WorkspaceAppActionExecutorTests
swift test --filter TaskRunLifecycleServiceTests
swift test --filter HeadlessChatPermissionScenarioTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 20: Split Capability Resolution into Authorization and Relevance

**Root cause:** `TaskCapabilityResolver` mixes enablement, approval, keyword relevance, runtime projection, and special cases. Launch may resolve capabilities multiple times against mutable SwiftData state.

**First-principles solution:** Resolve once into an immutable snapshot, then pass that snapshot to worker, adapter, audit, and preflight. Authorization and relevance should be separate stages.

**Scope:**

- Add immutable `TaskCapabilityResolutionSnapshot`.
- Split authorization/approval from relevance pruning.
- Remove or isolate the hardcoded `github-workflow` special case.
- Thread the snapshot through launch, adapter, audit, and preflight call sites.

**Primary files:**

- `Astra/Services/Capabilities/TaskCapabilityResolver.swift`
- `Astra/Services/Capabilities/TaskCapabilitySnapshotter.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift`
- `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- `Astra/Services/Capabilities/CapabilityRuntimeIntegrityService.swift`

**Tests:**

- `Tests/TaskCapabilityResolverTests.swift`
- `Tests/ComposerCapabilitySnapshotTests.swift`
- `Tests/CapabilityRuntimeIntegrityServiceTests.swift`
- `Tests/AgentRuntimeWorkerTests.swift`
- `Tests/CapabilityCoverageGapTests.swift`

**Validation:**

```bash
swift test --filter TaskCapabilityResolverTests
swift test --filter ComposerCapabilitySnapshotTests
swift test --filter CapabilityRuntimeIntegrityServiceTests
swift test --filter AgentRuntimeWorkerTests
swift test --filter CapabilityCoverageGapTests
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 21: Collapse Policy Vocabulary Drift and Runtime Protocol Strings

**Root cause:** `AgentPolicyLevel` carries richer states than `PermissionPolicy`, then round-trips through lossy strings before reaching providers. Runtime phases and provider messages are also repeated as literals.

**First-principles solution:** Keep the rich policy enum authoritative until the final CLI flag edge. Runtime protocol values should be typed values, not unstructured strings.

**Scope:**

- Preserve `AgentPolicyLevel` semantics end-to-end and derive three-state CLI flags only at provider render.
- Replace `phase: String` runtime signatures with `RunPhase`.
- Move provider message strings into `ProviderMessages`.
- Split provider adapter implementations out of `AgentRuntimeAdapter.swift` only where it reduces file ownership without changing behavior.
- Add a process-runner protocol seam and pass value snapshots instead of live SwiftData models where practical.

**Primary files:**

- `ASTRACore/AgentPolicyTypes.swift`
- `ASTRACore/AgentRuntimeTypes.swift`
- `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`
- Provider adapter files under `Astra/Services/Runtime/`

**Tests:**

- `Tests/AgentPolicyTests.swift`
- `Tests/AgentRuntimeAdapterTests.swift`
- `Tests/AgentRuntimeComponentTests.swift`
- `Tests/RuntimeScenarioTestSupport.swift`
- `Tests/AgentRuntimeWorkerTests.swift`

**Validation:**

```bash
swift test --filter AgentPolicyTests
swift test --filter AgentRuntimeAdapterTests
swift test --filter AgentRuntimeComponentTests
swift test --filter AgentRuntimeWorkerTests
swift test
git diff --check
script/precommit.sh
script/prepush.sh
```

## PR 22: Hygiene and Drift Guardrails

**Root cause:** Dead code, stale docs, line-budget escapees, duplicate declarations, non-atomic JSON writes, and source-text tests let architecture drift hide outside the current guardrails.

**First-principles solution:** Delete or centralize unused code, bring docs into agreement with registered providers and services, and ratchet guardrails so future drift fails fast.

**Scope:**

- Delete `MCPToolPolicyEngine` only if live policy code does not need it; otherwise make it the shared most-restrictive-wins module.
- Delete the nested `ChatBubbleView` in `ChatPanelView.swift` and obsolete `WorkspaceAppWebViewBridge` remnants if they still have zero production callers.
- Update `docs/architecture/runtime-adapters.md` to match registered providers.
- Add architecture docs for `Astra/Services/WorkspaceApps` and execution environments.
- Add global line-budget fitness rule for files over 2,000 lines plus owner/companion accounting.
- Move production-source-text assertions into `ArchitectureFitnessTests` or replace them with behavior tests.
- Make `SSHConnectionManager.save` atomic.
- Remove duplicate `DraftMessage` declarations in `ChatPanelView.swift`.
- Move keychain IO out of `@Model` classes where service-owned patterns already exist.

**Primary files:**

- `Astra/Services/Capabilities/MCPToolPolicyEngine.swift`
- `Astra/Services/Capabilities/MCPToolPolicyGatewayAdapter.swift`
- `Astra/Views/ChatPanelView.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppWebViewBridge.swift`
- `Astra/Services/Persistence/SSHConnectionManager.swift`
- `Astra/Models/Connector.swift`
- `Tests/ArchitectureFitnessTests.swift`
- `Tests/TaskPresentationModelTests.swift`
- `docs/architecture/runtime-adapters.md`
- New docs under `docs/architecture/`

**Tests:**

- `Tests/ArchitectureFitnessTests.swift`
- `Tests/TaskPresentationModelTests.swift` if `ChatBubbleView` tests are removed or replaced.
- SSH connection save coverage in the nearest persistence test file.
- Behavior tests replacing any removed source-text assertions.

**Validation:**

```bash
swift test --filter ArchitectureFitnessTests
swift test --filter WorkspacePersistenceTests
swift test --filter CapabilityPackageValidatorTests
git diff --check
script/precommit.sh
```

---

## Suggested Execution Batches

**Batch 1 - Live defects and data-loss protection:**

Land PRs 1 through 5 in order. They are the highest urgency because they cover running-task correctness, accounting correctness, repeated disk IO, schema recovery, and accidental sensitive mirror commits.

**Batch 2 - Runtime and owner boundaries:**

Land PRs 6 through 12. These change core launch, task state, selection, credential, continuation, and utility-process ownership. Keep them separate; each one has a different failure mode and different reviewer expertise.

**Batch 3 - Build acceleration and structural extraction:**

Land PRs 9 and 13 early enough to make the rest cheaper. If PR 9 only lands CI/cache/filter fixes, PR 13 should take the standalone architecture-test target before any broad target extraction.

**Batch 4 - Consolidations by touched surface:**

Land PRs 14 through 21 as work returns to those areas. Do not pull them into urgent P0 branches.

**Batch 5 - Hygiene ratchet:**

Land PR 22 once P0s are closed, or split it into smaller cleanup PRs if any deletion has uncertain behavior.

## Final Readiness Checklist

- [ ] Every PR has one owner boundary and one primary invariant.
- [ ] Every PR has at least one focused regression or fitness test that would have failed before the change.
- [ ] No PR combines persistence schema changes with unrelated UI refactors.
- [ ] No PR combines runtime credential egress with unrelated provider UI work.
- [ ] No PR updates broad line budgets without shrinking, splitting, or explicitly allow-listing the file.
- [ ] Remote PR reports separate local validation, unresolved review threads, remote checks, and review-required blockers.
