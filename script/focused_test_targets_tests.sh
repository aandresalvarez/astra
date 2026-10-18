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

assert_targets "MCPGatewaySupportTests" \
  "Tools/MCPGatewaySupport/MCPGatewaySupport.swift" \
  "Tests/MCPGatewaySupportTests/RemoteMCPGatewaySupportTests.swift"

assert_targets "MCPServerKitTests" \
  "Tools/MCPServerKit/MCPServerKit.swift" \
  "Tests/MCPServerKitTests/MCPServerKitTests.swift"

assert_targets "MailToolSupportTests" \
  "Tools/MailToolSupport/AppleScriptSource.swift" \
  "Tools/StanfordAppleMailTool/main.swift" \
  "Tests/MailToolSupportTests/StanfordAppleMailToolTests.swift"

assert_targets "HostControlToolSupportTests" \
  "Tools/HostControlToolSupport/HostControlToolSupport.swift" \
  "Tools/AstraHostControlTool/main.swift" \
  "Tests/HostControlToolSupportTests.swift"

assert_targets $'MCPGatewaySupportTests\nMCPServerKitTests\nMailToolSupportTests' \
  "Package.swift"

assert_targets "" \
  "Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift"

assert_targets "" \
  "ASTRAGitContracts/Sources/ASTRAGitContracts/GitStatusContracts.swift"

assert_targets "AppSemanticFitnessTests" \
  "Tests/AppSemanticFitnessTests.swift"

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

assert_targets $'RuntimeCancellationDiagnosticTests\nHeadlessChatScenarioTests\nFeedbackReportPresentationTests\nAgentRuntimeFailureDiagnosticsTests\nAgentRuntimeAdapterTests' \
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

assert_targets "" \
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

assert_targets $'AgentRuntimePipeCompletionTests\nStreamVolumeAccountingTests\nAgentExecutionScopedProcessTests\nAgentUtilityRuntimeTests\nProcessMonitorTests' \
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

assert_targets "StreamVolumeAccountingTests" "Tests/RuntimeProgressSignalTests.swift"

assert_targets $'TaskTextOnlyDeliverableTests\nTaskDeliverableExpectationTests\nDeliverableExpectationCoverageTests\nTaskDeliverableVerificationServiceTests\nTaskDeliverableFollowUpTests\nTaskExecutionResourceClaimResolverTests' \
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

assert_targets $'HostFileAccessBrokerTests\nShelfPreviewFailureTests\nShelfMarkdownAsyncLoadingTests' \
  "ASTRACore/HostFileAccessBroker.swift" \
  "Astra/Services/Browser/ShelfPreviewFailure.swift"

assert_targets $'TaskOutputDiscoveryTests\nAgentRuntimeRunPersistenceTests' \
  "Astra/Services/Persistence/TaskOutputDiscovery.swift"

assert_targets $'TaskOutputDiscoveryTests\nAgentRuntimeRunPersistenceTests\nRuntimeSettlementReviewRegressionTests\nWorkspaceSavedAutoExportTests\nWorkspaceSavedExportSnapshotTests\nWorkspaceSavedExportReviewTests\nWorkspaceSavedExportPendingTests\nWorkspaceSavedExportReplacementTests\nWorkspaceSnapshotDirectoryTests\nWorkspaceExportTerminationFlushTests\nTaskThreadChangeObserverTests' \
  "Astra/Services/Runtime/AgentRuntimeRunPersistence.swift"

assert_targets $'PendingP2RegressionTests\nSpecEngineTests\nAntigravityCLIRuntimeTests' \
  "Astra/Services/Tasks/TaskTitleGenerationService.swift" \
  "Astra/Services/Runtime/AntigravityCLIRuntime.swift"

assert_targets $'SwiftDataDeletionPreparationTests\nNewTaskWorktree\nPendingP2RegressionTests\nSpecEngineTests' \
  "Astra/Services/Tasks/TaskLifecycleCoordinator.swift"

assert_targets $'DiagnosticCoverageRegressionTests\nPendingP2RegressionTests\nLogDiagnosticsTests\nFeedbackEvidencePrivacyTests' \
  "Astra/Services/Diagnostics/LogDiagnosticsCollection.swift" \
  "Astra/Services/Diagnostics/LogDiagnosticsPreparationService.swift"

assert_targets $'CopilotCLICommandPlanningTests\nPendingP2RegressionTests' \
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
