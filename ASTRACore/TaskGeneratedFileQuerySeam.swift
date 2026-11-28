import Foundation
import os

// Added as part of Track A4 (ASTRAPersistence extraction) so
// `Astra/Services/Persistence/TaskOutputDiscovery.swift`/
// `WorkspaceFileIndexService.swift` can query generated-file facts without
// depending on `Astra/Services/Tasks/TaskGeneratedFiles.swift`, most of
// which is genuinely Shelf-UI-infrastructure-coupled (`CoreShelfRegistry`,
// `ShelfArtifactRouter`) per Track A2.1's original assessment - unlike that
// track's `isHTMLFile`/`isMarkdownFile`/`isSQLFile` pure slice (already in
// `ASTRACore/TaskGeneratedFilePathPolicy.swift`), these three methods still
// need the real Shelf-routing/file-I/O behind them, so they're seamed
// rather than moved.
//
// Follows the exact registration pattern in `RuntimeSeams.swift`: a public
// protocol + an `OSAllocatedUnfairLock`-backed static registry with
// `.register(_:)` and a fail-fast `.required` accessor, wired up from
// `RuntimeSeamRegistration.registerAll()`.
public protocol TaskGeneratedFileQuerying: Sendable {
    static func files(in folder: String, fileManager: FileManager) -> [String]
    static func shelfDestination(for path: String) -> TaskGeneratedFileShelfDestination?
    static func shouldDisplayTaskFolderFile(relativePath: String) -> Bool
    /// `files(in:fileManager:)` that polls `isCancelled` per entry and gives
    /// up with nil. Opt-in, so no other caller ever sees a partial list.
    static func files(in folder: String, fileManager: FileManager, isCancelled: () -> Bool) -> [String]?
    /// `files(in:fileManager:isCancelled:)` with what the walk already knows
    /// about each file, so a caller need not ask the filesystem again.
    static func entries(in folder: String, fileManager: FileManager, isCancelled: () -> Bool) -> [TaskGeneratedFileEntry]?
}

extension TaskGeneratedFileQuerying {
    public static func files(in folder: String, fileManager: FileManager, isCancelled: () -> Bool) -> [String]? {
        isCancelled() ? nil : files(in: folder, fileManager: fileManager)
    }

    public static func entries(
        in folder: String, fileManager: FileManager, isCancelled: () -> Bool
    ) -> [TaskGeneratedFileEntry]? {
        files(in: folder, fileManager: fileManager, isCancelled: isCancelled)?.map(TaskGeneratedFileEntry.init(unverifiedPath:))
    }
}

/// One file a task-folder walk found.
///
/// A verified entry is one the walk settled from the directory listing
/// itself: `path` is standardized and already resolved, names something that
/// is not a directory inside the walked root, and `modifiedAt` is its
/// modification date. A caller can trust those instead of paying a stat, a
/// symlink resolve and an attribute read per file again. An unverified entry
/// (a symlink, or a walk that could not read the listing's values) carries
/// only its path, and the caller checks it as it always has.
public struct TaskGeneratedFileEntry: Equatable, Sendable {
    public let path: String
    public let modifiedAt: Date?
    public let isVerified: Bool

    public init(verifiedPath path: String, modifiedAt: Date?) {
        self.path = path
        self.modifiedAt = modifiedAt
        isVerified = true
    }

    public init(unverifiedPath path: String) {
        self.path = path
        modifiedAt = nil
        isVerified = false
    }
}

public enum TaskGeneratedFileQuerySeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskGeneratedFileQuerying.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ provider: any TaskGeneratedFileQuerying.Type) {
        storage.withLock { $0 = provider }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    public static var required: any TaskGeneratedFileQuerying.Type {
        guard let provider = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskGeneratedFileQuerySeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return provider
    }
}
