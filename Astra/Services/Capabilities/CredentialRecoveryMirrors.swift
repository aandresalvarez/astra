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
        /// What decoding `data` gives, made off the main actor before the
        /// pass from these very bytes; nil when none was made.
        let decodedAhead: CredentialMirrorDecodes.File?
    }

    /// How many reads this process has made. Each one reads every mirror
    /// file on the main actor, so tests pin how many a pass makes by this
    /// count.
    private(set) static var readCount = 0

    /// How many times this process has decoded a mirror file's bytes on the
    /// main actor, as one shape (`decoded`). A decode made ahead, off the
    /// main actor, isn't counted, so tests pin by it what a pass decodes on
    /// the main actor.
    private(set) static var mainActorDecodeCount = 0

    private struct Group {
        let workspace: Workspace?
        let fallbackID: UUID?
        let isOwnRoot: Bool
        let candidates: [String]
    }

    static func read(
        modelContext: ModelContext, extraMirrors: [String]? = nil, excludingWorkspaceIDs: Set<UUID>? = nil,
        decodedAhead: CredentialMirrorDecodes? = nil
    ) -> [Entry]? {
        readCount += 1
        guard let groups = groups(modelContext: modelContext, extraMirrors: extraMirrors) else { return nil }
        let excluded = excludingWorkspaceIDs ?? Set(WorkspaceDeletionCleanupStore(for: modelContext).pending().map(\.workspaceID))
        var result: [Entry] = []
        for group in groups {
            for path in group.candidates {
                let data: Data
                do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
                catch {
                    if WorkspaceFileLayout.isMissingFile(error) { continue }
                    return nil
                }
                let ahead = decodedAhead?.file(at: path, ifContentsAre: data)
                guard let identity = decoded(data, ahead: ahead, \.identity, decodingWith: CredentialMirrorIdentity.decode)
                else { return nil }
                let id: UUID?
                if let raw = identity.id {
                    guard let parsed = UUID(uuidString: raw) else { return nil }
                    id = parsed
                } else { id = group.fallbackID }
                if !group.isOwnRoot, let id, excluded.contains(id) { break }
                let owner = group.workspace.flatMap { $0.id == id ? $0 : nil }
                // A decode made ahead holds the same bytes; keeping its copy
                // lets this read's own go.
                result.append(Entry(workspace: owner, workspaceID: id, data: ahead?.data ?? data, decodedAhead: ahead))
                break
            }
        }
        return result
    }

    /// The files `read` reads for `modelContext` and `extraMirrors`, each
    /// list in its order: the first that is there is the one read.
    static func candidates(modelContext: ModelContext, extraMirrors: [String]? = nil) -> [[String]] {
        (groups(modelContext: modelContext, extraMirrors: extraMirrors) ?? []).map(\.candidates)
    }

    /// `entry`'s bytes decoded as one shape: the decode made ahead from
    /// those bytes when there is one, else one made now, which is counted.
    /// Nil when they don't decode as that shape.
    static func decoded<Shape>(
        _ entry: Entry, _ shape: KeyPath<CredentialMirrorDecodes.File, Shape?>, decodingWith decode: (Data) -> Shape?
    ) -> Shape? {
        decoded(entry.data, ahead: entry.decodedAhead, shape, decodingWith: decode)
    }

    private static func decoded<Shape>(
        _ data: Data, ahead: CredentialMirrorDecodes.File?, _ shape: KeyPath<CredentialMirrorDecodes.File, Shape?>,
        decodingWith decode: (Data) -> Shape?
    ) -> Shape? {
        if let ahead { return ahead[keyPath: shape] }
        mainActorDecodeCount += 1
        return decode(data)
    }

    private static func groups(modelContext: ModelContext, extraMirrors: [String]?) -> [Group]? {
        let savedContext = ModelContext(modelContext.container)
        guard let current = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              let saved = try? savedContext.fetch(FetchDescriptor<Workspace>()) else { return nil }
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
        return groups
    }
}

/// The workspace ID a mirror file names, which is all `read` decodes.
struct CredentialMirrorIdentity: Decodable, Sendable {
    let id: String?

    static func decode(_ data: Data) -> Self? { try? JSONDecoder().decode(Self.self, from: data) }
}
