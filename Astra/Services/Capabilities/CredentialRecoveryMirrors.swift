import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The recovery files cleanup may still restore. This is a read-only view of
/// durable paths and this launch's admitted files, not another registry. Own
/// files use recovery's current-before-legacy rule; extras are never rewritten.
@MainActor
enum CredentialRecoveryMirrors {
    struct Entry {
        let workspace: Workspace?
        let workspaceID: UUID?
        let data: Data
    }

    static func read(
        modelContext: ModelContext, extraMirrors: [String]? = nil, excludingWorkspaceIDs: Set<UUID>? = nil
    ) -> [Entry]? {
        struct Identity: Decodable { let id: String? }
        struct Group {
            let workspace: Workspace?
            let fallbackID: UUID?
            let isOwnRoot: Bool
            let candidates: [String]
        }
        let savedContext = ModelContext(modelContext.container)
        guard let current = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              let saved = try? savedContext.fetch(FetchDescriptor<Workspace>()) else { return nil }
        let excluded = excludingWorkspaceIDs ?? Set(WorkspaceDeletionCleanupStore(for: modelContext).pending().map(\.workspaceID))
        let currentByRoot = Dictionary(current.map {
            ($0.id.uuidString + "|" + WorkspacePathPresentation.resolvedPath($0.primaryPath), $0)
        }, uniquingKeysWith: { first, _ in first })
        var groups: [Group] = []
        var roots = Set<String>()
        // Return only models owned by the caller's context. A saved path
        // hidden by an unsaved edit remains a read-only recovery reference;
        // no model escapes the lifetime of savedContext.
        for workspace in saved + current where !workspace.primaryPath.isEmpty {
            let root = WorkspacePathPresentation.resolvedPath(workspace.primaryPath)
            guard roots.insert(root).inserted else { continue }
            let owner = currentByRoot[workspace.id.uuidString + "|" + root]
            groups.append(Group(workspace: owner, fallbackID: workspace.id, isOwnRoot: true, candidates: [
                WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath),
                WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspace.primaryPath)
            ].filter { !$0.isEmpty }))
        }
        let own = Set(groups.flatMap(\.candidates).map { WorkspacePathPresentation.resolvedPath($0) })
        for extra in Set(extraMirrors ?? WorkspaceRecoveryTrust.loadedMirrors).sorted()
        where !own.contains(WorkspacePathPresentation.resolvedPath(extra)) {
            groups.append(Group(workspace: nil, fallbackID: nil, isOwnRoot: false, candidates: [extra]))
        }
        var result: [Entry] = []
        for group in groups {
            for path in group.candidates {
                let data: Data
                do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
                catch {
                    if WorkspaceFileLayout.isMissingFile(error) { continue }
                    return nil
                }
                guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else { return nil }
                let id: UUID?
                if let raw = identity.id {
                    guard let parsed = UUID(uuidString: raw) else { return nil }
                    id = parsed
                } else { id = group.fallbackID }
                if !group.isOwnRoot, let id, excluded.contains(id) { break }
                let owner = group.workspace.flatMap { $0.id == id ? $0 : nil }
                result.append(Entry(workspace: owner, workspaceID: id, data: data))
                break
            }
        }
        return result
    }
}
