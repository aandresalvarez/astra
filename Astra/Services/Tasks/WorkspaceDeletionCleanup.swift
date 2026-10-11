import CryptoKit
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// What a workspace deletion must remove outside the store: its generated
/// mirrors and its connectors' and skills' Keychain items. It is recorded
/// before the deletion is saved and cleared once that cleanup has run, so a
/// quit in between is settled at the next launch, before startup recovery
/// could reimport the workspace from a mirror left behind.
struct WorkspaceDeletionCleanupRecord: Codable, Equatable {
    let workspaceID: UUID
    let primaryPath: String
    /// The primary folder's physical path when the deletion was recorded.
    /// Mirrors, ownership, and the record's key all use it, so a symlink in
    /// the configured spelling retargeted before a retry can't aim cleanup
    /// at another folder's mirror.
    let physicalFolder: String
    let connectors: [ConnectorKeychainCleanup]
    let skills: [SkillKeychainCleanup]
    /// True for a record written before `physicalFolder` existed, whose
    /// folder was resolved again on reading. The store accepts one only
    /// while that resolution still matches the digest its file is named by.
    let folderWasResolvedOnRead: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID, primaryPath, physicalFolder, connectors, skills
    }

    init(
        workspaceID id: UUID, primaryPath path: String,
        connectors connectorCleanups: [ConnectorKeychainCleanup], skills skillCleanups: [SkillKeychainCleanup]
    ) {
        self.init(
            workspaceID: id, primaryPath: path, physicalFolder: WorkspacePathPresentation.resolvedPath(path),
            connectors: connectorCleanups, skills: skillCleanups
        )
    }

    private init(
        workspaceID id: UUID, primaryPath path: String, physicalFolder folder: String,
        connectors connectorCleanups: [ConnectorKeychainCleanup], skills skillCleanups: [SkillKeychainCleanup]
    ) {
        workspaceID = id
        primaryPath = path
        physicalFolder = folder
        connectors = connectorCleanups
        skills = skillCleanups
        folderWasResolvedOnRead = false
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        primaryPath = try container.decode(String.self, forKey: .primaryPath)
        // Records written before the folder was snapshotted resolve it here;
        // the store verifies that against the record's file name.
        let recorded = try container.decodeIfPresent(String.self, forKey: .physicalFolder)
        physicalFolder = recorded ?? WorkspacePathPresentation.resolvedPath(primaryPath)
        folderWasResolvedOnRead = recorded == nil
        connectors = try container.decode([ConnectorKeychainCleanup].self, forKey: .connectors)
        skills = try container.decode([SkillKeychainCleanup].self, forKey: .skills)
    }

    /// Both records' credentials, so a cleanup still pending for the same
    /// deletion is never dropped by a later one.
    func merging(_ other: WorkspaceDeletionCleanupRecord) -> WorkspaceDeletionCleanupRecord {
        WorkspaceDeletionCleanupRecord(
            workspaceID: workspaceID, primaryPath: primaryPath, physicalFolder: physicalFolder,
            // By every namespace-defining fact, not only the connector ID: a
            // reimported connector can keep its ID under a new base URL.
            connectors: connectors + other.connectors.filter { !connectors.contains($0) },
            skills: skills + other.skills.filter { new in !skills.contains { $0.skillID == new.skillID } }
        )
    }

    @MainActor
    init(_ workspace: Workspace) {
        workspaceID = workspace.id
        primaryPath = workspace.primaryPath
        physicalFolder = WorkspacePathPresentation.resolvedPath(workspace.primaryPath)
        connectors = workspace.connectors.map(\.keychainCleanup)
            + workspace.skills.flatMap { $0.connectors.map(\.keychainCleanup) }
        skills = workspace.skills.map(\.keychainCleanup)
        folderWasResolvedOnRead = false
    }
}

/// An app-owned outbox of workspace deletion cleanups, one atomic record per
/// workspace, outside provider-writable paths.
struct WorkspaceDeletionCleanupStore: Sendable {
    let directory: URL

    init(directory: URL = AppChannelStoragePaths.applicationSupportDirectory()
        .appendingPathComponent("WorkspaceDeletionCleanup", isDirectory: true)) {
        self.directory = directory.standardizedFileURL
    }

    /// Records `record` and returns what is now stored. Records are keyed by
    /// workspace and primary path, since imports reuse workspace IDs, and a
    /// pending record with the same key is merged rather than replaced. One
    /// that can't be read stops the deletion instead of being overwritten.
    @discardableResult
    func record(_ record: WorkspaceDeletionCleanupRecord) throws -> WorkspaceDeletionCleanupRecord {
        let stored = try existing(matching: record).map { $0.merging(record) } ?? record
        try write(stored)
        return stored
    }

    /// The pending record with `record`'s key, if any. One that can't be read
    /// throws rather than reading as absent.
    func existing(matching record: WorkspaceDeletionCleanupRecord) throws -> WorkspaceDeletionCleanupRecord? {
        let url = recordURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(url)
    }

    struct UnverifiableFolder: Error {}

    /// Decodes the record at `url`. A record without its recorded folder is
    /// trusted only while resolving its path still gives the folder its file
    /// was named for; once a symlink in it points elsewhere, the folder that
    /// was deleted is unknown, so it reads as unreadable and fails closed.
    private func read(_ url: URL) throws -> WorkspaceDeletionCleanupRecord {
        let record = try JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: Data(contentsOf: url))
        guard !record.folderWasResolvedOnRead
            || recordURL(for: record).standardizedFileURL.path == url.standardizedFileURL.path
        else { throw UnverifiableFolder() }
        return record
    }

    /// Replaces whatever is stored under the record's key.
    func write(_ record: WorkspaceDeletionCleanupRecord) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = recordURL(for: record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Undoes a `record` whose deletion wasn't saved: what was pending before
    /// it is put back, so a retry that rolls back never drops cleanup an
    /// earlier saved deletion still owes. With nothing before it, the record
    /// is removed. A write that fails keeps the merged record, which only
    /// ever names more to clean.
    func restore(_ previous: WorkspaceDeletionCleanupRecord?, replacing record: WorkspaceDeletionCleanupRecord) throws {
        if let previous {
            try write(previous)
        } else {
            remove(record)
        }
    }

    func remove(_ record: WorkspaceDeletionCleanupRecord) {
        try? FileManager.default.removeItem(at: recordURL(for: record))
    }

    /// Readable records; an unreadable one stays on disk and is skipped.
    func pending() -> [WorkspaceDeletionCleanupRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { try? read($0) }
    }

    /// The mirror files of every unsettled deletion, which startup recovery
    /// must not reimport. Nil when a record can't be read, since then which
    /// mirror it guards is unknown.
    func pendingMirrorPaths() -> Set<String>? {
        // No outbox means nothing pending; one that can't be listed is unknown.
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        var mirrors = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let record = try? read(url) else { return nil }
            // Resolved, so the same mirror reached through a symlink or an
            // alias such as /tmp and /private/tmp still matches.
            mirrors.insert(WorkspacePathPresentation.resolvedPath(WorkspaceFileLayout.workspaceConfigFile(for: record.physicalFolder)))
            mirrors.insert(WorkspacePathPresentation.resolvedPath(WorkspaceFileLayout.legacyWorkspaceConfigFile(for: record.physicalFolder)))
        }
        return mirrors
    }

    func recordURL(for record: WorkspaceDeletionCleanupRecord) -> URL {
        let path = record.physicalFolder
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(record.workspaceID.uuidString.lowercased() + "-" + digest + ".json")
    }
}

@MainActor
enum WorkspaceDeletionCleanupService {
    /// Removes what `record` names that nothing stored still owns. Mirrors go
    /// before credentials, so a quit between them leaves only unreachable
    /// Keychain items. Ownership is read from the committed store, never
    /// from whether this deletion was saved: a mirror at a primary path a
    /// stored workspace resolves to is spared, as is every Keychain
    /// namespace a stored connector resolves to and the items of a skill
    /// whose ID survives. So a deletion that was never saved, or a workspace
    /// reimported at the same path before a retry, keeps everything it
    /// uses, and only what no one owns is removed. Returns false, keeping
    /// the record, when the store can't be read or anything owed remains.
    @discardableResult
    static func settle(_ record: WorkspaceDeletionCleanupRecord, modelContext: ModelContext) -> Bool {
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              let connectors = try? modelContext.fetch(FetchDescriptor<Connector>()),
              let skills = try? modelContext.fetch(FetchDescriptor<Skill>()) else { return false }
        // The folder recorded at deletion, compared with where each stored
        // workspace resolves now, so an alias such as /tmp for /private/tmp
        // or a symlinked folder still names the same live mirror, and a
        // symlink retargeted since never redirects the removal.
        let path = record.physicalFolder
        // A mirror left behind would let recovery reimport the workspace, so
        // the record, and the credentials it needs, are kept for a retry.
        if !workspaces.contains(where: { WorkspacePathPresentation.resolvedPath($0.primaryPath) == path }),
           !removeMirrors(for: path) {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "mirror_removal_failed"
            ], level: .error)
            return false
        }
        // Only a live Outlook connector keeps the mail-registry entry its ID
        // names; an import that reused the ID for another service doesn't.
        let liveOutlookConnectors = Set(connectors.filter(\.isStanfordOutlookMail).map(\.id))
        // A recreated connector can share a stable endpoint or package
        // namespace under a new ID, so ownership is per namespace.
        let liveNamespaces = Set(connectors.flatMap { KeychainSecretStore.connectorEntityIDs(for: $0) })
        let liveSkills = Set(skills.map(\.id))
        // Every credential is attempted; any that couldn't be cleared keeps
        // the record for an idempotent retry.
        var cleared = true
        for connector in record.connectors {
            let keepRegistryEntry = liveOutlookConnectors.contains(connector.connectorID)
            // Owed when a namespace has no live owner, or a mail-registry
            // entry no live Outlook connector claims.
            let ownsRegistryEntry = connector.isStanfordOutlookMail && !keepRegistryEntry
            guard ownsRegistryEntry || !unownedNamespaces(of: connector, liveNamespaces: liveNamespaces).isEmpty
            else { continue }
            cleared = connector.run(sparing: liveNamespaces, keepRegistryEntry: keepRegistryEntry) && cleared
        }
        for skill in record.skills where !liveSkills.contains(skill.skillID) {
            cleared = skill.run() && cleared
        }
        if !cleared {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "credential_cleanup_failed"
            ], level: .error)
        }
        return cleared
    }

    /// The Keychain namespaces `connector` resolves to that no live
    /// connector uses, which are the only ones its cleanup removes.
    static func unownedNamespaces(of connector: ConnectorKeychainCleanup, liveNamespaces: Set<String>) -> Set<String> {
        Set(KeychainSecretStore.connectorEntityIDs(
            id: connector.connectorID, serviceType: connector.serviceType, baseURL: connector.baseURL,
            originPackageID: connector.originPackageID, originComponentID: connector.originComponentID
        )).subtracting(liveNamespaces)
    }

    /// Settles deletions a quit interrupted, reading committed state through
    /// a fresh context. Startup runs this before mirror recovery.
    @discardableResult
    static func resumePending(
        modelContext: ModelContext,
        store: WorkspaceDeletionCleanupStore = WorkspaceDeletionCleanupStore()
    ) -> Int {
        var settled = 0
        for record in store.pending() where settle(record, modelContext: ModelContext(modelContext.container)) {
            store.remove(record)
            settled += 1
        }
        return settled
    }

    /// False when a mirror that exists couldn't be removed. Existence is
    /// checked without following links: a dangling symlink is still a
    /// mirror, since its target could come back and be reimported, so the
    /// link itself is removed.
    static func removeMirrors(for workspacePath: String) -> Bool {
        let mirrorPaths = Set([
            WorkspaceFileLayout.workspaceConfigFile(for: workspacePath),
            WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspacePath)
        ])
        var removedAll = true
        for path in mirrorPaths where (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }
}
