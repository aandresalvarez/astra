#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

assert_targets() {
  local expected="$1"
  shift

  local actual
  actual="$(script/focused_test_targets.sh "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected targets:\n%s\nActual targets:\n%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

assert_targets "TaskDecisionOutcomeRefreshTests|TaskDecisionOutcomeColdRefreshTests|TaskDeliverableFollowUpTests|TaskDecisionDock|TaskMainActorScalingGateTests" \
  "Astra/Views/TaskDecisionOutcomeRefresh.swift" \
  "Tests/TaskDecisionOutcomeRefreshTests.swift" \
  "Astra/Services/Validation/TaskDeliverableHistoryReader.swift" \
  "Tests/TaskDecisionOutcomeColdRefreshTests.swift"

assert_targets "WorkspaceRailOutputPresentationTests|WorkspaceRailOutputPerformanceTests|WorkspaceRailSectionPresentationTests|WorkspaceRightRailPerformanceTests" \
  "Astra/Views/WorkspaceRailOutputPresentation.swift" \
  "Tests/WorkspaceRailOutputPerformanceTests.swift"

assert_targets "RuntimeNativeSessionOwnershipTests|AgentRuntimeAsyncWorkTests|AgentProcessResultTests" \
  "Astra/Services/Runtime/RuntimeNativeSessionOwnership.swift" \
  "Tests/RuntimeNativeSessionOwnershipTests.swift"

assert_targets "MCPGatewaySupportTests" \
  "Tools/MCPGatewaySupport/MCPGatewaySupport.swift" \
  "Tests/MCPGatewaySupportTests/RemoteMCPGatewaySupportTests.swift"

assert_targets "ProviderSharedStateIdentityTests|ProviderSharedStateMigrationTests|ProviderSharedStateLaunchTests" \
  "Astra/Services/Runtime/ProviderSharedStateIdentity.swift" \
  "Astra/Services/Runtime/ProviderSharedStateCompatibility.swift" \
  "Astra/Services/Runtime/AgentRuntimeProcessRunner+SharedConfiguration.swift" \
  "Tests/ProviderSharedStateIdentityTests.swift" \
  "Tests/ProviderSharedStateMigrationTests.swift" \
  "Tests/ProviderSharedStateLaunchTests.swift"

assert_targets "AntigravityReadFilePolicyTests|AgentPolicyTests|AgentPolicyRuntimeMatrixTests|RuntimePolicyGuardTests|AntigravityCLIRuntimeTests" \
  "ASTRACore/ProviderReadFileInput.swift" \
  "ASTRACore/ProviderToolSemantics.swift" \
  "ASTRACore/AgentPolicyTypes.swift" \
  "Astra/Services/Runtime/AgentPolicyAdapters.swift" \
  "Astra/Services/Runtime/AgentRuntimePolicyGuard.swift" \
  "Tests/AntigravityReadFilePolicyTests.swift"

assert_targets "RuntimeLaunchWaitTests|RuntimeLaunchPresentationRegressionTests|RuntimePreparationAccountingTests|RuntimePreparationSettlementTests|TaskDecisionDockPresentationTests|RuntimeProviderRecordingLimitsTests|NativeResumeEmptyTurnTests|ImportedTaskHistoryIsolationTests" \
  "Astra/Views/RuntimeLaunchPresentation.swift" \
  "Tests/RuntimePreparationAccountingTests.swift"

assert_targets "MCPServerKitTests" \
  "Tools/MCPServerKit/MCPServerKit.swift" \
  "Tests/MCPServerKitTests/MCPServerKitTests.swift"

assert_targets "MailToolSupportTests" \
  "Tools/MailToolSupport/AppleScriptSource.swift" \
  "Tools/StanfordAppleMailTool/main.swift" \
  "Tests/MailToolSupportTests/StanfordAppleMailToolTests.swift"

assert_targets $'HostControlToolSupportTests\nProcessWaitExecutorTests|ProcessDescriptorIsolationTests|SpawnedChildSignalStateTests|HostControlParentDeathSupervisorTests' \
  "Tools/HostControlToolSupport/HostControlToolSupport.swift" \
  "Tools/AstraHostControlTool/main.swift" \
  "Tests/HostControlParentDeathSupervisorTests.swift" \
  "Tests/HostControlToolSupportTests.swift"

assert_targets "BrowserToolShimTests" \
  "ASTRACore/SSHKnownHostsOption.swift" \
  "Tests/BrowserToolShimTests.swift"

assert_targets $'RemoteWorkspaceJobTests\nRemoteWorkspaceJobShimTests\nRemoteWorkspaceJobSafetyTests\nRemoteWorkspaceJobPersistenceTests\nRemoteWorkspaceJobBundlingTests\nRemoteWorkspaceJobOutputStateTests\nRemoteWorkspaceSSHRouteTests\nRemoteWorkspacePromptGuidanceTests' \
  "Tools/WorkspaceToolSupport/RemoteWorkspaceJobManager.swift" \
  "Tools/AstraWorkspaceJobTool/main.swift" \
  "Astra/Services/Runtime/RemoteWorkspaceJobShim.swift" \
  "Astra/Views/RemoteWorkspaceJobOutputState.swift" \
  "Tests/RemoteWorkspaceJobTests.swift"

assert_targets $'MCPGatewaySupportTests\nMCPServerKitTests\nMailToolSupportTests' \
  "Package.swift"

assert_targets "" \
  "Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift"

assert_targets "" \
  "ASTRAGitContracts/Sources/ASTRAGitContracts/GitStatusContracts.swift"

assert_targets "CLIPrerequisiteSlowStartTests|EnvironmentHealthCheckerTests|PreflightCacheTests|PluginManifestTests|PluginPackagePrereqTests|CapabilityHealthServiceTests|CapabilityRuntimeIntegrityServiceTests|PluginRepair|CLISessionExpiryTests" \
  "ASTRACore/GCloudCredentialProbe.swift" \
  "Tests/CLIPrerequisiteSlowStartTests.swift"

assert_targets "CodexSessionUsageCorrection|CumulativeSessionUsage|ProviderSessionUsageEpoch|WorkspaceImportOrchestrator|RuntimeRecoveryOwnershipTests" \
  "Astra/Services/Tasks/CodexSessionUsageCorrectionAdmission.swift" \
  "Astra/Services/Tasks/CodexSessionUsageReplay.swift" \
  "Astra/Services/Persistence/WorkspaceConfigManager+CodexUsageHistory.swift" \
  "Tests/CodexSessionUsageCorrectionImportTests.swift"

assert_targets "AppSemanticFitnessTests" \
  "Tests/AppSemanticFitnessTests.swift"

assert_targets $'RuntimeSupervision\nProcessMonitorTests\nClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting' \
  "Astra/Services/Runtime/RuntimeSupervisionSession.swift" \
  "Astra/Services/Runtime/AgentProcessSupport.swift" \
  "Tests/RuntimeSupervisionWorkerTests.swift"

assert_targets $'RuntimeRecovery\nRuntimeSupervision' \
  "Astra/Services/Runtime/RuntimeRecoverySession.swift" \
  "Astra/Services/Runtime/RuntimeRecoveryService.swift" \
  "Tests/RuntimeRecoveryTests.swift"

for path in \
  Tests/TaskMainActorScalingGateTests.swift \
  Tests/TaskHistoryReadTests.swift \
  Astra/Models/TaskHistoryRead.swift \
  Astra/Services/Tasks/TaskConversationContinuationService.swift \
  Astra/Services/Tasks/TaskExecutionLaunchSnapshotApplicator.swift \
  Astra/Services/Runtime/TaskRuntimePermissionGrants.swift; do
  assert_targets $'TaskMainActorScalingGateTests\nTaskHistoryReadTests\nTaskExecutionLaunchSnapshotApplicatorTests\nRuntimePermissionGrantRegressionTests' "$path"
done

for path in \
  Astra/Services/Persistence/SSHConnectionManager.swift \
  Astra/Services/Persistence/WorkspaceAutoExportWriter.swift \
  Astra/Services/Persistence/WorkspaceConfigManager.swift \
  Astra/Services/Persistence/WorkspacePersistenceCoordinator.swift \
  Astra/Services/Persistence/WorkspacePersistenceWork.swift \
  Astra/Services/Persistence/WorkspaceSavedAutoExport.swift \
  Astra/Services/Persistence/WorkspaceExportChangeScope.swift \
  Astra/Services/Persistence/WorkspaceSavedExportLease.swift \
  Astra/Services/Persistence/WorkspaceSnapshotDirectory.swift \
  Tests/WorkspaceSavedExportPendingTests.swift \
  Tests/WorkspaceSavedExportReplacementTests.swift \
  Tests/WorkspaceSnapshotDirectoryTests.swift \
  Tests/WorkspaceSavedAutoExportTests.swift \
  Tests/WorkspaceSavedExportReviewTests.swift \
  Tests/WorkspaceExportTerminationFlushTests.swift \
  Tests/RunFinalizationResponsivenessTests.swift \
  Tests/RuntimeSettlementReviewRegressionTests.swift; do
  assert_targets $'RuntimeSettlementReviewRegressionTests\nWorkspaceSavedAutoExportTests\nWorkspaceSavedExportSnapshotTests\nWorkspaceSavedExportReviewTests\nWorkspaceSavedExportPendingTests\nWorkspaceSavedExportReplacementTests\nWorkspaceSnapshotDirectoryTests\nWorkspaceExportTerminationFlushTests\nAgentRuntimeRunPersistenceTests\nTaskThreadChangeObserverTests' "$path"
done

assert_targets "FeedbackEvidencePrivacyTests" \
  "Astra/Services/Feedback/FeedbackEvidenceBuilder.swift" \
  "Tests/FeedbackEvidencePrivacyTests.swift"

assert_targets $'RuntimeFeedbackSnapshotTests\nFeedbackEvidencePrivacyTests' \
  "Astra/Services/Feedback/RuntimeFeedbackSnapshotBuilder.swift"

assert_targets $'RuntimeFeedbackSnapshotTests\nFeedbackEvidencePrivacyTests' \
  "Tests/RuntimeFeedbackSnapshotTests.swift"

assert_targets $'RuntimeFeedbackSnapshotTests\nFeedbackEvidencePrivacyTests' \
  "Astra/Services/Feedback/RuntimeFeedbackSnapshotBuilder.swift" \
  "Tests/RuntimeFeedbackSnapshotTests.swift" \
  "Astra/Services/Feedback/FeedbackEvidenceBuilder.swift" \
  "Tests/FeedbackEvidencePrivacyTests.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackEvidencePrivacyTests\nRuntimeFeedbackSnapshotTests\nFeedbackOutboxStateMachineTests\nFeedbackManualExportTests' \
  "Astra/Services/Feedback/FeedbackReportPreparationService.swift" \
  "Astra/Services/Feedback/FeedbackPreparationStagingReconciler.swift" \
  "Astra/Views/Feedback/FeedbackReportView.swift" \
  "Tests/FeedbackReportPresentationTests.swift" \
  "Tests/FeedbackReportPresentationLifecycleTests.swift"

assert_targets $'FeedbackCrashRecoveryTests\nFeedbackReportPresentationTests' \
  "Astra/Services/Feedback/FeedbackCrashOfferService.swift" \
  "Astra/Services/Feedback/FeedbackCrashLaunchMonitor.swift" \
  "Tests/FeedbackCrashRecoveryTests.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackOutboxStateMachineTests\nFeedbackManualExportTests' \
  "Astra/Services/Persistence/FeedbackOutboxService.swift"

assert_targets "FeedbackManualExportTests" \
  "Astra/Services/Feedback/FeedbackManualExportService.swift" \
  "Tests/FeedbackManualExportTests.swift"

assert_targets $'FeedbackReportContractTests\nFeedbackEvidencePrivacyTests\nFeedbackOutboxStateMachineTests\nFeedbackAssessmentPolicyTests\nFeedbackReportPresentationTests' \
  "ASTRACore/Feedback/FeedbackReportContract.swift" \
  "ASTRACore/Feedback/FeedbackAssessmentContract.swift" \
  "Astra/Services/Persistence/FeedbackPackageAdoptionValidator.swift" \
  "Astra/Services/Persistence/FeedbackEvidenceArchiveValidator.swift" \
  "Astra/Services/Persistence/FeedbackPackageRemoval.swift"

assert_targets $'TaskDecisionDockPresentationTests\nFeedbackReportPresentationTests' \
  "Tests/TaskDecisionDockPresentationTests.swift" \
  "Astra/Services/Tasks/TaskDecisionDockPresentation.swift"

assert_targets $'TaskDecisionDockPresentationTests\nFeedbackReportPresentationTests\nComposerAttachmentsTests\nTaskInputContinuityPromptTests\nTaskAttachmentFilesReaderTests' \
  "Astra/Views/TaskMainView.swift"

assert_targets $'ComposerAttachmentsTests\nTaskInputContinuityPromptTests\nTaskAttachmentFilesReaderTests' \
  "Astra/Views/Components/TaskFilesPopoverView.swift" \
  "Astra/Views/Components/TaskInputFilesView.swift" \
  "Tests/ComposerAttachmentsTests.swift"

assert_targets $'TaskAttachmentFilesReaderTests\nComposerAttachmentsTests' \
  "Astra/Services/Tasks/TaskAttachmentFilesReader.swift" \
  "Tests/TaskAttachmentFilesReaderTests.swift"

assert_targets $'ClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting\nRuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode\nRuntimeCancellationDiagnosticTests\nHeadlessChatScenarioTests\nFeedbackReportPresentationTests\nCopilotPostFailureHomeInspectionTests\nAgentRuntimeFailureDiagnosticsTests\nAgentRuntimeAdapterTests' \
  "Astra/Services/Runtime/AgentRuntimeWorker.swift" \
  "Tests/HeadlessChatProcessScenarioTests.swift" \
  "Astra/Services/Diagnostics/AgentRuntimeDiagnostics.swift" \
  "Astra/Services/Runtime/ProviderMessages.swift" \
  "Tests/AgentRuntimeAdapterTests.swift"

assert_targets $'DiagnosticCoverageRegressionTests\nPendingP2RegressionTests\nLogDiagnosticsTests\nFeedbackEvidencePrivacyTests\nFeedbackCrashRecoveryTests' \
  "Astra/Services/Diagnostics/LogDiagnosticsService.swift" \
  "Astra/Services/Diagnostics/PersistedLogEntryParser.swift" \
  "Astra/Services/Diagnostics/CrashDiagnosticsService.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackCrashRecoveryTests' \
  "Astra/Models/AppStorageKeys.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackCrashRecoveryTests\nTaskDecisionDockPresentationTests\nWorkspaceRightPanelLayoutTests\nPanelLayoutGeometryTests' \
  "Astra/Models/AppStorageKeys.swift" \
  "Tests/TaskDecisionDockPresentationTests.swift" \
  "Astra/Views/ContentView.swift" \
  "Astra/Services/Feedback/FeedbackCrashOfferService.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackCrashRecoveryTests\nWorkspaceRightPanelLayoutTests\nPanelLayoutGeometryTests' \
  "Astra/ASTRAApp.swift" \
  "Astra/Views/ContentView.swift" \
  "Astra/Views/LogViewerView.swift"

assert_targets $'WorkspaceRightPanelLayoutTests\nPanelLayoutGeometryTests' \
  "Astra/Views/WorkspaceCanvasItem.swift" \
  "Tests/PanelLayoutGeometryTests.swift" \
  "Tests/WorkspaceRightPanelLayoutTests.swift"

assert_targets ""

assert_targets $'RuntimeHomeAccessTests\nRuntimeHomeAccessEdgeCaseTests\nRuntimeHomeAccessAdditionalStateTests\nNativeContinuationFallbackTests\nExecutionSandboxRunnerTests\nCopilotHomeAccessCheckTests\nPermissionRepairCommandClientTests\nRuntimeReadinessServiceTests\nRuntimeReadinessStateCacheTests\nRuntimeLaunchReadinessCacheTests\nAgentRuntimeAdapterTests\nExecutionEnvironmentTests' \
  "Astra/Services/Runtime/AgentRuntimeAdapter.swift"

assert_targets $'CodexMCPConfigRendererTests\nMCPRuntimeProjectionTests' \
  "Astra/Services/Runtime/CodexMCPLaunchProjection.swift" \
  "Tests/CodexMCPConfigRendererTests.swift"

assert_targets $'ShelfMarkdownPanelLayoutTests\nShelfChromeTests\nTaskAttachmentFilesReaderTests\nShelfAttachmentHistoryTests' \
  "Astra/Views/ShelfFileNavigatorPresentation.swift" \
  "Astra/Views/ShelfMarkdownPanelView.swift" \
  "Tests/ShelfMarkdownPanelLayoutTests.swift"

assert_targets $'ShelfAttachmentHistoryTests\nTaskAttachmentFilesReaderTests' \
  "Astra/Views/ShelfAttachmentHistoryModifier.swift" \
  "Tests/ShelfAttachmentHistoryTests.swift"

assert_targets $'ReleaseBuildNumberDerivationTests\nReleaseUpdateScriptTests\nAppBundlePackagingTests' \
  ".github/workflows/release.yml" \
  "script/build_and_run.sh" \
  "Tests/ReleaseBuildNumberDerivationTests.swift"

assert_targets $'SidebarTaskStoreTests\nSidebarTaskStoreSignalIntegrationTests\nSidebarTaskSourceObservationTests' \
  "Astra/Views/SidebarTaskChangeObservation.swift" \
  "Tests/SidebarTaskSourceObservationTests.swift"

assert_targets "RunningTaskCountPredicateTests" \
  "Astra/Services/Settings/AppUpdateSafety.swift"

assert_targets $'SwiftDataDeletionPreparationTests\nNewTaskWorktree\nPendingP2RegressionTests\nSpecEngineTests' \
  "Astra/Services/Persistence/SwiftDataDeletionPreparation.swift" \
  "Astra/Services/Tasks/TaskWorktreeService.swift" \
  "Astra/Services/Tasks/TaskLifecycleCoordinator.swift"

assert_targets "OrphanedV12StoreMigratorTests" \
  "Astra/Services/Persistence/OrphanedV12StoreMigrator.swift" \
  "Tests/OrphanedV12StoreMigratorTests.swift"

assert_targets $'AgentRuntimePipeCompletionTests\nStreamVolumeAccountingTests\nAgentExecutionScopedProcessTests\nRuntimeRecovery\nAgentUtilityRuntimeTests\nProcessMonitorTests\nProcessWaitExecutorTests|ProcessDescriptorIsolationTests|ProcessBinaryRunnerTests|SpawnedChildSignalStateTests|OpenCodeRunnerCompletionTests|OpenCodeCompletionProofTests|HostControlParentDeathSupervisorTests\nClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting\nRuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode' \
  "Astra/Services/Runtime/AgentProcessPipeReader.swift" \
  "Astra/Services/Runtime/AgentExecutionScopedProcess.swift" \
  "Tests/AgentExecutionScopedProcessTests.swift" \
  "Astra/Services/Runtime/AgentRuntimeProcessRunner.swift" \
  "Tests/AgentRuntimePipeCompletionTests.swift"

assert_targets $'UsageDashboardStoreTests\nUsageDashboardRenderingTests' \
  "Astra/Views/UsageDashboardView.swift" \
  "Astra/Views/UsageDashboardTaskTable.swift" \
  "Astra/Views/UsageDashboardStore.swift" \
  "Astra/Views/UsageDashboardSummary.swift" \
  "Tests/UsageDashboardStoreTests.swift" \
  "Tests/UsageDashboardRenderingTests.swift" \
  "Tests/LargeHistoryResponsivenessTests.swift"

for path in \
  ASTRACore/RuntimeProgressSignals.swift \
  Tests/RuntimeProgressSignalTests.swift; do
  assert_targets $'StreamVolumeAccountingTests\nRuntimeProgressClassificationTests\nWatchdogEscalationTests\nRuntimeStreamReplayTests\nCodexFileChangeProgressTests' "$path"
done

for path in \
  ASTRACore/CodexStreamEventParser.swift \
  Astra/Services/Runtime/CodexCLIRuntime.swift \
  Tests/CodexCLIRuntimeTests.swift \
  Tests/CodexFileChangeProgressTests.swift; do
  expected=$'CodexCLIRuntimeTests\nProviderMessageIdentityTests\nAgentEventRecorderTests\nProviderTranscriptConformanceTests\nRuntimeProgressClassificationTests\nWatchdogEscalationTests\nCodexFileChangeProgressTests'
  if [[ "$path" == "ASTRACore/CodexStreamEventParser.swift" ]]; then
    expected=$'ClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting\n'"$expected"
  fi
  assert_targets "$expected" "$path"
done

assert_targets $'TaskDecisionOutcomeColdRefreshTests\nTaskTextOnlyDeliverableTests\nTaskDeliverableExpectationTests\nDeliverableExpectationCoverageTests\nTaskDeliverableVerificationServiceTests\nTaskDeliverableFollowUpTests\nTaskExecutionResourceClaimResolverTests' \
  "Astra/Services/Validation/TaskDeliverableExpectation.swift" \
  "Astra/Services/Validation/StandaloneArtifactRequestPolicy.swift" \
  "Astra/Services/Tasks/TaskIntentLanguagePolicy.swift" \
  "Tests/TaskTextOnlyDeliverableTests.swift"

assert_targets $'TaskInputContinuityPromptTests\nBuildPromptTests\nAgentRuntimeAttachmentProjectionTests\nRuntimeAttachmentPolicyRegressionTests\nPromptContextPreviewPresentationTests' \
  "Astra/Services/Runtime/AgentPromptBuilder.swift" \
  "Astra/Services/Runtime/TaskInputManifest.swift" \
  "Astra/Services/Runtime/TaskInputsPromptSectionProvider.swift" \
  "Astra/Services/Tasks/PromptContextSectionProvider.swift" \
  "Astra/Views/PromptContextPreviewView.swift" \
  "Tests/TaskInputContinuityPromptTests.swift" \
  "Tests/AgentRuntimeWorkerTests.swift"

assert_targets $'HostFileAccessBrokerTests\nShelfPreviewFailureTests\nShelfMarkdownAsyncLoadingTests|ShelfFilesOwnershipTests' \
  "ASTRACore/HostFileAccessBroker.swift" \
  "Astra/Services/Browser/ShelfPreviewFailure.swift"

assert_targets $'TaskOutputDiscoveryTests\nAgentRuntimeRunPersistenceTests' \
  "Astra/Services/Persistence/TaskOutputDiscovery.swift"

assert_targets $'TaskOutputDiscoveryTests\nAgentRuntimeRunPersistenceTests\nRuntimeSettlementReviewRegressionTests\nWorkspaceSavedAutoExportTests\nWorkspaceSavedExportSnapshotTests\nWorkspaceSavedExportReviewTests\nWorkspaceSavedExportPendingTests\nWorkspaceSavedExportReplacementTests\nWorkspaceSnapshotDirectoryTests\nWorkspaceExportTerminationFlushTests\nTaskThreadChangeObserverTests' \
  "Astra/Services/Runtime/AgentRuntimeRunPersistence.swift"

assert_targets $'PendingP2RegressionTests\nSpecEngineTests\nAntigravityCLIRuntimeTests\nBinaryProcessGroupCompletionTests|ProcessBinaryRunnerTests|AntigravityLaunchPreparationTests|RuntimeCancelledPreparationContinuationTests|RuntimeCompletedUserTurnContinuationTests' \
  "Astra/Services/Tasks/TaskTitleGenerationService.swift" \
  "Astra/Services/Runtime/AntigravityCLIRuntime.swift"

assert_targets $'SwiftDataDeletionPreparationTests\nNewTaskWorktree\nPendingP2RegressionTests\nSpecEngineTests' \
  "Astra/Services/Tasks/TaskLifecycleCoordinator.swift"

assert_targets $'DiagnosticCoverageRegressionTests\nPendingP2RegressionTests\nLogDiagnosticsTests\nFeedbackEvidencePrivacyTests' \
  "Astra/Services/Diagnostics/LogDiagnosticsCollection.swift" \
  "Astra/Services/Diagnostics/LogDiagnosticsPreparationService.swift"

assert_targets $'CopilotCLICommandPlanningTests\nCopilotCLICapabilityProbeTests\nCopilotWorkerExecutionTests\nCopilotLaunchDiscoveryTests\nCopilotDiscoveryAdmissionTests\nCopilotCapabilityFlightDeadlineTests\nAgentUtilityRuntimeTests\nAgentRuntimeCapabilityProfileTests\nRuntimeReadinessServiceTests\nPendingP2RegressionTests' \
  "Astra/Services/Runtime/CopilotCLIRuntime.swift"

assert_targets $'ShelfFileIndexControllerTests\nFilesShelfResponsivenessTelemetryTests\nUIResponsivenessDiagnosticsTests\nShelfAttachmentHistoryTests' \
  "Astra/Views/ShelfFileIndexController.swift" \
  "Astra/Views/ShelfAttachmentRootResolver.swift" \
  "Tests/ShelfFileIndexControllerTests.swift" \
  "Astra/Services/Diagnostics/FilesShelfResponsivenessTelemetry.swift" \
  "Astra/Services/Diagnostics/UIResponsivenessDiagnostics.swift"

assert_targets $'GitHubReviewPublicationTests\nSwiftDataDeletionPreparationTests' \
  "Astra/Services/Persistence/SwiftDataTaskRollbackPreparation.swift" \
  "Astra/Services/Git/GitHubReviewPublicationService.swift" \
  "Tests/GitHubReviewPublicationTests.swift"

assert_targets $'RuntimeHomeAccessTests\nRuntimeHomeAccessEdgeCaseTests\nRuntimeHomeAccessAdditionalStateTests\nNativeContinuationFallbackTests\nExecutionSandboxRunnerTests\nCopilotHomeAccessCheckTests\nPermissionRepairCommandClientTests\nRuntimeReadinessServiceTests\nRuntimeReadinessStateCacheTests\nRuntimeLaunchReadinessCacheTests\nAgentRuntimeAdapterTests\nExecutionEnvironmentTests' \
  "Astra/Services/Runtime/RuntimeHomeAccessPolicy.swift" \
  "Astra/Services/Runtime/RuntimeHomeAccessService.swift" \
  "Astra/Services/Runtime/RuntimeHomeAccessContainerCommand.swift" \
  "Astra/Services/Runtime/RuntimeAccessACL.swift" \
  "Astra/Services/Runtime/AgentRuntimeProcessRunner+HomeAccessGuard.swift" \
  "AstraObjCSupport/AstraMembership.m" \
  "Tests/RuntimeHomeAccessTests.swift" \
  "Tests/RuntimeHomeAccessEdgeCaseTests.swift" \
  "Tests/RuntimeHomeAccessAdditionalStateTests.swift" \
  "Tests/RuntimeReadinessStateCacheTests.swift" \
  "Tests/RuntimeLaunchReadinessCacheTests.swift" \
  "Astra/Services/Runtime/RuntimeHomeAccessContainerPreflight.swift" \
  "Astra/Services/Runtime/ProviderNativeSessionStore.swift" \
  "Astra/Services/Runtime/RuntimeHomeAccessCancellationGate.swift" \
  "Tests/ExecutionSandboxRunnerTests.swift"

assert_targets $'RuntimeCancellationDiagnosticTests\nHeadlessChatScenarioTests\nFeedbackReportPresentationTests\nCopilotPostFailureHomeInspectionTests' \
  "Astra/Services/Runtime/CopilotPostFailureHomeInspection.swift" \
  "Tests/CopilotPostFailureHomeInspectionTests.swift"

assert_targets $'AgentRuntimeAdapterTests\nNativeContinuationFallbackTests' \
  "Tests/AgentRuntimeAdapterCopilotFixture.swift"

assert_targets $'RuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode\nProviderSharedStateIdentityTests|ProviderSharedStateMigrationTests|ProviderSharedStateLaunchTests' \
  'Astra/Services/Tasks/TaskQueue.swift' \
  'Astra/Services/Runtime/RuntimeProviderOwnershipReference.swift' \
  'Tests/RuntimeCancellationReviewTests.swift' \
  'Tests/RuntimeSettlementCancellationTests.swift'

assert_targets 'RuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode' \
  'Tests/Fixtures/ProviderStreams/claude/cancellation-tool-free.jsonl' \
  'Tests/Fixtures/ProviderStreams/codex/cancellation-tool-free.jsonl' \
  'Tests/Fixtures/ProviderStreams/antigravity/cancellation-tool-free.jsonl'

assert_targets 'RuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode' \
  'Astra/Services/Runtime/RuntimeTemplateHookScope.swift' \
  'Tests/LaunchSnapshotDisciplineTests.swift' \
  'Tests/QueueLockTests.swift' \
  'Tests/RuntimeSettlementRecoveryFollowupTests.swift'

assert_targets 'CapabilityInstallerTests|CapabilityResolutionInputsTests|PluginActivationMigrationTests|PluginActivationOwnershipTests|PluginPromptScopeParityTests|RoutineSkillSelectionTests' \
  'Tests/CapabilityResolutionTestSupport.swift' \
  'Tests/CapabilityInstallerTests.swift' \
  'Tests/PluginActivationMigrationTests.swift' \
  'Tests/PluginActivationOwnershipTests.swift' \
  'Tests/PluginPromptScopeParityTests.swift' \
  'Tests/RoutineSkillSelectionTests.swift'

# Completion/accounting safety must run in the required focused CI lane.
assert_targets $'ClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting\nRuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode' \
  "ASTRACore/OpenCodeStreamAccounting.swift" \
  "Tests/RuntimeProviderStreamContractTests.swift" \
  "Tests/Fixtures/ProviderStreams/claude/recovery-captured-20261024.jsonl"

assert_targets "ClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting" \
  "ASTRACore/ClaudeSessionUsageSnapshot.swift" \
  "Astra/Services/Tasks/ClaudeSessionUsageEvidence.swift" \
  "Tests/ClaudeSessionUsageAccountingTests.swift" \
  "ASTRACore/ClaudeStreamAccounting.swift" \
  "ASTRACore/CopilotStreamAccounting.swift" \
  "Astra/Models/TaskRequestBudget.swift" \
  "Tests/RuntimeUsageStreamContractTests.swift"

assert_targets "NativeResumeEmptyTurnTests|RuntimeUsage" \
  "Astra/Services/Runtime/NativeResumeEmptyTurnGate.swift" \
  "Tests/NativeResumeEmptyTurnTests.swift"

for path in Astra/Services/Persistence/TaskContextEventIndex.swift Astra/Services/Persistence/TaskContextStateManager.swift Astra/Services/Persistence/TaskActiveObjectiveResolver.swift Astra/Models/TaskCorrectiveWorkQueries.swift Tests/TaskContextEventIndexTests.swift Tests/TaskContextDerivationPerformanceTests.swift Tests/TaskContextStateOffMainRefreshTests.swift; do
  assert_targets $'TaskContextEventIndexTests|TaskContextState|TaskPlanServiceTests\nTaskHistoryReadTests|TaskMainActorScalingGateTests\nTaskAttachmentFilesReaderTests|ShelfAttachmentHistoryTests\nrequestBudget' "$path"
done

assert_targets $'ShelfBrowserOwnershipTests|ShelfBrowserLifetimeTests|ControlledBrowserProfileLeaseTests|BrowserBridgeSecurityTests|BrowserSessionPolicy|ShelfBrowserPanelLayoutTests|WorkspaceRightRailPerformanceTests\nShelfFilesOwnershipTests|ShelfMarkdownSessionTests|ShelfMarkdownAsyncLoadingTests' \
  "Astra/Services/Browser/ShelfSessionStores.swift"
assert_targets "ShelfFilesOwnershipTests|ShelfMarkdownSessionTests|ShelfMarkdownAsyncLoadingTests" \
  "Tests/ShelfFilesOwnershipTests.swift"
assert_targets $'TaskAttachmentFilesReaderTests\nComposerAttachmentsTests' \
  "Astra/Services/Tasks/TaskHeaderFilesReader.swift"

assert_targets $'AgentRuntimePipeCompletionTests\nStreamVolumeAccountingTests\nAgentExecutionScopedProcessTests\nRuntimeRecovery\nAgentUtilityRuntimeTests\nProcessMonitorTests\nProcessWaitExecutorTests|ProcessDescriptorIsolationTests|ProcessBinaryRunnerTests|SpawnedChildSignalStateTests|OpenCodeRunnerCompletionTests|OpenCodeCompletionProofTests|HostControlParentDeathSupervisorTests\nBinaryProcessGroupCompletionTests|ProcessBinaryRunnerTests|AntigravityLaunchPreparationTests|RuntimeCancelledPreparationContinuationTests|RuntimeCompletedUserTurnContinuationTests' \
  "ASTRACore/ProcessGroupSpawn.swift" \
  "ASTRACore/ProcessWaitExecutor.swift" \
  "Tests/ProcessWaitExecutorTests.swift" \
  "ASTRACore/BinaryRunner.swift" \
  "Tests/BinaryRunnerTests.swift" \
  "Tests/ProcessDescriptorIsolationTests.swift"
