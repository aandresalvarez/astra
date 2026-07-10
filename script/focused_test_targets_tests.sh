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

assert_targets $'ArchitectureFitnessTests.ArchitectureFitnessTests\nMCPGatewaySupportTests\nMCPServerKitTests\nMailToolSupportTests' \
  "Package.swift"

assert_targets "ArchitectureFitnessTests.ArchitectureFitnessTests" \
  "Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift"

assert_targets "AppSemanticFitnessTests" \
  "Tests/AppSemanticFitnessTests.swift"

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

assert_targets $'FeedbackReportPresentationTests\nFeedbackEvidencePrivacyTests\nRuntimeFeedbackSnapshotTests\nFeedbackOutboxStateMachineTests' \
  "Astra/Services/Feedback/FeedbackReportPreparationService.swift" \
  "Astra/Services/Feedback/FeedbackPreparationStagingReconciler.swift" \
  "Astra/Views/Feedback/FeedbackReportView.swift" \
  "Tests/FeedbackReportPresentationTests.swift"

assert_targets $'FeedbackCrashRecoveryTests\nFeedbackReportPresentationTests' \
  "Astra/Services/Feedback/FeedbackCrashOfferService.swift" \
  "Astra/Services/Feedback/FeedbackCrashLaunchMonitor.swift" \
  "Tests/FeedbackCrashRecoveryTests.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackOutboxStateMachineTests' \
  "Astra/Services/Persistence/FeedbackOutboxService.swift"

assert_targets $'TaskDecisionDockPresentationTests\nFeedbackReportPresentationTests' \
  "Tests/TaskDecisionDockPresentationTests.swift" \
  "Astra/Services/Tasks/TaskDecisionDockPresentation.swift" \
  "Astra/Views/TaskMainView.swift"

assert_targets $'HeadlessChatScenarioTests\nFeedbackReportPresentationTests\nAgentRuntimeFailureDiagnosticsTests\nAgentRuntimeAdapterTests' \
  "Astra/Services/Runtime/AgentRuntimeWorker.swift" \
  "Tests/HeadlessChatProcessScenarioTests.swift" \
  "Astra/Services/Diagnostics/AgentRuntimeDiagnostics.swift" \
  "Astra/Services/Runtime/ProviderMessages.swift" \
  "Tests/AgentRuntimeAdapterTests.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackCrashRecoveryTests' \
  "Astra/Models/AppStorageKeys.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackCrashRecoveryTests\nTaskDecisionDockPresentationTests' \
  "Astra/Models/AppStorageKeys.swift" \
  "Tests/TaskDecisionDockPresentationTests.swift" \
  "Astra/Views/ContentView.swift" \
  "Astra/Services/Feedback/FeedbackCrashOfferService.swift"

assert_targets $'FeedbackReportPresentationTests\nFeedbackCrashRecoveryTests' \
  "Astra/ASTRAApp.swift" \
  "Astra/Views/ContentView.swift" \
  "Astra/Views/LogViewerView.swift"

assert_targets ""

assert_targets "" \
  "Astra/Services/Runtime/AgentRuntimeAdapter.swift"
