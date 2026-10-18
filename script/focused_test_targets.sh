#!/usr/bin/env bash
set -euo pipefail

selected_targets=()

add_target() {
  local target="$1"
  local selected

  if ((${#selected_targets[@]} > 0)); then
    for selected in "${selected_targets[@]}"; do
      [[ "$selected" == "$target" ]] && return 0
    done
  fi

  selected_targets+=("$target")
}

target_for_path() {
  local path="$1"

  if [[ "$path" == "Package.swift" ]]; then
    add_target "MCPGatewaySupportTests"
    add_target "MCPServerKitTests"
    add_target "MailToolSupportTests"
    return
  fi

  case "$path" in
    Tests/ArchitectureFitnessTests/*)
      ;;
    Tests/AppSemanticFitnessTests.swift)
      add_target "AppSemanticFitnessTests"
      ;;
    Astra/Services/Persistence/SSHConnectionManager.swift|Astra/Services/Persistence/WorkspaceAutoExportWriter.swift|Astra/Services/Persistence/WorkspaceConfigManager.swift|Astra/Services/Persistence/WorkspacePersistenceCoordinator.swift|Astra/Services/Persistence/WorkspacePersistenceWork.swift|Astra/Services/Persistence/WorkspaceSavedAutoExport.swift|Astra/Services/Persistence/WorkspaceSavedExportSnapshot.swift|Astra/Services/Persistence/WorkspaceExportChangeScope.swift|Astra/Services/Persistence/WorkspaceSavedExportLease.swift|Astra/Services/Persistence/WorkspaceSnapshotDirectory.swift|Tests/WorkspaceSavedExportPendingTests.swift|Tests/WorkspaceSavedExportReplacementTests.swift|Tests/WorkspaceSnapshotDirectoryTests.swift|Tests/WorkspaceSavedExportSnapshotTests.swift|Tests/WorkspaceSavedAutoExportTests.swift|Tests/WorkspaceSavedExportReviewTests.swift|Tests/WorkspaceExportTerminationFlushTests.swift|Tests/RunFinalizationResponsivenessTests.swift|Tests/RuntimeSettlementReviewRegressionTests.swift)
      add_target "RuntimeSettlementReviewRegressionTests"
      add_target "WorkspaceSavedAutoExportTests"
      add_target "WorkspaceSavedExportSnapshotTests"
      add_target "WorkspaceSavedExportReviewTests"
      add_target "WorkspaceSavedExportPendingTests"
      add_target "WorkspaceSavedExportReplacementTests"
      add_target "WorkspaceSnapshotDirectoryTests"
      add_target "WorkspaceExportTerminationFlushTests"
      add_target "AgentRuntimeRunPersistenceTests"
      add_target "TaskThreadChangeObserverTests"
      ;;
    Astra/Services/Persistence/SwiftDataTaskRollbackPreparation.swift|Astra/Services/Git/GitHubReviewPublicationService.swift|Tests/GitHubReviewPublicationTests.swift)
      add_target "GitHubReviewPublicationTests"
      add_target "SwiftDataDeletionPreparationTests"
      ;;
    Astra/Services/Runtime/RuntimeHomeAccess*.swift|Astra/Services/Runtime/RuntimeAccessACL.swift|Astra/Services/Runtime/CopilotHomeAccessCheck.swift|Astra/Services/Runtime/AgentRuntimeProcessRunner+HomeAccessGuard.swift|Astra/Services/Runtime/AgentRuntimeHomeStateAccess.swift|Astra/Services/Runtime/RuntimeReadinessService.swift|Astra/Services/Runtime/RuntimeProviderAvailabilityService.swift|Astra/Services/Runtime/AgentRuntimeAdapter.swift|Astra/Services/Runtime/ExecutionEnvironment.swift|AstraObjCSupport/AstraMembership.m|Tests/RuntimeHomeAccessTests.swift|Tests/CopilotHomeAccessCheckTests.swift)
      add_target "RuntimeHomeAccessTests"
      add_target "CopilotHomeAccessCheckTests"
      add_target "RuntimeReadinessServiceTests"
      add_target "AgentRuntimeAdapterTests"
      add_target "ExecutionEnvironmentTests"
      ;;
    Tests/RuntimeFeedbackSnapshotTests.swift|Astra/Services/Feedback/RuntimeFeedbackSnapshotBuilder.swift)
      add_target "RuntimeFeedbackSnapshotTests"
      add_target "FeedbackEvidencePrivacyTests"
      ;;
    Tests/FeedbackCrashRecoveryTests.swift|Astra/Services/Feedback/FeedbackCrashOfferService.swift|Astra/Services/Feedback/FeedbackCrashLaunchMonitor.swift)
      add_target "FeedbackCrashRecoveryTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Models/AppStorageKeys.swift)
      add_target "FeedbackReportPresentationTests"
      add_target "FeedbackCrashRecoveryTests"
      ;;
    Tests/FeedbackReportPresentationTests.swift|Tests/FeedbackReportPresentationLifecycleTests.swift|Astra/Services/Feedback/FeedbackReportPreparationService.swift|Astra/Services/Feedback/FeedbackPreparationStagingReconciler.swift|Astra/Services/Feedback/FeedbackReportRouting.swift|Astra/Views/Feedback/*)
      add_target "FeedbackReportPresentationTests"
      add_target "FeedbackEvidencePrivacyTests"
      add_target "RuntimeFeedbackSnapshotTests"
      add_target "FeedbackOutboxStateMachineTests"
      add_target "FeedbackManualExportTests"
      ;;
    Tests/FeedbackReportContractTests.swift|ASTRACore/Feedback/FeedbackReportContract.swift|ASTRACore/Feedback/FeedbackReportStatus.swift|ASTRACore/Feedback/FeedbackContractSupport.swift)
      add_target "FeedbackReportContractTests"
      add_target "FeedbackEvidencePrivacyTests"
      add_target "FeedbackOutboxStateMachineTests"
      ;;
    Tests/FeedbackAssessmentPolicyTests.swift|ASTRACore/Feedback/FeedbackAssessmentContract.swift|ASTRACore/FeedbackAssessmentValidation.swift|ASTRACore/FeedbackPriorityPolicy.swift)
      add_target "FeedbackReportContractTests"
      add_target "FeedbackAssessmentPolicyTests"
      ;;
    Astra/Services/Persistence/FeedbackPackageAdoptionValidator.swift|Astra/Services/Persistence/FeedbackEvidenceArchiveValidator.swift|Astra/Services/Persistence/FeedbackPackageRemoval.swift)
      add_target "FeedbackOutboxStateMachineTests"
      add_target "FeedbackEvidencePrivacyTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Services/Persistence/FeedbackOutboxService.swift|Astra/Services/Persistence/FeedbackOutboxTypes.swift)
      add_target "FeedbackReportPresentationTests"
      add_target "FeedbackOutboxStateMachineTests"
      add_target "FeedbackManualExportTests"
      ;;
    Tests/FeedbackManualExportTests.swift|Astra/Services/Feedback/FeedbackManualExportService.swift)
      add_target "FeedbackManualExportTests"
      ;;
    Astra/ASTRAApp.swift|Astra/Views/ContentView.swift|Astra/Views/LogViewerView.swift)
      add_target "FeedbackReportPresentationTests"
      add_target "FeedbackCrashRecoveryTests"
      ;;
    Astra/Views/TaskMainView.swift)
      add_target "TaskDecisionDockPresentationTests"
      add_target "FeedbackReportPresentationTests"
      add_target "ComposerAttachmentsTests"
      add_target "TaskInputContinuityPromptTests"
      add_target "TaskAttachmentFilesReaderTests"
      ;;
    Tests/TaskDecisionDockPresentationTests.swift|Astra/Services/Tasks/TaskDecisionDockContextBuilder.swift|Astra/Services/Tasks/TaskDecisionDockPresentation.swift|Astra/Views/TaskDecisionDockView.swift)
      add_target "TaskDecisionDockPresentationTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Views/TaskInputFileMetadata.swift|Astra/Views/Components/TaskFilesPopoverView.swift|Astra/Views/Components/TaskInputFilesView.swift|Tests/ComposerAttachmentsTests.swift)
      add_target "ComposerAttachmentsTests"
      add_target "TaskInputContinuityPromptTests"
      add_target "TaskAttachmentFilesReaderTests"
      ;;
    Astra/Services/Tasks/TaskAttachmentFilesReader.swift|Tests/TaskAttachmentFilesReaderTests.swift)
      add_target "TaskAttachmentFilesReaderTests"
      add_target "ComposerAttachmentsTests"
      ;;
    Astra/Views/ShelfAttachmentHistoryModifier.swift|Tests/ShelfAttachmentHistoryTests.swift)
      add_target "ShelfAttachmentHistoryTests"
      add_target "TaskAttachmentFilesReaderTests"
      ;;
    Tests/HeadlessChatProcessScenarioTests.swift|Tests/RuntimeCancellationDiagnosticTests.swift|Astra/Services/Runtime/AgentRuntimeWorker.swift)
      add_target "RuntimeCancellationDiagnosticTests"
      add_target "HeadlessChatScenarioTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Services/Diagnostics/AgentRuntimeDiagnostics.swift)
      add_target "AgentRuntimeFailureDiagnosticsTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Services/Diagnostics/LogDiagnostics*.swift|Astra/Services/Diagnostics/DiagnosticPerformancePolicy.swift|Tests/DiagnosticCoverageRegressionTests.swift|Astra/Services/Diagnostics/PersistedLogEntryParser.swift)
      add_target "DiagnosticCoverageRegressionTests"
      add_target "PendingP2RegressionTests"
      add_target "LogDiagnosticsTests"
      add_target "FeedbackEvidencePrivacyTests"
      ;;
    Astra/Services/Runtime/CopilotCLIRuntime.swift)
      add_target "CopilotCLICommandPlanningTests"
      add_target "PendingP2RegressionTests"
      ;;
    Astra/Services/Tasks/TaskTitleGenerationService.swift|Astra/Services/Tasks/SpecEngine.swift|Astra/Services/Runtime/AntigravityCLIRuntime.swift|Astra/Services/Diagnostics/CopilotStartupEvidence.swift|Tests/PendingP2RegressionTests.swift)
      add_target "PendingP2RegressionTests"
      add_target "SpecEngineTests"
      add_target "AntigravityCLIRuntimeTests"
      ;;
    Astra/Services/Tasks/TaskLifecycleCoordinator.swift)
      add_target "SwiftDataDeletionPreparationTests"
      add_target "NewTaskWorktree"
      add_target "PendingP2RegressionTests"
      add_target "SpecEngineTests"
      ;;
    ASTRACore/HostFileAccessBroker.swift|Astra/Services/Browser/ShelfPreviewFailure.swift|Astra/Services/Browser/ShelfMarkdownSession.swift|Tests/ShelfPreviewFailureTests.swift)
      add_target "HostFileAccessBrokerTests"
      add_target "ShelfPreviewFailureTests"
      add_target "ShelfMarkdownAsyncLoadingTests"
      ;;
    Astra/Services/Runtime/AgentRuntimeRunPersistence.swift|Astra/Services/Persistence/TaskOutputDiscovery.swift)
      add_target "TaskOutputDiscoveryTests"
      add_target "AgentRuntimeRunPersistenceTests"
      ;;
    Astra/Services/Diagnostics/CrashDiagnosticsService.swift)
      add_target "LogDiagnosticsTests"
      add_target "FeedbackEvidencePrivacyTests"
      add_target "FeedbackCrashRecoveryTests"
      ;;
    Tests/AgentRuntimeAdapterTests.swift|Astra/Services/Runtime/ProviderMessages.swift|Astra/Services/Runtime/CopilotRuntimeLaunchSupport.swift)
      add_target "AgentRuntimeAdapterTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Services/Runtime/CodexMCPLaunchProjection.swift|Tests/CodexMCPConfigRendererTests.swift)
      add_target "CodexMCPConfigRendererTests"
      add_target "MCPRuntimeProjectionTests"
      ;;
    Astra/Views/ShelfFileIndexController.swift|Astra/Views/ShelfAttachmentRootResolver.swift|Tests/ShelfFileIndexControllerTests.swift|Astra/Services/Diagnostics/UIResponsivenessDiagnostics.swift|Astra/Services/Diagnostics/FilesShelfResponsivenessTelemetry.swift)
      add_target "ShelfFileIndexControllerTests"
      add_target "FilesShelfResponsivenessTelemetryTests"
      add_target "UIResponsivenessDiagnosticsTests"
      add_target "ShelfAttachmentHistoryTests"
      ;;
    Astra/Views/ShelfFileNavigatorPresentation.swift|Astra/Views/ShelfMarkdownPanelView.swift|Tests/ShelfMarkdownPanelLayoutTests.swift)
      add_target "ShelfMarkdownPanelLayoutTests"
      add_target "ShelfChromeTests"
      add_target "TaskAttachmentFilesReaderTests"
      add_target "ShelfAttachmentHistoryTests"
      ;;
    Astra/Views/SidebarTask*.swift|Astra/Views/TaskSidebarView.swift|Tests/SidebarTaskStore*.swift|Tests/SidebarTaskSourceObservationTests.swift)
      add_target "SidebarTaskStoreTests"
      add_target "SidebarTaskStoreSignalIntegrationTests"
      add_target "SidebarTaskSourceObservationTests"
      ;;
    Astra/Services/Runtime/AgentRuntimeProcessRunner.swift|Astra/Services/Runtime/AgentProcessPipeReader.swift|Astra/Services/Runtime/AgentExecutionScopedProcess.swift|Tests/AgentRuntimePipeCompletionTests.swift|Tests/AgentExecutionScopedProcessTests.swift)
      add_target "AgentRuntimePipeCompletionTests"
      add_target "StreamVolumeAccountingTests"
      add_target "AgentExecutionScopedProcessTests"
      add_target "AgentUtilityRuntimeTests"
      add_target "ProcessMonitorTests"
      ;;
    Tests/RuntimeProgressSignalTests.swift)
      add_target "StreamVolumeAccountingTests"
      ;;
    Astra/Services/Runtime/AgentPromptBuilder.swift|Astra/Services/Runtime/TaskInputManifest.swift|Astra/Services/Runtime/TaskInputsPromptSectionProvider.swift|Astra/Services/Tasks/PromptContextSectionProvider.swift|Astra/Views/PromptContextPreviewView.swift|Tests/TaskInputContinuityPromptTests.swift|Tests/AgentRuntimeWorkerTests.swift)
      add_target "TaskInputContinuityPromptTests"
      add_target "BuildPromptTests"
      add_target "AgentRuntimeAttachmentProjectionTests"
      add_target "RuntimeAttachmentPolicyRegressionTests"
      add_target "PromptContextPreviewPresentationTests"
      ;;
    Astra/Services/Validation/TaskDeliverableExpectation.swift|Astra/Services/Validation/StandaloneArtifactRequestPolicy.swift|Astra/Services/Tasks/TaskIntentLanguagePolicy.swift|Tests/TaskTextOnlyDeliverableTests.swift)
      add_target "TaskTextOnlyDeliverableTests"
      add_target "TaskDeliverableExpectationTests"
      add_target "DeliverableExpectationCoverageTests"
      add_target "TaskDeliverableVerificationServiceTests"
      add_target "TaskDeliverableFollowUpTests"
      add_target "TaskExecutionResourceClaimResolverTests"
      ;;
    Astra/Views/UsageDashboard*.swift|Tests/UsageDashboard*.swift|Tests/LargeHistoryResponsivenessTests.swift)
      add_target "UsageDashboardStoreTests"
      add_target "UsageDashboardRenderingTests"
      ;;
    Astra/Services/Settings/AppUpdateSafety.swift|Tests/RunningTaskCountPredicateTests.swift)
      add_target "RunningTaskCountPredicateTests"
      ;;
    Astra/Services/Persistence/OrphanedV12StoreMigrator.swift|Tests/OrphanedV12StoreMigratorTests.swift)
      add_target "OrphanedV12StoreMigratorTests"
      ;;
    Astra/Services/Persistence/SwiftDataDeletionPreparation.swift|Astra/Services/Tasks/TaskWorktreeService.swift|Tests/SwiftDataDeletionPreparationTests.swift|Tests/NewTaskWorktree*.swift)
      add_target "SwiftDataDeletionPreparationTests"
      add_target "NewTaskWorktree"
      ;;
    Tests/FeedbackEvidencePrivacyTests.swift|Astra/Services/Feedback/*)
      add_target "FeedbackEvidencePrivacyTests"
      ;;
    Tests/MCPGatewaySupportTests/*|Tools/AstraMCPGatewayTool/*|Tools/MCPGatewaySupport/*)
      add_target "MCPGatewaySupportTests"
      ;;
    Tests/MCPServerKitTests/*|Tools/MCPServerKit/*)
      add_target "MCPServerKitTests"
      ;;
    Tests/MailToolSupportTests/*|Tools/MailToolSupport/*|Tools/StanfordAppleMailTool/*|Tools/StanfordGraphMailTool/*|Tools/StanfordMailTool/*)
      add_target "MailToolSupportTests"
      ;;
    Tests/HostControlToolSupportTests.swift|Tools/AstraHostControlTool/*|Tools/HostControlToolSupport/*)
      add_target "HostControlToolSupportTests"
      ;;
    .github/workflows/release.yml|script/build_and_run.sh|Tests/ReleaseBuildNumberDerivationTests.swift)
      # These three paths co-derive/co-verify the release build-number
      # scheme (PR #253 review comment 3549627108): release.yml's
      # "Determine release version and build" step and
      # default_app_build() in build_and_run.sh must stay byte-for-byte
      # in sync, and ReleaseBuildNumberDerivationTests reads both files
      # fresh from disk to prove it. Both required gates
      # (script/prepush.sh, which this file feeds, and the release
      # workflow's own "Run release test gate" step, which also runs
      # prepush.sh) would otherwise be able to skip this regression suite
      # entirely on a change to any of the three. AppBundlePackagingTests
      # also reads build_and_run.sh directly, so pull it in alongside the
      # other release-path suite for the same reason.
      add_target "ReleaseBuildNumberDerivationTests"
      add_target "ReleaseUpdateScriptTests"
      add_target "AppBundlePackagingTests"
      ;;
  esac

  case "$path" in
    Astra/Services/Runtime/AgentRuntimeRunPersistence.swift)
      add_target "RuntimeSettlementReviewRegressionTests"
      add_target "WorkspaceSavedAutoExportTests"
      add_target "WorkspaceSavedExportSnapshotTests"
      add_target "WorkspaceSavedExportReviewTests"
      add_target "WorkspaceSavedExportPendingTests"
      add_target "WorkspaceSavedExportReplacementTests"
      add_target "WorkspaceSnapshotDirectoryTests"
      add_target "WorkspaceExportTerminationFlushTests"
      add_target "TaskThreadChangeObserverTests"
      ;;
  esac

  case "$path" in
    Astra/Views/ContentView.swift|Astra/Views/WorkspaceCanvasItem.swift|Tests/PanelLayoutGeometryTests.swift|Tests/WorkspaceRightPanelLayoutTests.swift)
      add_target "WorkspaceRightPanelLayoutTests"
      add_target "PanelLayoutGeometryTests"
      ;;
  esac
}

for path in "$@"; do
  target_for_path "$path"
done

if ((${#selected_targets[@]} > 0)); then
  printf '%s\n' "${selected_targets[@]}"
fi
