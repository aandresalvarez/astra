import Foundation
import os
import ASTRACore

// Added as part of Track A4 (ASTRAPersistence extraction) so
// `Astra/Services/Persistence/TaskContextStateManager.swift` and
// `WorkspaceFileIndexService.swift` can read fork-checkpoint facts they
// render into prompt context / the files shelf without depending on
// `Astra/Services/Tasks/TaskForkManifestService.swift` (real file I/O via
// `HostFileAccessBroker`, distinct from A2.6's already-seamed
// `writeManifest`/`manifestPath`, which cover the write side of the same
// service). `checkpointFilePaths` primitive-izes `load(for:fileManager:)` +
// reading `.sourceOutputFiles`/`.sourceArtifacts` off the returned
// `TaskForkManifest` into the exact flattened path list
// `WorkspaceFileIndexService` actually needs, rather than exposing
// `TaskForkManifest`/`FileReference` across the seam boundary.
//
// Lives in `ASTRAModels`, not `ASTRACore`, for the same reason as
// `TaskPlanReconstructionSeam`: `AgentTask` is a Models type, so a seam
// shaped around it can't live in `ASTRACore` (which can never import
// `ASTRAModels`).
//
// Follows the exact registration pattern in `RuntimeSeams.swift`: a public
// protocol + an `OSAllocatedUnfairLock`-backed static registry with
// `.register(_:)` and a fail-fast `.required` accessor, wired up from
// `RuntimeSeamRegistration.registerAll()`.
public protocol TaskForkSourcePointerProviding {
    static func sourcePointers(for task: AgentTask) -> [TaskContextSourcePointer]
    // Protocol requirements can't declare default parameter values (unlike
    // `TaskForkManifestService.sourceAvailabilityWarning(for:fileManager:)`'s
    // own `fileManager: FileManager = .default`), so callers through this
    // seam must pass `fileManager` explicitly.
    static func sourceAvailabilityWarning(for task: AgentTask, fileManager: FileManager) -> String?
    static func checkpointFilePaths(for task: AgentTask, fileManager: FileManager) -> [String]
}

public enum TaskForkSourcePointerSeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskForkSourcePointerProviding.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ provider: any TaskForkSourcePointerProviding.Type) {
        storage.withLock { $0 = provider }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    public static var required: any TaskForkSourcePointerProviding.Type {
        guard let provider = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskForkSourcePointerSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return provider
    }
}
