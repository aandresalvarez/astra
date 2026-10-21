import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Pending task credential cleanup", .serialized)
struct PendingTaskCredentialCleanupTests {
    @Test("Namespace cleanup remains owed until the saved request finishes, including after reopening", arguments: [false, true])
    func namespaceWaits(onDisk: Bool) throws {
        try verifyDeferredCleanup(onDisk: onDisk, wholeNamespace: true)
    }

    @Test("Single-key cleanup remains owed until the saved request finishes", arguments: [false, true])
    func keyWaits(onDisk: Bool) throws {
        try verifyDeferredCleanup(onDisk: onDisk, wholeNamespace: false)
    }

    private func verifyDeferredCleanup(onDisk: Bool, wholeNamespace: Bool) throws {
        let fixture = try Fixture(onDisk: onDisk)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        QueuedSecretDeletes.reset()
        let namespace = fixture.namespace
        let requestID = fixture.request.id
        let outbox = PluginSecretCleanupOutbox(fileURL: fixture.root.appendingPathComponent("skills-cleanup.json"))
        fixture.context.delete(fixture.activation)
        #expect(PluginSecretCleanupOutbox.deleteThenClean(
            wholeNamespace ? [namespace] : [],
            keys: wholeNamespace ? [] : [.init(key: "API_TOKEN", skillID: namespace)],
            modelContext: fixture.context, outbox: outbox, secrets: QueuedSecretDeletes.self,
            save: { (try? fixture.context.save()) != nil }
        ))
        #expect(QueuedSecretDeletes.deleted.isEmpty)
        #expect(try !outbox.entries().isEmpty)

        // A fresh context exercises the same durable request ownership used
        // after restarting ASTRA, not an in-memory copy of the queued task.
        let reopened = ModelContext(fixture.container)
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened, outbox: outbox,
                                                secrets: QueuedSecretDeletes.self, rewriteMirror: { _ in true })
        #expect(QueuedSecretDeletes.deleted.isEmpty)
        #expect(try !outbox.entries().isEmpty)
        let request = try #require(try reopened.fetch(FetchDescriptor<TaskTurnRequest>()).first { $0.id == requestID })
        request.state = .completed
        request.terminalAt = Date()
        try reopened.save()
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened, outbox: outbox,
                                                secrets: QueuedSecretDeletes.self, rewriteMirror: { _ in true })
        #expect(!QueuedSecretDeletes.deleted.isEmpty)
        #expect(try outbox.entries().isEmpty)
    }

    @Test("An unreadable active request prevents destructive credential cleanup")
    func unreadableSnapshotKeepsCleanup() throws {
        let fixture = try Fixture(onDisk: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        QueuedSecretDeletes.reset()
        fixture.request.executionPolicySnapshotJSON = "{interrupted snapshot"
        fixture.context.delete(fixture.activation)
        try fixture.context.save()
        let outbox = PluginSecretCleanupOutbox(fileURL: fixture.root.appendingPathComponent("skills-cleanup.json"))
        #expect(PluginSecretCleanupOutbox.deleteThenClean([fixture.namespace], modelContext: fixture.context,
            outbox: outbox, secrets: QueuedSecretDeletes.self, save: { true }))
        #expect(QueuedSecretDeletes.deleted.isEmpty)
        #expect(try outbox.pending() == [fixture.namespace])
    }

    @Test("Deleting an account keeps its queued credentials owed until the request is terminal", arguments: [false, true])
    func accountWaits(onDisk: Bool) throws {
        let fixture = try Fixture(onDisk: onDisk)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cleanup = fixture.account.keychainCleanup
        fixture.context.delete(fixture.account)
        try fixture.context.save()
        var cleaned: [UUID] = []
        let perform: ([ConnectorKeychainCleanup], ConnectorCredentialCleanup.Ownership) -> Bool = { records, _ in
            cleaned += records.map(\.connectorID)
            return true
        }
        #expect(!ConnectorCredentialCleanup.run([cleanup], modelContext: fixture.context, retained: [], perform: perform))
        #expect(cleaned.isEmpty)
        fixture.request.state = .cancelled
        fixture.request.terminalAt = Date()
        try fixture.context.save()
        #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: fixture.context, retained: [], perform: perform))
        #expect(cleaned == [cleanup.connectorID])
    }

    @Test("A permission-paused terminal request retains its frozen credentials until the approval is superseded")
    func permissionContinuationStillOwnsCredentials() throws {
        let fixture = try Fixture(onDisk: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == fixture.request.taskID })
        let run = TaskRun(task: task)
        fixture.context.insert(run)
        run.status = .failed
        run.typedStopReason = .permissionApprovalRequired
        fixture.request.runID = run.id
        fixture.request.state = .failed
        fixture.request.terminalAt = Date()
        task.status = .pendingUser
        let binding = TaskPermissionContinuation.capture(task: task, run: run, modelContext: fixture.context)
        let label = "connector:\(fixture.account.id.uuidString):API_TOKEN"
        let payload = try #require(PermissionBroker.approvalPayload(providerID: task.resolvedRuntimeID,
            request: .connectorCredentials(connectorID: fixture.account.id, displayName: "Account", labels: [label]),
            reason: "Blocked pending approval", grants: [.credential(label: label)], requestID: "permission-hold").encodedString())
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
            payload: TaskPermissionContinuation.attach(payload, continuation: binding), task: task)
        let cleanup = fixture.account.keychainCleanup
        fixture.context.delete(fixture.activation)
        fixture.context.delete(fixture.account)
        try fixture.context.save()
        let reopened = ModelContext(fixture.container)
        let references = try #require(PendingTaskCredentialReferences.capture(modelContext: reopened))
        #expect(references.holdsSkill(fixture.namespace, key: "API_TOKEN"))
        #expect(references.holdsAccount(cleanup))
        let savedTask = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first)
        let submission = ExecutionRequestSubmissionService.submitPermissionResume(message: "Continue",
            executionPolicy: .default, for: savedTask, into: reopened, continuation: binding)
        guard case .success(let submitted) = submission else { Issue.record("The same accepted context must remain resumable"); return }
        let transferred = try #require(PendingTaskCredentialReferences.capture(modelContext: reopened))
        #expect(transferred.holdsSkill(fixture.namespace, key: "API_TOKEN"))
        #expect(transferred.holdsAccount(cleanup))
        let continuation = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: reopened))
        continuation.state = .cancelled
        continuation.terminalAt = Date()
        try reopened.save()
        let released = try #require(PendingTaskCredentialReferences.capture(modelContext: reopened))
        #expect(!released.holdsSkill(fixture.namespace, key: "API_TOKEN"))
        #expect(!released.holdsAccount(cleanup))
    }

    @Test("An unknown request state or policy version holds cleanup closed", arguments: ["state", "version"])
    func unknownEvidenceIsConservative(kind: String) throws {
        let fixture = try Fixture(onDisk: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if kind == "state" {
            fixture.request.stateRawValue = "future_waiting_state"
        } else {
            let json = try #require(fixture.request.executionPolicySnapshotJSON)
            var policy = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            policy["version"] = 2
            fixture.request.executionPolicySnapshotJSON = String(decoding: try JSONSerialization.data(withJSONObject: policy), as: UTF8.self)
        }
        try fixture.context.save()
        #expect(PendingTaskCredentialReferences.capture(modelContext: fixture.context) == nil)
    }

    @Test("An unsaved terminal edit cannot authorize cleanup")
    func unsavedCompletionStillHolds() throws {
        let fixture = try Fixture(onDisk: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.request.state = .completed
        let references = try #require(PendingTaskCredentialReferences.capture(modelContext: fixture.context))
        #expect(references.holdsSkill(fixture.namespace, key: "API_TOKEN"))
        #expect(!references.holdsSkill(UUID()))
    }

    @Test("A detached launch keeps the submitted namespace when its target workspace differs")
    func submittedWorkspaceOwnsNamespace() throws {
        let fixture = try Fixture(onDisk: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try #require(fixture.activation.workspace)
        let target = Workspace(name: "Moved", primaryPath: fixture.root.appendingPathComponent("other").path)
        let record = PluginActivationRecord(fixture.activation)
        WorkspaceCapabilityActivation.copyActivations([record], of: source, to: target,
            accountsByID: [fixture.account.id: fixture.account], definitionsFrozen: true)
        let copy = try #require(WorkspaceCapabilityActivation.activations(of: target).first)
        #expect(PluginRuntimeProjection.derivedID(of: copy, componentID: "skill:agent") == fixture.namespace)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacy.removeValue(forKey: "workspaceID")
        let decoded = try JSONDecoder().decode(PluginActivationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.workspaceID == nil)
        #expect(decoded.pluginID == record.pluginID)
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
            root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-pending-credentials-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [onDisk ? ModelConfiguration(url: root.appendingPathComponent("test.store"))
                    : ModelConfiguration(isStoredInMemoryOnly: true)])
            context = container.mainContext
            context.autosaveEnabled = false
            let workspace = Workspace(name: "Pending", primaryPath: root.path)
            context.insert(workspace)
            activation = PluginActivation(pluginID: "queued-plugin-\(UUID())")
            context.insert(activation)
            activation.workspace = workspace
            WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
            WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#API_TOKEN", on: activation)
            namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:agent")
            account = Connector(name: "Queued account", serviceType: "rest_api", baseURL: "https://queued.example.test")
            account.originPackageID = activation.pluginID
            context.insert(account)
            account.workspace = workspace
            WorkspaceCapabilityActivation.bind(account, toComponent: "connector:rest_api:account", of: activation)
            let task = AgentTask(title: "Queued", goal: "Use the accepted plugin", workspace: workspace)
            context.insert(task)
            request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            context.insert(request)
            try context.save()
        }
    }
}

private enum QueuedSecretDeletes: SkillSecretPersisting {
    private static let records = OSAllocatedUnfairLock<[String]>(initialState: [])
    static var deleted: [String] { records.withLock { $0 } }
    static func reset() { records.withLock { $0 = [] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        records.withLock { $0.append("\(skillID)#\(key)") }; return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteAllSecrets(skillID: UUID) { records.withLock { $0.append(skillID.uuidString) } }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { deleteAllSecrets(skillID: skillID); return true }
}
