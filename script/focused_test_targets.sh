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

  case "$path" in
    Astra/Views/TaskDecisionOutcomeRefresh.swift|Astra/Views/TaskMainViewDecisionOutcomes.swift|Astra/Views/TaskMainViewObservers.swift|Astra/Services/Validation/TaskDeliverableHistoryReader.swift|Tests/TaskDecisionOutcomeRefreshTests.swift|Tests/TaskDecisionOutcomeColdRefreshTests.swift)
      add_target "TaskDecisionOutcomeRefreshTests|TaskDecisionOutcomeColdRefreshTests|TaskDeliverableFollowUpTests|TaskDecisionDock|TaskMainActorScalingGateTests"
      ;;
    Astra/Views/WorkspaceRailOutputPresentation.swift|Astra/Views/WorkspaceRailSectionPresentation.swift|Astra/Views/WorkspaceRightRailView.swift|Tests/WorkspaceRailOutput*Tests.swift)
      add_target "WorkspaceRailOutputPresentationTests|WorkspaceRailOutputPerformanceTests|WorkspaceRailSectionPresentationTests|WorkspaceRightRailPerformanceTests"
      ;;
    Astra/Services/Runtime/ProviderSharedState*.swift|Astra/Services/Runtime/AgentRuntimeProcessRunner+SharedConfiguration.swift|Astra/Services/Runtime/AgentRuntimeSharedStateGate.swift|Astra/Services/Runtime/RuntimeProviderOwnershipReference.swift|Astra/Services/Runtime/RuntimeProviderResourceRegistry.swift|Tests/ProviderSharedState*Tests.swift|Tests/ProviderFixtureRecovery*.swift)
      add_target "ProviderSharedStateIdentityTests|ProviderSharedStateMigrationTests|ProviderSharedStateLaunchTests|ProviderSharedStateIsolationTests|ProviderFixtureRecoveryTests|antigravityEmptyRetryIgnoresEarlierArtifacts"
      ;;
  esac

  case "$path" in
    ASTRACore/ProviderToolSemantics.swift|ASTRACore/ProviderReadFileInput.swift|ASTRACore/AgentPolicyTypes.swift|Astra/Services/Runtime/AgentPolicyAdapters.swift|Astra/Services/Runtime/AgentRuntimePolicyGuard.swift|Tests/AntigravityReadFilePolicyTests.swift)
      add_target "AntigravityReadFilePolicyTests|AgentPolicyTests|AgentPolicyRuntimeMatrixTests|RuntimePolicyGuardTests|AntigravityCLIRuntimeTests"
      ;;
    Astra/Views/RuntimeLaunchPresentation.swift|Astra/Services/Runtime/RuntimeProviderStateWaitTimeout.swift|Astra/Services/Runtime/AgentRuntimeSharedStateGate.swift|Astra/Services/Runtime/ProviderSharedStateProcessLock.swift|Tests/RuntimeLaunchWaitTests.swift|Tests/RuntimeLaunchPresentationRegressionTests.swift|Tests/RuntimePreparationAccountingTests.swift|Tests/RuntimePreparationSettlementTests.swift)
      add_target "RuntimeLaunchWaitTests|RuntimeLaunchPresentationRegressionTests|RuntimePreparationAccountingTests|RuntimePreparationSettlementTests|TaskDecisionDockPresentationTests|RuntimeProviderRecordingLimitsTests|NativeResumeEmptyTurnTests|ImportedTaskHistoryIsolationTests"
      ;;
  esac

  case "$path" in
    ASTRACore/BinaryRunner.swift|ASTRACore/BinaryProcessGroupCompletion.swift|Astra/Services/Runtime/RuntimePrelaunchCancellation.swift|Astra/Services/Runtime/RuntimeCompletedUserTurnContinuation.swift|Astra/Services/Runtime/AntigravityLaunchPreparation.swift|Astra/Services/Runtime/AntigravityCLIRuntime.swift|Tests/RuntimeCancelledPreparationContinuationTests.swift|Tests/BinaryProcessGroupCompletionTests.swift)
      add_target "BinaryProcessGroupCompletionTests|ProcessBinaryRunnerTests|AntigravityLaunchPreparationTests|RuntimeCancelledPreparationContinuationTests|RuntimeCompletedUserTurnContinuationTests"
      ;;
  esac

  case "$path" in
    Astra/Services/Runtime/RuntimeWorkspaceContinuation*.swift|Astra/Views/TaskWorkspaceContinuationPrompt.swift|Tests/RuntimeWorkspaceContinuation*Tests.swift|Astra/Services/Runtime/RuntimeExecution*.swift|Astra/Services/Tasks/TaskQueue+ResourceAdmission.swift)
      add_target "RuntimeWorkspaceContinuation.*Tests|RuntimeCompletedUserTurnContinuationTests|RemoteWorkspaceJobPersistenceTests|TaskDecisionDock"
      ;;
  esac

  case "$path" in
    Astra/Services/Browser/ShelfBrowserOwner.swift|Astra/Services/Browser/ShelfBrowserBridgeRegistry.swift|Astra/Services/Browser/ShelfBrowserSession.swift|Astra/Services/Browser/ShelfSessionStores.swift|Astra/Services/Browser/ControlledBrowser*.swift|Astra/Views/ContentViewBrowserSessionPolicyCache.swift|Astra/Views/ShelfBrowserPanelView.swift|Tests/ShelfBrowserOwnershipTests.swift|Tests/ShelfBrowserLifetimeTests.swift|Tests/ControlledBrowserProfileLeaseTests.swift)
      add_target "ShelfBrowserOwnershipTests|ShelfBrowserLifetimeTests|ControlledBrowserProfileLeaseTests|BrowserBridgeSecurityTests|BrowserSessionPolicy|ShelfBrowserPanelLayoutTests|WorkspaceRightRailPerformanceTests"
      ;;
  esac

  case "$path" in
    Astra/Services/Runtime/NativeResumeEmptyTurnGate.swift|Tests/NativeResumeEmptyTurnTests.swift)
      add_target "NativeResumeEmptyTurnTests|RuntimeUsage"
      ;;
  esac

  case "$path" in
    ASTRACore/ClaudeSessionUsageSnapshot.swift|Astra/Services/Tasks/ClaudeSessionUsageEvidence.swift|Tests/ClaudeSessionUsageAccountingTests.swift|ASTRACore/AgentRuntimeTypes.swift|Astra/Services/Runtime/AgentProcessSupport.swift|Astra/Services/Tasks/AgentUsageMetadataRecorder.swift|ASTRACore/*StreamAccounting.swift|ASTRACore/ProviderUsageArithmetic.swift|ASTRACore/*StreamEventParser.swift|Astra/Models/TaskRequestBudget.swift|Astra/Services/Tasks/ProviderUsageEvidence.swift|Astra/Services/Tasks/ProviderSessionUsageEpoch.swift|Astra/Services/Tasks/AgentEventRecorder.swift|Astra/Services/Tasks/TaskThreadHistoryReader.swift|Astra/Views/TaskThreadSnapshot.swift|Astra/Services/Runtime/CopilotSessionMetricsReader.swift|Astra/Services/Runtime/CopilotCLIRuntimeAdapter+Session.swift|Astra/Services/Runtime/RuntimeTurnOutcomeService.swift|Astra/Services/Runtime/RuntimeTurnSettlementService.swift|Astra/Services/Runtime/AgentRuntimeWorker.swift|Astra/Services/Runtime/RuntimeExecutionOwner.swift|Astra/Services/Runtime/RuntimeExecutionAdmission.swift|Astra/Services/Runtime/AgentRuntimeProcessRunner.swift|Tests/RuntimeUsage*Tests.swift|Tests/RequestUsageBudgetTests.swift)
      add_target "ClaudeSessionUsageAccounting|claudeSessionSnapshotsAcrossRequests|RuntimeUsage|requestBudget|CumulativeSessionUsage|ProviderSessionUsageEpoch|CopilotSessionDiscovery|TaskThreadHistory|TaskThreadSnapshot|AntigravityStreamEventParser|OpenCodeStreamAccounting"
      ;;
  esac

  case "$path" in
    ASTRACore/CodexUsageHistory.swift|Astra/Services/Tasks/CodexSessionUsage*.swift|Astra/Services/Persistence/WorkspaceConfigManager+CodexUsageHistory.swift|Astra/Services/Tasks/WorkspaceImportOrchestrator.swift|Tests/CodexSessionUsageCorrection*.swift)
      add_target "CodexSessionUsageCorrection|CumulativeSessionUsage|ProviderSessionUsageEpoch|WorkspaceImportOrchestrator|RuntimeRecoveryOwnershipTests"
      return
      ;;
  esac

  case "$path" in
    Astra/Views/CapabilityPrerequisitePresentation.swift|ASTRACore/CLIPrerequisite.swift|ASTRACore/EnvironmentHealthChecker.swift|ASTRACore/GCloudCredentialProbe.swift|ASTRACore/PluginManifest.swift|ASTRACore/RepairAction.swift|Astra/Services/Capabilities/PluginRepairCoordinator.swift|Astra/Services/Runtime/CLISessionExpiryClassifier.swift|Astra/Services/Runtime/PreflightCache.swift|Astra/Resources/Capabilities/gcloud-workflow.json|Tests/CLIPrerequisiteSlowStartTests.swift)
      add_target "CLIPrerequisiteSlowStartTests|EnvironmentHealthCheckerTests|PreflightCacheTests|PluginManifestTests|PluginPackagePrereqTests|CapabilityHealthServiceTests|CapabilityRuntimeIntegrityServiceTests|PluginRepair|CLISessionExpiryTests"
      ;;
  esac

  case "$path" in
    ASTRACore/OpenCode*.swift|Astra/Services/Runtime/RuntimeStreamExecutionHints.swift|Astra/Services/Runtime/RuntimeCopilotFrameEvidence.swift|Astra/Services/Runtime/RuntimeUsageArithmetic.swift|Astra/Services/Runtime/RuntimeRecoveryPresentation.swift|Tests/RuntimeProvider*Tests.swift|Tests/RuntimeCleanupAuthorizationTests.swift|Tests/OpenCode*Tests.swift|Tests/Fixtures/ProviderStreams/*/recovery-captured-*.jsonl|Astra/Services/Runtime/RuntimeTemplateHookScope.swift|Tests/QueueLockTests.swift|Tests/RuntimeSettlementRecoveryFollowupTests.swift|Tests/LaunchSnapshotDisciplineTests.swift|Astra/Services/Tasks/TaskQueue*.swift|Astra/Services/Tasks/TaskWedgedWorkerLeaseReclaimer.swift|Astra/Services/Runtime/RuntimeExecution*.swift|Astra/Services/Runtime/RuntimeResourceOwnership.swift|Astra/Services/Runtime/RuntimeProvider*.swift|Astra/Services/Runtime/RuntimeUtilitySharedStateLease.swift|Astra/Services/Runtime/ProviderSharedStateProcessLock.swift|Astra/Services/Runtime/RuntimeSettlement*.swift|Astra/Services/Runtime/RuntimeFinalPlanSettlement.swift|Astra/Services/Runtime/RuntimeTurnOutcomeService.swift|Astra/Services/Runtime/AgentRuntimeSharedStateGate.swift|Astra/Services/Runtime/AgentRuntimeWorker.swift|Astra/Services/Runtime/AgentRuntimeProcessRunner.swift|Astra/Services/Runtime/AgentRuntimeAsyncWork.swift|Astra/Services/Runtime/AgentInteractivePermissionChannel.swift|Tests/Fixtures/ProviderStreams/*/cancellation-tool-free.jsonl|Tests/RuntimeCancellation*Tests.swift|Tests/RuntimeSettlementCancellationTests.swift|Tests/TaskQueueWedgedWorkerReleaseTests.swift)
      add_target "RuntimeCancellation|RuntimeSettlementCancellationTests|TaskQueueWedgedWorkerReleaseTests|RuntimeTurnSettlementTests|LaunchSnapshotDisciplineTests|QueueLockTests|RuntimeSettlementRecoveryFollowupTests|RuntimeProvider|RuntimeCleanupAuthorizationTests|OpenCode"
      ;;
  esac

  case "$path" in
    Astra/Services/Runtime/RuntimeRecovery*.swift|Astra/Services/Runtime/RuntimeExecution*.swift|Tests/RuntimeRecovery*Tests.swift)
      add_target "RuntimeRecovery"
      add_target "RuntimeSupervision"
      return
      ;;
    Astra/Services/Runtime/RuntimeSupervision*.swift|Astra/Services/Runtime/ClaudeCodeUtilityLaunchPolicy.swift|Astra/Services/Runtime/ClaudeObservationAuthentication.swift|Astra/Services/Runtime/AgentUtilityRuntime.swift|Astra/Services/Runtime/AgentUtilityExecutionLimits.swift|Astra/Services/Runtime/AgentProcessProgressClassification.swift|Astra/Services/Runtime/AgentProcessSupport.swift|Tests/RuntimeSupervision*Tests.swift)
      add_target "RuntimeSupervision"
      add_target "ProcessMonitorTests"
      ;;
  esac

  if [[ "$path" == "Package.swift" ]]; then
    add_target "MCPGatewaySupportTests"
    add_target "MCPServerKitTests"
    add_target "MailToolSupportTests"
    return
  fi

  case "$path" in
    Tests/CapabilityResolutionTestSupport.swift|Tests/CapabilityInstallerTests.swift|Tests/PluginActivationMigrationTests.swift|Tests/PluginActivationOwnershipTests.swift|Tests/PluginPromptScopeParityTests.swift|Tests/RoutineSkillSelectionTests.swift)
      add_target "CapabilityInstallerTests|CapabilityResolutionInputsTests|PluginActivationMigrationTests|PluginActivationOwnershipTests|PluginPromptScopeParityTests|RoutineSkillSelectionTests"
      ;;
    Tests/ArchitectureFitnessTests/*)
      ;;
    Tests/AppSemanticFitnessTests.swift)
      add_target "AppSemanticFitnessTests"
      ;;
    Astra/Services/Persistence/TaskContextEventIndex.swift|Astra/Services/Persistence/TaskContextStateManager.swift|Astra/Services/Persistence/TaskActiveObjectiveResolver.swift|Astra/Models/TaskCorrectiveWorkQueries.swift|Tests/TaskContextEventIndexTests.swift|Tests/TaskContextDerivationPerformanceTests.swift|Tests/TaskContextStateOffMainRefreshTests.swift)
      add_target "TaskContextEventIndexTests|TaskContextState|TaskPlanServiceTests"
      add_target "TaskHistoryReadTests|TaskMainActorScalingGateTests"
      add_target "TaskAttachmentFilesReaderTests|ShelfAttachmentHistoryTests"
      add_target "requestBudget"
      ;;
    Tests/TaskMainActorScalingGateTests.swift|Tests/TaskHistoryReadTests.swift|Astra/Models/TaskHistoryRead.swift|Astra/Services/Tasks/TaskConversationContinuationService.swift|Astra/Services/Tasks/TaskExecutionLaunchSnapshotApplicator.swift|Astra/Services/Runtime/TaskRuntimePermissionGrants.swift)
      add_target "TaskMainActorScalingGateTests"
      add_target "TaskHistoryReadTests"
      add_target "TaskExecutionLaunchSnapshotApplicatorTests"
      add_target "RuntimePermissionGrantRegressionTests"
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
    Astra/Services/Runtime/RuntimeHomeAccess*.swift|Astra/Services/Runtime/RuntimeAccessACL.swift|Astra/Services/Runtime/CopilotHomeAccessCheck.swift|Astra/Services/Runtime/AgentRuntimeProcessRunner+HomeAccessGuard.swift|Astra/Services/Runtime/AgentRuntimeHomeStateAccess.swift|Astra/Services/Runtime/RuntimeReadinessService.swift|Astra/Services/Runtime/RuntimeProviderAvailabilityService.swift|Astra/Services/Runtime/AgentRuntimeAdapter.swift|Astra/Services/Runtime/ExecutionEnvironment.swift|AstraObjCSupport/AstraMembership.m|Tests/RuntimeHomeAccess*Tests.swift|Tests/CopilotHomeAccessCheckTests.swift|Tests/PermissionRepairCommandClient.swift|Tests/PermissionRepairCommandClientTests.swift|script/swift_test.sh|script/permission_repair_test_harness*.py|Astra/Services/Runtime/ProviderNativeSessionStore.swift|Tests/NativeContinuationFallbackTests.swift|Tests/ExecutionSandboxRunnerTests.swift|Tests/RuntimeReadinessStateCacheTests.swift|Tests/RuntimeLaunchReadinessCacheTests.swift|Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift)
      add_target "RuntimeHomeAccessTests"
      add_target "RuntimeHomeAccessEdgeCaseTests"
      add_target "RuntimeHomeAccessAdditionalStateTests"
      add_target "NativeContinuationFallbackTests"
      add_target "ExecutionSandboxRunnerTests"
      add_target "CopilotHomeAccessCheckTests"
      add_target "PermissionRepairCommandClientTests"
      add_target "RuntimeReadinessServiceTests"
      add_target "RuntimeReadinessStateCacheTests"
      add_target "RuntimeLaunchReadinessCacheTests"
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
    Astra/Services/Browser/ShelfSessionStores.swift|Tests/ShelfFilesOwnershipTests.swift)
      add_target "ShelfFilesOwnershipTests|ShelfMarkdownSessionTests|ShelfMarkdownAsyncLoadingTests"
      ;;
    Astra/Services/Tasks/TaskAttachmentFilesReader.swift|Astra/Services/Tasks/TaskHeaderFilesReader.swift|Tests/TaskAttachmentFilesReaderTests.swift)
      add_target "TaskAttachmentFilesReaderTests"
      add_target "ComposerAttachmentsTests"
      ;;
    Astra/Views/ShelfAttachmentHistoryModifier.swift|Tests/ShelfAttachmentHistoryTests.swift)
      add_target "ShelfAttachmentHistoryTests"
      add_target "TaskAttachmentFilesReaderTests"
      ;;
    Tests/HeadlessChatProcessScenarioTests.swift|Tests/RuntimeCancellationDiagnosticTests.swift|Astra/Services/Runtime/AgentRuntimeWorker.swift|Astra/Services/Runtime/CopilotPostFailureHomeInspection.swift|Tests/CopilotPostFailureHomeInspectionTests.swift)
      add_target "RuntimeCancellationDiagnosticTests"
      add_target "HeadlessChatScenarioTests"
      add_target "FeedbackReportPresentationTests"
      add_target "CopilotPostFailureHomeInspectionTests"
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
    Astra/Services/Runtime/CopilotCLIRuntime.swift|Astra/Services/Runtime/CopilotCapabilityProbe.swift|Astra/Services/Runtime/CopilotCapabilityResolution.swift|Astra/Services/Runtime/CopilotCLIRuntimeAdapter+Readiness.swift|Tests/CopilotCLICapabilityProbeTests.swift|Tests/CopilotLaunchDiscoveryTests.swift|Tests/CopilotDiscoveryAdmissionTests.swift|Tests/CopilotCapabilityFlightDeadlineTests.swift)
      add_target "CopilotCLICommandPlanningTests"
      add_target "CopilotCLICapabilityProbeTests"
      add_target "CopilotWorkerExecutionTests"
      add_target "CopilotLaunchDiscoveryTests"
      add_target "CopilotDiscoveryAdmissionTests"
      add_target "CopilotCapabilityFlightDeadlineTests"
      add_target "AgentUtilityRuntimeTests"
      add_target "AgentRuntimeCapabilityProfileTests"
      add_target "RuntimeReadinessServiceTests"
      add_target "PendingP2RegressionTests"
      ;;
    Tests/AgentRuntimeAdapterCopilotFixture.swift)
      add_target "AgentRuntimeAdapterTests"
      add_target "NativeContinuationFallbackTests"
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
      add_target "ShelfMarkdownAsyncLoadingTests|ShelfFilesOwnershipTests"
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
    Astra/Services/Runtime/AgentRuntimeProcessRunner.swift|Astra/Services/Runtime/AgentUtilityScopedProcessRunState.swift|Astra/Services/Runtime/AgentProcessPipeReader.swift|Astra/Services/Runtime/AgentExecutionScopedProcess.swift|Tests/AgentRuntimePipeCompletionTests.swift|Tests/AgentExecutionScopedProcessTests.swift|ASTRACore/ProcessGroupSpawn.swift|ASTRACore/ProcessWaitExecutor.swift|Tests/ProcessWaitExecutorTests.swift|ASTRACore/BinaryRunner.swift|Tests/ProcessDescriptorIsolationTests.swift|Tests/BinaryRunnerTests.swift)
      add_target "AgentRuntimePipeCompletionTests"
      add_target "StreamVolumeAccountingTests"
      add_target "AgentExecutionScopedProcessTests"
      add_target "RuntimeRecovery"
      add_target "AgentUtilityRuntimeTests"
      add_target "ProcessMonitorTests"
      add_target "ProcessWaitExecutorTests|ProcessDescriptorIsolationTests|ProcessBinaryRunnerTests|SpawnedChildSignalStateTests|OpenCodeRunnerCompletionTests|OpenCodeCompletionProofTests|HostControlParentDeathSupervisorTests"
      ;;
    ASTRACore/RuntimeProgressSignals.swift|Tests/RuntimeProgressSignalTests.swift)
      add_target "StreamVolumeAccountingTests"
      add_target "RuntimeProgressClassificationTests"
      add_target "WatchdogEscalationTests"
      add_target "RuntimeStreamReplayTests"
      add_target "CodexFileChangeProgressTests"
      ;;
    ASTRACore/CodexStreamEventParser.swift|Astra/Services/Runtime/CodexCLIRuntime.swift|Tests/CodexCLIRuntimeTests.swift|Tests/CodexFileChangeProgressTests.swift)
      add_target "CodexCLIRuntimeTests"
      add_target "ProviderMessageIdentityTests"
      add_target "AgentEventRecorderTests"
      add_target "ProviderTranscriptConformanceTests"
      add_target "RuntimeProgressClassificationTests"
      add_target "WatchdogEscalationTests"
      add_target "CodexFileChangeProgressTests"
      ;;
    Astra/Services/Runtime/AgentPromptBuilder.swift|Astra/Services/Runtime/TaskInputManifest.swift|Astra/Services/Runtime/TaskInputsPromptSectionProvider.swift|Astra/Services/Tasks/PromptContextSectionProvider.swift|Astra/Views/PromptContextPreviewView.swift|Tests/TaskInputContinuityPromptTests.swift|Tests/AgentRuntimeWorkerTests.swift)
      add_target "TaskInputContinuityPromptTests"
      add_target "BuildPromptTests"
      add_target "AgentRuntimeAttachmentProjectionTests"
      add_target "RuntimeAttachmentPolicyRegressionTests"
      add_target "PromptContextPreviewPresentationTests"
      ;;
    Astra/Services/Validation/TaskDeliverableExpectation.swift|Astra/Services/Validation/StandaloneArtifactRequestPolicy.swift|Astra/Services/Tasks/TaskIntentLanguagePolicy.swift|Tests/TaskTextOnlyDeliverableTests.swift)
      add_target "TaskDecisionOutcomeColdRefreshTests"
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
    Tests/HostControlToolSupportTests.swift|Tests/HostControlParentDeathSupervisorTests.swift|Tools/AstraHostControlTool/*|Tools/HostControlToolSupport/*)
      add_target "HostControlToolSupportTests"
      add_target "ProcessWaitExecutorTests|ProcessDescriptorIsolationTests|SpawnedChildSignalStateTests|HostControlParentDeathSupervisorTests"
      ;;
    ASTRACore/SSHKnownHostsOption.swift|Tests/BrowserToolShimTests.swift)
      add_target "BrowserToolShimTests"
      ;;
    Tests/RemoteWorkspaceJob*.swift|Tools/WorkspaceToolSupport/RemoteWorkspaceJob*.swift|Tools/AstraWorkspaceJobTool/*|Astra/Services/Runtime/RemoteWorkspaceJob*.swift|Astra/Views/RemoteWorkspaceJob*.swift|Astra/Services/Runtime/RemoteWorkspaceSSHRoute.swift|Astra/Services/Runtime/RemoteWorkspacePromptGuidance.swift)
      add_target "RemoteWorkspaceJobTests"
      add_target "RemoteWorkspaceJobShimTests"
      add_target "RemoteWorkspaceJobSafetyTests"
      add_target "RemoteWorkspaceJobPersistenceTests"
      add_target "RemoteWorkspaceJobBundlingTests"
      add_target "RemoteWorkspaceJobOutputStateTests"
      add_target "RemoteWorkspaceSSHRouteTests"
      add_target "RemoteWorkspacePromptGuidanceTests"
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
