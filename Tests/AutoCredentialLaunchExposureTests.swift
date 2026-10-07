import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// In Auto the launch gate allows a connector for the task and the launch goes
/// on. The capability snapshot was captured at admission, before that grant, so
/// the launch has to be built from a snapshot refreshed from the durable grants
/// or it starts without the credential the chat says was allowed.
@Suite("Auto credential grant reaches the same launch")
@MainActor
struct AutoCredentialLaunchExposureTests {
    @Test("A grant the Auto gate records is exposed by the refreshed snapshot, scope unchanged")
    func refreshedSnapshotExposesTheAutoGrant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-credential-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Auto launch", primaryPath: root.path)
        let connector = Connector(
            name: "Internal API",
            serviceType: "custom_api",
            baseURL: "https://api.example.test/",
            authMethod: "bearer"
        )
        connector.workspace = workspace
        connector.credentialKeys = ["API_TOKEN"]
        let task = AgentTask(title: "Use API", goal: "Use the Internal API connector", workspace: workspace)
        let run = TaskRun(task: task)
        run.runtimeID = AgentRuntimeID.claudeCode.rawValue
        context.insert(workspace)
        context.insert(connector)
        context.insert(task)
        context.insert(run)
        try context.save()
        let store = MockSecretStore()
        store.save(
            key: "API_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )
        let label = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "API_TOKEN")

        let admitted = TaskCapabilityResolutionSnapshot.capture(
            for: task, providerLaunchContextText: task.goal, runtime: .claudeCode, secretStore: store
        )
        #expect(!admitted.connectorCredentialExposurePolicy.approvedCredentialLabels.contains(label))

        let gate = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "test",
            contextText: task.goal,
            permissionPolicy: .autonomous,
            capabilityResolutionSnapshot: admitted,
            secretStore: store
        )
        #expect(gate.didPass)

        let refreshed = admitted.addingApprovedCredentialLabels(
            TaskRuntimePermissionGrants.approvedCredentialLabels(for: task, runtime: .claudeCode)
        )
        #expect(refreshed.connectorCredentialExposurePolicy.approvedCredentialLabels.contains(label))
        #expect(refreshed.providerLaunch.connectors.map(\.id) == admitted.providerLaunch.connectors.map(\.id))

        func plan(_ snapshot: TaskCapabilityResolutionSnapshot) -> TaskLaunchResourcePlan {
            TaskLaunchResourceResolver.resolve(
                task: task,
                runID: run.id,
                runtime: .claudeCode,
                phase: "run",
                prompt: task.goal,
                contextText: task.goal,
                workspacePath: root.path,
                capabilityResolutionSnapshot: snapshot,
                connectorSecretStore: store,
                gitCredentialContextProvider: { _, _, _, _ in .empty }
            )
        }
        #expect(!plan(admitted).credentialGrants.contains { $0.label == label }, "the admitted snapshot predates the grant")
        #expect(plan(refreshed).credentialGrants.contains { $0.label == label })
    }

    @Test("Refreshing with nothing new returns the same exposure")
    func refreshWithNothingNewIsUnchanged() {
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: AgentTask(title: "Plain", goal: "Summarize"),
            providerLaunchContextText: "Summarize"
        )
        let same = snapshot.addingApprovedCredentialLabels([])
        #expect(same.connectorCredentialExposurePolicy == snapshot.connectorCredentialExposurePolicy)
    }

    /// The behaviour above only helps if the worker builds the launch from the
    /// refreshed snapshot, after the connector gate, and not from the admitted
    /// one. Source-shape pin: the worker body is too entangled to drive here.
    @Test("The worker builds the launch from the snapshot refreshed after the connector gate")
    func workerRefreshesAfterTheConnectorGate() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot().appendingPathComponent("Astra/Services/Runtime/AgentRuntimeWorker.swift"),
            encoding: .utf8
        )
        let gate = try #require(source.range(of: "AgentRuntimeConnectorPreflight.passed("))
        let refresh = try #require(source.range(
            of: "let capabilityResolutionSnapshot = admittedCapabilitySnapshot.addingApprovedCredentialLabels("
        ))
        let resources = try #require(source.range(of: "TaskLaunchResourceResolver.resolve("))
        #expect(gate.upperBound < refresh.lowerBound, "refresh after the gate records its grant")
        #expect(refresh.upperBound < resources.lowerBound, "launch resources are built from the refreshed snapshot")
        let gateCall = source[gate.lowerBound..<refresh.lowerBound]
        #expect(gateCall.contains("capabilityResolutionSnapshot: admittedCapabilitySnapshot"))
    }

    private static func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
