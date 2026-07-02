# ASTRA Architectural Review Remaining Execution Loop

**Coordinator branch:** `alvaro/arch-review-all-remaining-gaps`
**Foundation checkpoint:** `f3b882e` (`PR 1-4`)
**Source plan:** `docs/superpowers/plans/2026-07-01-architectural-review-pr-split.md`

## Loop Contract

For each remaining PR:

1. Create an isolated worktree and branch from the current coordinator branch.
2. Give the implementer the full PR text, owning boundary, and verification target.
3. Require a local commit in the PR worktree.
4. Run spec-compliance review against the actual diff.
5. Run code-quality review only after spec compliance passes.
6. Merge the PR branch into the coordinator branch.
7. Run focused tests for that PR plus `git diff --check`.
8. Only advance to the next PR after the coordinator branch is clean and verified.

## Remaining Queue

- [x] PR 5: Bound and Relocate the Workspace JSON Mirror
- [x] PR 6: Derive Launch Arguments from `ProviderPolicyRender`
- [x] PR 7: Introduce `TaskStateMachine`
- [x] PR 8: Introduce `SceneSelectionModel`
- [x] PR 9: Fix CI and Test Target Feedback Loops
- [x] PR 10: Gate Credential Egress
- [ ] PR 11: Promote Continuation and Approval State to Typed Properties
- [ ] PR 12: Run Utility Prompts Through a Sandboxed Launch Plan
- [ ] PR 13: Extract First SwiftPM Leaf Targets
- [ ] PR 14: Extract a Shared Chat Transcript Component
- [ ] PR 15: Replace Browser Command Switches with a Handler Registry
- [ ] PR 16: Single-Source WorkspaceApps Permission Gate and Read Pipeline
- [ ] PR 17: Add `MCPServerKit` for Stdio Server Boundaries
- [ ] PR 18: Add a Shared `HardenedProcessExecutor`
- [ ] PR 19: Funnel SwiftData Saves Through Persistence Boundaries
- [ ] PR 20: Split Capability Resolution into Authorization and Relevance
- [ ] PR 21: Collapse Policy Vocabulary Drift and Runtime Protocol Strings
- [ ] PR 22: Hygiene and Drift Guardrails

## Final Verification Gate

- [ ] `swift test`
- [ ] `git diff --check`
- [ ] `script/precommit.sh`
- [ ] `script/prepush.sh`

## Completed PRs

### PR 5

- Branch: `alvaro/arch-review-pr5-json-mirror`
- Head: `03b28a5c2a4e2559b6f969bd29b248861f5dcf1e`
- Spec review: passed after fix loop.
- Code quality review: passed after fix loop.
- Coordinator merge: completed.
- Focused worker validation: `WorkspacePersistenceTests`, `WorkspaceStoreRepairTests`, `git diff --check`, `script/precommit.sh`.

### PR 6

- Branch: `alvaro/arch-review-pr6-policy-render`
- Head: `a07c03f789889214d45f475781706a82f10744da`
- Spec review: passed after the Copilot Docker Auto render/launch consistency loop.
- Code quality review: passed after fixing broad Copilot flags and stale wildcard render evidence.
- Coordinator merge: completed.
- Focused worker validation: `AgentRuntimeAdapterTests`, `AgentPolicyTests`, `RunPermissionManifestTests`, `AgentRuntimeExecutionPolicyTests`, `ArchitectureFitnessTests`, `CopilotRuntimeTests`, `ExecutionSandboxRunnerTests`, `git diff --check`, `script/precommit.sh`.
- Coordinator validation: `swift test --filter AgentRuntimeAdapterTests/copilotDockerAutoPreflightManifestPersistsRestrictedLaunchFlags` passed; `swift test --filter AgentRuntimeAdapterTests --filter AgentPolicyTests --filter RunPermissionManifestTests --filter AgentRuntimeExecutionPolicyTests --filter ArchitectureFitnessTests` passed.

### PR 7

- Branch: `alvaro/arch-review-pr7-task-state-machine`
- Head: `ef9874272d6e258863a9725d9b96ff54306b1c59`
- Spec review: passed after the queue-admission, no-step approved-plan, and raw status-write fitness guard fix loop.
- Code quality review: passed after verifying `TaskStateMachine` stayed the production status mutation boundary.
- Coordinator merge: completed.
- Focused worker validation: `TaskStateMachineTests`, `QueueLockTests`, `TaskRunLifecycleServiceTests`, `TaskRuntimeHealthTests`, `ArchitectureFitnessTests`, `git diff --check`, `script/precommit.sh`.
- Coordinator validation: `swift test --filter TaskStateMachineTests`, `swift test --filter ArchitectureFitnessTests/productionTaskStatusWritesGoThroughTaskStateMachine`, `swift test --filter TaskRunLifecycleServiceTests`, `swift test --filter QueueLockTests`, `swift test --filter TaskRuntimeHealthTests`, `swift test --filter ArchitectureFitnessTests`, and `git diff --check 6f777596c93e211ff58b4d0fb03d7ee36c2212e1..HEAD` passed before merge.

### PR 8

- Branch: `alvaro/arch-review-pr8-scene-selection`
- Head: `33f322cabe23b6c68756e2346a03e2b042892bf4`
- Spec review: passed after fixing App/App Studio side effects and passive workspace restoration preservation.
- Code quality review: passed after verifying `SceneSelectionModel` stayed the single mutable scene selection owner.
- Coordinator merge: completed.
- Focused worker validation: `SceneSelectionModelTests`, `SidebarPresentationModelTests`, `SidebarSurfaceTests`, `SidebarWorkspaceAppFilterTests`, `ViewTests`, `git diff --check`, `script/precommit.sh`.
- Coordinator validation: `swift test --filter SceneSelectionModelTests` passed after merge.

### PR 9

- Branch: `alvaro/arch-review-pr9-ci-feedback`
- Head: `d7cbdc4d2791aa1260778dde1dfd19f146e05691`
- Spec review: passed after confirming CI cache/manual full-suite coverage, focused hook routing, and the PR13 deferral for the ArchitectureFitness leaf target split.
- Code quality review: passed after fixing macOS `/bin/bash` empty-array handling under `set -u` and wiring `script/focused_test_targets_tests.sh` into the automated guardrails.
- Coordinator merge: completed.
- Focused worker validation: `script/focused_test_targets_tests.sh`, `swift test --filter MCPGatewaySupportTests`, `swift test --filter MailToolSupportTests`, `git diff --check`, `script/precommit.sh`, `script/prepush.sh`.
- Coordinator validation: shell syntax checks for focused target scripts and hooks, `script/focused_test_targets_tests.sh`, `swift test --filter ArchitectureFitnessTests/repositoryProtectionArtifactsStayWired`, `swift test --filter MCPGatewaySupportTests`, `swift test --filter MailToolSupportTests`, and `git diff --check 0aa6bffdb9d74a4d49eedf9d0a9c3537de6cdf2d..HEAD` passed after merge.

### PR 10

- Branch: `alvaro/arch-review-pr10-credential-egress`
- Head: `93e2c40a82a579fec68eff4db17c219f038b0db8`
- Spec review: passed.
- Code quality review: passed after fixing one-run credential replay and fail-closed non-HTTP compatibility defaults.
- Coordinator merge: completed.
- Focused worker validation: `TaskRuntimePermissionActionHandlerTests`, `CapabilityProjectionRobustnessTests`, `TaskLifecycleResumeTests`, `ConnectorPreflightServiceTests`, `TaskCapabilityResolverTests`, `AgentPolicyTests`, `AgentRuntimeAdapterTests`, `AgentRuntimeExecutionPolicyTests`, `git diff --check`, `script/precommit.sh`, `script/prepush.sh`.
- Coordinator validation: `swift test --filter CapabilityProjectionRobustnessTests`, `swift test --filter 'ConnectorPreflightServiceTests|TaskRuntimePermissionActionHandlerTests|TaskCapabilityResolverTests|AgentPolicyTests|AgentRuntimeAdapterTests'`, `swift test --filter 'TaskLifecycleResumeTests|AgentRuntimeExecutionPolicyTests'`, and `git diff --check 14d1c7355fd0ea2e8e4c15f37a2fae369c36e1d7..HEAD` passed after merge.
