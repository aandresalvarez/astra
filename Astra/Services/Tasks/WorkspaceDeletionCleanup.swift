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

    @MainActor
    init(_ workspace: Workspace) {
        workspaceID = workspace.id
        primaryPath = workspace.primaryPath
        connectors = workspace.connectors.map(\.keychainCleanup)
            + workspace.skills.flatMap { $0.connectors.map(\.keychainCleanup) }
        skills = workspace.skills.map(\.keychainCleanup)
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

    func record(_ record: WorkspaceDeletionCleanupRecord) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = recordURL(for: record.workspaceID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(_ record: WorkspaceDeletionCleanupRecord) {
        try? FileManager.default.removeItem(at: recordURL(for: record.workspaceID))
    }

    /// Readable records; an unreadable one stays on disk and is skipped.
    func pending() -> [WorkspaceDeletionCleanupRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            try? JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: Data(contentsOf: $0))
        }
    }

    func recordURL(for workspaceID: UUID) -> URL {
        directory.appendingPathComponent(workspaceID.uuidString.lowercased() + ".json")
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
        // The deletion was never saved: there is nothing to clean up.
        guard !workspaces.contains(where: { $0.id == record.workspaceID }) else { return true }
        let path = WorkspacePathPresentation.standardizedPath(record.primaryPath)
        if !workspaces.contains(where: { WorkspacePathPresentation.standardizedPath($0.primaryPath) == path }) {
            removeMirrors(for: record.primaryPath)
        }
        let liveConnectors = Set(connectors.map(\.id))
        let liveSkills = Set(skills.map(\.id))
        for connector in record.connectors where !liveConnectors.contains(connector.connectorID) { connector.run() }
        for skill in record.skills where !liveSkills.contains(skill.skillID) { skill.run() }
        return true
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

    static func removeMirrors(for workspacePath: String) {
        let mirrorPaths = Set([
            WorkspaceFileLayout.workspaceConfigFile(for: workspacePath),
            WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspacePath)
        ])
        for path in mirrorPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
