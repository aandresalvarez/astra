import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Pending task credential ownership", .serialized)
struct PendingTaskCredentialOwnershipTests {
    @Test("A queued skill namespace remains journaled across contexts, then cleans after completion", arguments: [false, true])
    func skillOwnerOutlivesActivation(onDisk: Bool) throws {
        let fixture = try Fixture(onDisk: onDisk)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        DeferredOwnerSecrets.reset()
        let outbox = PluginSecretCleanupOutbox(fileURL: fixture.root.appendingPathComponent("cleanup.json"))
        fixture.context.delete(fixture.activation)
        #expect(PluginSecretCleanupOutbox.deleteThenClean([fixture.namespace], modelContext: fixture.context,
            outbox: outbox, secrets: DeferredOwnerSecrets.self, save: { (try? fixture.context.save()) != nil }))
        #expect(DeferredOwnerSecrets.deleted.isEmpty)
        #expect(try outbox.pending() == [fixture.namespace])
        let reopened = ModelContext(fixture.container)
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened, outbox: outbox, secrets: DeferredOwnerSecrets.self)
        #expect(DeferredOwnerSecrets.deleted.isEmpty)
        let request = try #require(try reopened.fetch(FetchDescriptor<TaskTurnRequest>()).first)
        request.state = .completed
        try reopened.save()
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened, outbox: outbox, secrets: DeferredOwnerSecrets.self)
        #expect(DeferredOwnerSecrets.deleted == [fixture.namespace])
        #expect(try outbox.pending().isEmpty)
    }

    @Test("A frozen account keeps its endpoint namespace and cleanup debt until cancellation")
    func frozenAccountOwnsCredentials() throws {
        let fixture = try Fixture(onDisk: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cleanup = fixture.account.keychainCleanup
        fixture.context.delete(fixture.account)
        try fixture.context.save()
        var deleted: [UUID] = []
        let perform: ([ConnectorKeychainCleanup], ConnectorCredentialCleanup.Ownership) -> Bool = { rows, _ in
            deleted += rows.map(\.connectorID)
            return true
        }
        #expect(!ConnectorCredentialCleanup.run([cleanup], modelContext: fixture.context, retained: [], perform: perform))
        #expect(deleted.isEmpty)
        fixture.request.state = .cancelled
        try fixture.context.save()
        #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: fixture.context, retained: [], perform: perform))
        #expect(deleted == [cleanup.connectorID])
    }

    @Test("A legacy snapshot cannot borrow the identity of a workspace its task moved to")
    func legacySnapshotDoesNotBorrowMovedWorkspace() throws {
        let fixture = try Fixture(onDisk: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let json = try #require(fixture.request.executionPolicySnapshotJSON)
        var policy = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var activations = try #require(policy["pluginActivations"] as? [[String: Any]])
        for index in activations.indices { activations[index].removeValue(forKey: "workspaceID") }
        policy["pluginActivations"] = activations
        fixture.request.executionPolicySnapshotJSON = String(decoding: try JSONSerialization.data(withJSONObject: policy), as: UTF8.self)
        let moved = Workspace(name: "Moved", primaryPath: fixture.root.appendingPathComponent("moved").path)
        fixture.context.insert(moved)
        let task = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>()).first)
        task.workspace = moved
        try fixture.context.save()
        #expect(PendingTaskCredentialReferences.capture(modelContext: fixture.context) == nil)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let activation: PluginActivation
        let account: Connector
        let request: TaskTurnRequest
        let namespace: UUID

        init(onDisk: Bool) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-pending-owner-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [onDisk ? ModelConfiguration(url: root.appendingPathComponent("test.store"))
                    : ModelConfiguration(isStoredInMemoryOnly: true)])
            context = container.mainContext
            context.autosaveEnabled = false
            let workspace = Workspace(name: "Pending", primaryPath: root.path)
            context.insert(workspace)
            activation = PluginActivation(pluginID: "pending-owner-\(UUID())")
            context.insert(activation)
            activation.workspace = workspace
            WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
            WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#API_TOKEN", on: activation)
            namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:agent")
            account = Connector(name: "Pending account", serviceType: "rest_api", baseURL: "https://pending.example.test")
            context.insert(account)
            account.workspace = workspace
            WorkspaceCapabilityActivation.bind(account, toComponent: "connector:rest_api:account", of: activation)
            let task = AgentTask(title: "Queued", goal: "Use accepted definition", workspace: workspace)
            context.insert(task)
            request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            context.insert(request)
            try context.save()
        }
    }
}

private enum DeferredOwnerSecrets: SkillSecretPersisting {
    private static let records = OSAllocatedUnfairLock<[UUID]>(initialState: [])
    static var deleted: [UUID] { records.withLock { $0 } }
    static func reset() { records.withLock { $0 = [] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteAllSecrets(skillID: UUID) { records.withLock { $0.append(skillID) } }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { deleteAllSecrets(skillID: skillID); return true }
}
