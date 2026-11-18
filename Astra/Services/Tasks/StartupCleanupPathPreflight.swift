import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Touches, off the main actor, the folders and mirror files the startup
/// credential cleanup is about to read on it.
///
/// Those passes stay synchronous on the main actor, so each decides ownership
/// from one consistent read of the store. Their file work can wait on things
/// ASTRA doesn't control, though. A new build's first read inside a protected
/// folder such as Documents raises a macOS privacy prompt and blocks until it
/// is answered, and a slow or unresponsive volume can stall a stat. Done here
/// first, that wait holds a background thread while the app keeps responding;
/// once it returns, the prompt's answer is cached and the passes read paths
/// that just answered.
///
/// Read-only and idempotent: it reads metadata and the small mirror files,
/// keeps nothing, and decides nothing.
enum StartupCleanupPathPreflight {
    struct Paths: Equatable, Sendable {
        /// Walked to the root as the deletion pass checks a pinned folder.
        var folders: [String] = []
        /// Stat'd and read as the mirror readers read them.
        var files: [String] = []
        var isEmpty: Bool { folders.isEmpty && files.isEmpty }
    }

    /// What the next passes read: each pending deletion's pinned mirrors,
    /// their folders, and the moved mirrors it may remove, plus every stored
    /// workspace's mirror and the mirrors recovery loaded, which the
    /// ownership reads load.
    @MainActor
    static func paths(
        modelContext: ModelContext, store: WorkspaceDeletionCleanupStore? = nil,
        movedMirrors: [String] = [], extraMirrors: [String]? = nil
    ) -> Paths {
        let pending = (store ?? WorkspaceDeletionCleanupStore(for: modelContext)).pending()
        let stored = ((try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? [])
            .filter { !$0.primaryPath.isEmpty }
        let pinned = pending.flatMap(\.mirrorFiles)
        let storedMirrors = stored.flatMap {
            [WorkspaceFileLayout.workspaceConfigFile(for: $0.primaryPath),
             WorkspaceFileLayout.legacyWorkspaceConfigFile(for: $0.primaryPath)]
        }
        let files = pinned + movedMirrors + storedMirrors + (extraMirrors ?? WorkspaceRecoveryTrust.loadedMirrors)
        let folders = (pinned + storedMirrors).map { ($0 as NSString).deletingLastPathComponent }
        return Paths(folders: unique(folders), files: unique(files))
    }

    private static let queue = DispatchQueue(label: "com.coral.astra.startup-cleanup-preflight", qos: .utility)

    /// Walks `paths.folders` and reads `paths.files` on a dedicated queue,
    /// never the cooperative pool a blocked read would starve, and returns
    /// once every one has returned, however long that takes. The caller
    /// awaits it, so the main actor stays free while a prompt is up.
    static func run(
        _ paths: Paths,
        walk: @escaping @Sendable (String) -> Void = { _ = WorkspaceDeletionCleanupService.pinnedFolderState($0) },
        read: @escaping @Sendable (String) -> Void = { path in
            _ = try? WorkspaceFileLayout.itemIdentityConfirmingAbsence(at: path)
            _ = try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    ) async {
        guard !paths.isEmpty else { return }
        let counts = ["folder_count": String(paths.folders.count), "file_count": String(paths.files.count)]
        audit("startup_cleanup_preflight_started", counts)
        let start = DispatchTime.now().uptimeNanoseconds
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                paths.folders.forEach(walk)
                paths.files.forEach(read)
                continuation.resume()
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        audit("startup_cleanup_preflight", counts.merging(["duration_ms": String(format: "%.2f", elapsed)]) { _, new in new })
    }

    private static func audit(_ event: String, _ fields: [String: String]) {
        AuditLoggingSeam.required.audit(.workspaceExported, category: "Performance", fields: fields.merging([
            "event": event, "launch_age_ms": LaunchDiagnosticClock.ageMilliseconds()
        ]) { _, new in new }, level: .info)
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
