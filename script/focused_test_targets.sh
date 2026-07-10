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
    add_target "ArchitectureFitnessTests.ArchitectureFitnessTests"
    add_target "MCPGatewaySupportTests"
    add_target "MCPServerKitTests"
    add_target "MailToolSupportTests"
    return
  fi

  case "$path" in
    Tests/ArchitectureFitnessTests/*)
      add_target "ArchitectureFitnessTests.ArchitectureFitnessTests"
      ;;
    Tests/AppSemanticFitnessTests.swift)
      add_target "AppSemanticFitnessTests"
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
      ;;
    Astra/Services/Persistence/FeedbackOutboxService.swift|Astra/Services/Persistence/FeedbackOutboxTypes.swift)
      add_target "FeedbackReportPresentationTests"
      add_target "FeedbackOutboxStateMachineTests"
      ;;
    Astra/ASTRAApp.swift|Astra/Views/ContentView.swift|Astra/Views/LogViewerView.swift)
      add_target "FeedbackReportPresentationTests"
      add_target "FeedbackCrashRecoveryTests"
      ;;
    Tests/TaskDecisionDockPresentationTests.swift|Astra/Services/Tasks/TaskDecisionDockContextBuilder.swift|Astra/Services/Tasks/TaskDecisionDockPresentation.swift|Astra/Views/TaskDecisionDockView.swift|Astra/Views/TaskMainView.swift)
      add_target "TaskDecisionDockPresentationTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Tests/HeadlessChatProcessScenarioTests.swift|Astra/Services/Runtime/AgentRuntimeWorker.swift)
      add_target "HeadlessChatScenarioTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Astra/Services/Diagnostics/AgentRuntimeDiagnostics.swift)
      add_target "AgentRuntimeFailureDiagnosticsTests"
      add_target "FeedbackReportPresentationTests"
      ;;
    Tests/AgentRuntimeAdapterTests.swift|Astra/Services/Runtime/ProviderMessages.swift)
      add_target "AgentRuntimeAdapterTests"
      add_target "FeedbackReportPresentationTests"
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
  esac
}

for path in "$@"; do
  target_for_path "$path"
done

if ((${#selected_targets[@]} > 0)); then
  printf '%s\n' "${selected_targets[@]}"
fi
