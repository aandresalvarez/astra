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
    let connectors: [ConnectorKeychainCleanup]
    let skills: [SkillKeychainCleanup]
    /// True once a deletion of this workspace was saved. Its cleanup is owed
    /// from then on, even after the same workspace is reimported at the same
    /// path; until then a stored workspace means the deletion never happened.
    let committed: Bool

    init(
        workspaceID id: UUID, primaryPath path: String,
        connectors connectorCleanups: [ConnectorKeychainCleanup], skills skillCleanups: [SkillKeychainCleanup],
        committed isCommitted: Bool = false
    ) {
        workspaceID = id
        primaryPath = path
        connectors = connectorCleanups
        skills = skillCleanups
        committed = isCommitted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        primaryPath = try container.decode(String.self, forKey: .primaryPath)
        connectors = try container.decode([ConnectorKeychainCleanup].self, forKey: .connectors)
        skills = try container.decode([SkillKeychainCleanup].self, forKey: .skills)
        committed = try container.decodeIfPresent(Bool.self, forKey: .committed) ?? false
    }

    /// Both records' credentials, so a cleanup still pending for the same
    /// deletion is never dropped by a later one. Committed if either was.
    func merging(_ other: WorkspaceDeletionCleanupRecord) -> WorkspaceDeletionCleanupRecord {
        WorkspaceDeletionCleanupRecord(
            workspaceID: workspaceID, primaryPath: primaryPath,
            // By every namespace-defining fact, not only the connector ID: a
            // reimported connector can keep its ID under a new base URL.
            connectors: connectors + other.connectors.filter { !connectors.contains($0) },
            skills: skills + other.skills.filter { new in !skills.contains { $0.skillID == new.skillID } },
            committed: committed || other.committed
        )
    }

    var markedCommitted: WorkspaceDeletionCleanupRecord {
        WorkspaceDeletionCleanupRecord(
            workspaceID: workspaceID, primaryPath: primaryPath, connectors: connectors, skills: skills, committed: true
        )
    }

    @MainActor
    init(_ workspace: Workspace) {
        workspaceID = workspace.id
        primaryPath = workspace.primaryPath
        connectors = workspace.connectors.map(\.keychainCleanup)
            + workspace.skills.flatMap { $0.connectors.map(\.keychainCleanup) }
        skills = workspace.skills.map(\.keychainCleanup)
        committed = false
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
        return try JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: Data(contentsOf: url))
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
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            try? JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: Data(contentsOf: $0))
        }
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
            guard let record = try? JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: Data(contentsOf: url))
            else { return nil }
            // Resolved, so the same mirror reached through a symlink or an
            // alias such as /tmp and /private/tmp still matches.
            mirrors.insert(WorkspacePathPresentation.resolvedPath(WorkspaceFileLayout.workspaceConfigFile(for: record.primaryPath)))
            mirrors.insert(WorkspacePathPresentation.resolvedPath(WorkspaceFileLayout.legacyWorkspaceConfigFile(for: record.primaryPath)))
        }
        return mirrors
    }

    func recordURL(for record: WorkspaceDeletionCleanupRecord) -> URL {
        let path = WorkspacePathPresentation.resolvedPath(record.primaryPath)
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(record.workspaceID.uuidString.lowercased() + "-" + digest + ".json")
    }
}

@MainActor
enum WorkspaceDeletionCleanupService {
    /// Removes what `record` names once its workspace is durably gone. Mirrors
    /// go before credentials, so a quit between them leaves only unreachable
    /// Keychain items. Anything a surviving workspace still uses is spared: a
    /// mirror at a primary path another workspace has, and the Keychain items
    /// of a connector or skill whose ID survives, as Duplicate imports keep
    /// IDs. Returns false, keeping the record, when the store can't be read.
    @discardableResult
    static func settle(_ record: WorkspaceDeletionCleanupRecord, modelContext: ModelContext) -> Bool {
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              let connectors = try? modelContext.fetch(FetchDescriptor<Connector>()),
              let skills = try? modelContext.fetch(FetchDescriptor<Skill>()) else { return false }
        guard deletionWasSaved(record, workspaces: workspaces) else { return true }
        let path = WorkspacePathPresentation.standardizedPath(record.primaryPath)
        // A mirror left behind would let recovery reimport the workspace, so
        // the record, and the credentials it needs, are kept for a retry.
        if !workspaces.contains(where: { WorkspacePathPresentation.standardizedPath($0.primaryPath) == path }),
           !removeMirrors(for: record.primaryPath) {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "mirror_removal_failed"
            ], level: .error)
            return false
        }
        let liveConnectors = Set(connectors.map(\.id))
        let liveSkills = Set(skills.map(\.id))
        // Every credential is attempted; any that couldn't be cleared keeps
        // the record for an idempotent retry.
        var cleared = true
        for connector in record.connectors where !liveConnectors.contains(connector.connectorID) {
            cleared = connector.run() && cleared
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

    /// Whether `record`'s cleanup is owed. An uncommitted record's deletion
    /// was never saved when that same workspace, by ID and path, is still
    /// stored; an import that reused the ID elsewhere doesn't make its
    /// cleanup unnecessary. A committed one is owed even then: the stored
    /// workspace is a reimport, whose mirror and live connectors and skills
    /// `settle` spares.
    static func deletionWasSaved(_ record: WorkspaceDeletionCleanupRecord, workspaces: [Workspace]) -> Bool {
        let resolvedRecordPath = WorkspacePathPresentation.resolvedPath(record.primaryPath)
        return record.committed || !workspaces.contains {
            $0.id == record.workspaceID && WorkspacePathPresentation.resolvedPath($0.primaryPath) == resolvedRecordPath
        }
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

    /// False when a mirror that exists couldn't be removed.
    static func removeMirrors(for workspacePath: String) -> Bool {
        let mirrorPaths = Set([
            WorkspaceFileLayout.workspaceConfigFile(for: workspacePath),
            WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspacePath)
        ])
        var removedAll = true
        for path in mirrorPaths where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }
}
