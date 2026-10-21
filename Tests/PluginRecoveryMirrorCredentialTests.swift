import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Recoverable plugin credential references", .serialized)
@MainActor
struct PluginRecoveryMirrorCredentialTests {
    @Test("A recovery mirror keeps a released namespace or key until the copy is gone", arguments: [false, true], [false, true])
    func holdsRecoverableSecrets(extra: Bool, whole: Bool) throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        let mirror = extra ? env.root.appendingPathComponent("old-copy.json") : env.ownMirror
        let identity = extra ? UUID() : env.workspace.id
        let namespace = env.namespace(workspaceID: identity)
        try env.writeActivation(at: mirror, workspaceID: identity)
        if !extra {
            // The ordinary mirror cannot be refreshed. A successful real
            // refresh would legitimately release its former references.
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mirror.path)
        }
        WorkspaceRecoveryTrust.recordLoadedMirrors(extra ? [mirror.path] : [])
        try env.record(namespace, whole: whole)
        MirrorDeletes.reset()
        env.resume()
        #expect(MirrorDeletes.deleted.isEmpty)
        #expect(try !env.outbox.entries().isEmpty)
        try FileManager.default.removeItem(at: mirror)
        env.resume()
        #expect(MirrorDeletes.deleted.count == 1)
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("A mirror's recorded key does not retain an unrelated retired key in that namespace")
    func unrelatedKeyCanBeReleased() throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        try env.writeActivation(at: env.ownMirror, workspaceID: env.workspace.id)
        let namespace = env.namespace(workspaceID: env.workspace.id)
        try env.outbox.journal([.init(key: "RETIRED_TOKEN", skillID: namespace)])
        MirrorDeletes.reset()
        env.resume()
        #expect(MirrorDeletes.deleted == ["\(namespace)#RETIRED_TOKEN"])
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("A malformed activation in a loaded mirror cannot authorize key deletion")
    func malformedExtraActivationHoldsClosed() throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        let mirror = env.root.appendingPathComponent("unreadable-activation.json")
        try Data(#"{"installedPlugins":"interrupted"}"#.utf8).write(to: mirror)
        WorkspaceRecoveryTrust.recordLoadedMirrors([mirror.path])
        try env.record(UUID(), whole: false)
        MirrorDeletes.reset()
        env.resume()
        #expect(MirrorDeletes.deleted.isEmpty)
        #expect(try !env.outbox.entries().isEmpty)
    }

    @Test("A nonterminal request retained only by an additional mirror keeps its credential generation")
    func mirroredRequestOwnsSecrets() throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        let (mirror, namespace, _) = try env.makeRequestCopy(includeAccount: false)
        WorkspaceRecoveryTrust.recordLoadedMirrors([mirror.path])
        try env.record(namespace, whole: true)
        MirrorDeletes.reset()
        env.resume()
        #expect(MirrorDeletes.deleted.isEmpty)
        #expect(try env.outbox.pending() == [namespace])
        try FileManager.default.removeItem(at: mirror)
        env.resume()
        #expect(MirrorDeletes.deleted == ["\(namespace)"])
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("A queued account held only by a recovered copy retains its cleanup until the copy is gone")
    func mirroredRequestOwnsAccount() throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        let (mirror, _, account) = try env.makeRequestCopy(includeAccount: true)
        let cleanup = try #require(account)
        WorkspaceRecoveryTrust.recordLoadedMirrors([mirror.path])
        var cleaned: [UUID] = []
        let perform: ([ConnectorKeychainCleanup], ConnectorCredentialCleanup.Ownership) -> Bool = { records, _ in
            cleaned += records.map(\.connectorID)
            return true
        }
        #expect(!ConnectorCredentialCleanup.run([cleanup], modelContext: env.context, retained: [], perform: perform))
        #expect(cleaned.isEmpty)
        try FileManager.default.removeItem(at: mirror)
        #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: env.context, retained: [], perform: perform))
        #expect(cleaned == [cleanup.connectorID])
    }

    @Test("A permission-paused request kept only in a recovery mirror retains its accepted credentials", arguments: [false, true])
    func mirroredPermissionPauseOwnsCredentials(includeAccount: Bool) throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        let (mirror, namespace, cleanup) = try env.makeRequestCopy(includeAccount: includeAccount, permissionPaused: true)
        WorkspaceRecoveryTrust.recordLoadedMirrors([mirror.path])
        try env.record(namespace, whole: true)
        MirrorDeletes.reset()
        env.resume()
        #expect(MirrorDeletes.deleted.isEmpty)
        #expect(try env.outbox.pending() == [namespace])
        var cleaned: [UUID] = []
        let perform: ([ConnectorKeychainCleanup], ConnectorCredentialCleanup.Ownership) -> Bool = { records, _ in
            cleaned += records.map(\.connectorID); return true
        }
        if let cleanup {
            #expect(!ConnectorCredentialCleanup.run([cleanup], modelContext: env.context, retained: [], perform: perform))
            #expect(cleaned.isEmpty)
        }
        try FileManager.default.removeItem(at: mirror)
        env.resume()
        #expect(MirrorDeletes.deleted == ["\(namespace)"])
        if let cleanup {
            #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: env.context, retained: [], perform: perform))
            #expect(cleaned == [cleanup.connectorID])
        }
    }

    @Test("An unsaved folder edit cannot hide the stored mirror from cleanup")
    func savedPathStillCounts() throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        try env.writeActivation(at: env.ownMirror, workspaceID: env.workspace.id)
        let original = env.workspace.primaryPath
        let mirror = env.ownMirror
        let namespace = env.namespace(workspaceID: env.workspace.id)
        env.workspace.primaryPath = env.root.appendingPathComponent("unsaved-location").path
        try env.record(namespace, whole: false)
        MirrorDeletes.reset()
        env.resume()
        #expect(MirrorDeletes.deleted.isEmpty)
        #expect(try ModelContext(env.container).fetch(FetchDescriptor<Workspace>()).first?.primaryPath == original)
        try FileManager.default.removeItem(at: mirror)
        env.resume()
        #expect(MirrorDeletes.deleted.count == 1)
    }

    @Test("Workspace deletion also waits for an activation retained by another recoverable copy")
    func workspaceDeletionKeepsMirroredGeneration() throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let mirrorID = UUID()
        let namespace = env.namespace(workspaceID: mirrorID)
        let mirror = env.root.appendingPathComponent("other-copy.json")
        try env.writeActivation(at: mirror, workspaceID: mirrorID)
        let cleanup = try JSONDecoder().decode(SkillKeychainCleanup.self,
            from: JSONSerialization.data(withJSONObject: ["skillID": namespace.uuidString]))
        let deletion = WorkspaceDeletionCleanupRecord(workspaceID: UUID(),
            primaryPath: env.root.appendingPathComponent("deleted").path, connectors: [], skills: [cleanup])
        var cleaned: [UUID] = []
        let clean: (SkillKeychainCleanup) -> Bool = { cleaned.append($0.skillID); return true }
        #expect(!WorkspaceDeletionCleanupService.settle(deletion, modelContext: env.context,
            extraMirrors: [mirror.path], cleanSkill: clean))
        #expect(cleaned.isEmpty)
        try FileManager.default.removeItem(at: mirror)
        #expect(WorkspaceDeletionCleanupService.settle(deletion, modelContext: env.context,
            extraMirrors: [mirror.path], cleanSkill: clean))
        #expect(cleaned == [namespace])
    }

    @MainActor
    struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let outbox: PluginSecretCleanupOutbox
        var ownMirror: URL { URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath)) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-credentials-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            context = container.mainContext
            context.autosaveEnabled = false
            workspace = Workspace(name: "Current", primaryPath: root.appendingPathComponent("workspace").path)
            context.insert(workspace)
            try context.save()
            outbox = PluginSecretCleanupOutbox(fileURL: root.appendingPathComponent("cleanup.json"))
        }
        /// A real exported mirror with an active immutable request, after
        /// its live activation/account have been removed. The newer store
        /// then forgets that request, leaving only the additional copy.
        func makeRequestCopy(includeAccount: Bool, permissionPaused: Bool = false) throws -> (URL, UUID, ConnectorKeychainCleanup?) {
            let activation = PluginActivation(pluginID: "mirror-plugin")
            context.insert(activation)
            activation.workspace = workspace
            WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
            WorkspaceCapabilityActivation.setCredentialNamespaceSeed("request-generation", on: activation)
            WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#API_TOKEN", on: activation)
            var account: Connector?
            if includeAccount {
                let created = Connector(name: "Frozen account", serviceType: "rest_api", baseURL: "https://mirror.example.invalid")
                context.insert(created)
                created.workspace = workspace
                WorkspaceCapabilityActivation.bind(created, toComponent: "connector:rest_api:account", of: activation)
                account = created
            }
            let task = AgentTask(title: "Recoverable request", goal: "Use original credentials", workspace: workspace)
            context.insert(task)
            let message = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Run with the accepted plugin")
            context.insert(message)
            let request = TaskTurnRequest(task: task, messageEventID: message.id, sequence: 1, pluginDefinitions: [])
            context.insert(request)
            if permissionPaused {
                let run = TaskRun(task: task)
                context.insert(run)
                run.status = .failed
                run.typedStopReason = .permissionApprovalRequired
                request.runID = run.id
                request.state = .failed
                request.terminalAt = Date()
                task.status = .pendingUser
                let binding = TaskPermissionContinuation.capture(task: task, run: run, modelContext: context)
                let accountID = account?.id ?? UUID()
                let label = "connector:\(accountID.uuidString):API_TOKEN"
                let approval = PermissionBroker.approvalPayload(providerID: task.resolvedRuntimeID,
                    request: .connectorCredentials(connectorID: accountID, displayName: "Account", labels: [label]),
                    reason: "Blocked pending approval", grants: [.credential(label: label)], requestID: "mirror-permission")
                let payload = try #require(approval.encodedString())
                TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
                    payload: TaskPermissionContinuation.attach(payload, continuation: binding), task: task)
            }
            try context.save()
            let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")
            let cleanup = account?.keychainCleanup
            context.delete(activation)
            if let account { context.delete(account) }
            try context.save()
            let mirror = root.appendingPathComponent("request-copy.json")
            try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: mirror)
            let config = try WorkspaceConfigManager.loadConfig(from: mirror)
            #expect(config.tasks?.first?.turnRequests?.count == 1)
            context.delete(request)
            try context.save()
            return (mirror, namespace, cleanup)
        }
        func namespace(workspaceID: UUID) -> UUID {
            PluginActivation.credentialID(workspaceID: workspaceID, pluginID: "mirror-plugin", componentID: "skill:agent",
                runtimeSeed: "stable", generation: "old-generation")
        }
        func writeActivation(at file: URL, workspaceID: UUID) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json: [String: Any] = ["id": workspaceID.uuidString,
                "installedPlugins": [["id": "mirror-plugin", "knownComponentIDs": ["skill:agent"],
                    "secretSettingKeys": ["skill:agent#API_TOKEN"], "namespaceSeed": "stable", "credentialNamespaceSeed": "old-generation"]]]
            try JSONSerialization.data(withJSONObject: json).write(to: file)
        }
        func record(_ namespace: UUID, whole: Bool) throws {
            if whole { try outbox.write([namespace]) }
            else { try outbox.journal([.init(key: "API_TOKEN", skillID: namespace)]) }
        }
        func resume() {
            PluginSecretCleanupOutbox.resumePending(modelContext: context, outbox: outbox,
                secrets: MirrorDeletes.self, rewriteMirror: { _ in true })
        }
        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }
}

private enum MirrorDeletes: SkillSecretPersisting {
    private static let records = OSAllocatedUnfairLock<[String]>(initialState: [])
    static var deleted: [String] { records.withLock { $0 } }
    static func reset() { records.withLock { $0 = [] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { records.withLock { $0.append("\(skillID)#\(key)") }; return true }
    static func deleteAllSecrets(skillID: UUID) { _ = deleteAllSecretsReportingResult(skillID: skillID) }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { records.withLock { $0.append("\(skillID)") }; return true }
}
