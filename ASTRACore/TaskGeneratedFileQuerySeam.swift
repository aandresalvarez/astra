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
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return provider
    }
}
