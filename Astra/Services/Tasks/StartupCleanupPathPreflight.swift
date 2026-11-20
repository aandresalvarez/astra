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
/// Read-only and idempotent: it reads metadata and the mirror files the
/// passes would read, keeps nothing, and decides nothing.
enum StartupCleanupPathPreflight {
    struct Paths: Equatable, Sendable {
        /// Walked to the root as the deletion pass checks a pinned folder.
        var folders: [String] = []
        /// Identified by metadata alone, as the deletion pass identifies a
        /// mirror before unlinking it. Never opened, so a link at that path
        /// is not followed.
        var identified: [String] = []
        /// Read as the ownership reader reads them: each list in order,
        /// stopping at the first file that is there, so a legacy mirror is
        /// opened only when the current one is missing.
        var read: [[String]] = []
        var isEmpty: Bool { folders.isEmpty && identified.isEmpty && read.isEmpty }
    }

    /// What the next passes touch: each pending deletion's pinned mirrors and
    /// their folders, the moved mirrors it may remove, every workspace's
    /// mirror, and the mirrors recovery loaded.
    ///
    /// Workspaces come from the saved store as well as the caller's context,
    /// as `CredentialRecoveryMirrors.read` fetches them: an unsaved folder
    /// edit doesn't hide the stored location from that reader. Only paths
    /// leave the saved context.
    @MainActor
    static func paths(
        modelContext: ModelContext, store: WorkspaceDeletionCleanupStore? = nil,
        movedMirrors: [String] = [], extraMirrors: [String]? = nil
    ) -> Paths {
        let pinned = (store ?? WorkspaceDeletionCleanupStore(for: modelContext)).pending().flatMap(\.mirrorFiles)
        let roots = unique([ModelContext(modelContext.container), modelContext].flatMap {
            ((try? $0.fetch(FetchDescriptor<Workspace>())) ?? []).map(\.primaryPath)
        })
        let own = roots.map {
            unique([WorkspaceFileLayout.workspaceConfigFile(for: $0),
                    WorkspaceFileLayout.legacyWorkspaceConfigFile(for: $0)])
        }
        let ownFiles = Set(own.joined())
        // A moved mirror is identified, and read when that identity wasn't
        // pinned; recovery has already read it this launch.
        let others = unique(movedMirrors + (extraMirrors ?? WorkspaceRecoveryTrust.loadedMirrors))
            .filter { !ownFiles.contains($0) }
        return Paths(
            folders: unique((pinned + own.joined()).map { ($0 as NSString).deletingLastPathComponent }),
            identified: unique(pinned + movedMirrors),
            read: own + others.map { [$0] }
        )
    }

    private static let queue = DispatchQueue(label: "com.coral.astra.startup-cleanup-preflight", qos: .utility)

    /// Touches `paths` on a dedicated queue, never the cooperative pool a
    /// blocked read would starve, and returns once every touch has returned,
    /// however long that takes. The caller awaits it, so the main actor stays
    /// free while a prompt is up. `read` returns whether the file is
    /// confirmed missing, which is when its list's next file is read.
    static func run(
        _ paths: Paths,
        walk: @escaping @Sendable (String) -> Void = { _ = WorkspaceDeletionCleanupService.pinnedFolderState($0) },
        identify: @escaping @Sendable (String) -> Void = {
            _ = try? WorkspaceFileLayout.itemIdentityConfirmingAbsence(at: $0)
        },
        read: @escaping @Sendable (String) -> Bool = { StartupCleanupPathPreflight.isMissingAfterReading($0) }
    ) async {
        guard !paths.isEmpty else { return }
        let counts = ["folder_count": String(paths.folders.count),
                      "file_count": String(Set(paths.identified).union(paths.read.joined()).count)]
        audit("startup_cleanup_preflight_started", counts)
        let start = DispatchTime.now().uptimeNanoseconds
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                paths.folders.forEach(walk)
                paths.identified.forEach(identify)
                for candidates in paths.read { _ = candidates.first { !read($0) } }
                continuation.resume()
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        audit("startup_cleanup_preflight", counts.merging(["duration_ms": String(format: "%.2f", elapsed)]) { _, new in new })
    }

    /// Reads a mirror as the ownership reader does. True only for a file
    /// confirmed missing; one that is there, or can't be read, ends its list.
    static func isMissingAfterReading(_ path: String) -> Bool {
        do {
            _ = try Data(contentsOf: URL(fileURLWithPath: path))
            return false
        } catch {
            return WorkspaceFileLayout.isMissingFile(error)
        }
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
