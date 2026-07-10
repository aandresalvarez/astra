import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task capability credential prompt regressions")
struct TaskCapabilityCredentialPromptRegressionTests {
    @Test("Resolution snapshot preserves Auto connector credential exposure")
    func resolutionSnapshotPreservesAutoCredentialExposure() {
        let task = AgentTask(title: "Jira lookup", goal: "List my Jira issues")

        let restricted = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: task.goal
        )
        let automatic = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: task.goal,
            exposeAllConnectorCredentials: true
        )

        #expect(restricted.connectorCredentialExposurePolicy == .none)
        #expect(automatic.connectorCredentialExposurePolicy == .allowAllCredentials)
    }

    @Test("Provider prompt uses the captured connector credential exposure policy")
    func providerPromptUsesCapturedCredentialExposurePolicy() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeDirectory = repoRoot.appendingPathComponent("Astra/Services/Runtime", isDirectory: true)
        let workerSource = try String(
            contentsOf: runtimeDirectory.appendingPathComponent("AgentRuntimeWorker.swift"),
            encoding: .utf8
        )
        let promptBuilderSource = try String(
            contentsOf: runtimeDirectory.appendingPathComponent("AgentPromptBuilder.swift"),
            encoding: .utf8
        )

        #expect(workerSource.contains("capabilityResolutionSnapshot: capabilityResolutionSnapshot"))
        #expect(promptBuilderSource.contains("capabilityResolutionSnapshot?.providerLaunch"))
        #expect(promptBuilderSource.contains("capabilityResolutionSnapshot?.connectorCredentialExposurePolicy"))
    }
}
