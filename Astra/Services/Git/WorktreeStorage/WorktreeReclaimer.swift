import Darwin
import Foundation
import ASTRACore

/// What one reclaim or sweep pass did. Typed so the service, the UI and tests
/// read the same facts the log records.
struct WorktreeReclaimOutcome: Equatable, Sendable {
    struct Reclaimed: Equatable, Sendable {
        let path: String
        let bytes: Int64
    }

    struct Skipped: Equatable, Sendable {
        let path: String
        let reason: String
    }

    struct Failure: Equatable, Sendable {
        let path: String
        let message: String
    }

    var reclaimed: [Reclaimed] = []
    var skipped: [Skipped] = []
    var failures: [Failure] = []

    var freedBytes: Int64 { reclaimed.reduce(0) { $0 + $1.bytes } }

    mutating func merge(_ other: WorktreeReclaimOutcome) {
        reclaimed += other.reclaimed
        skipped += other.skipped
        failures += other.failures
    }
}

/// The only code in ASTRA that deletes build artifacts. Every artifact is
/// re-validated immediately before it is touched, so a stale measurement can
/// never widen what gets deleted. Idempotent: a second pass over the same
/// paths finds nothing to do and frees zero bytes.
struct WorktreeReclaimer: Sendable {
    var rules: [WorktreeArtifactRule] = WorktreeArtifactRule.all
    var probe = WorktreeActivityProbe()

    /// Reclaims the given artifact directories of one worktree. Synchronous and
    /// slow on large trees; run it off the main actor.
    func reclaim(artifactPaths: [String], inWorktree worktreePath: String, now: Date = Date()) -> WorktreeReclaimOutcome {
        var outcome = WorktreeReclaimOutcome()
        guard let root = WorktreePath.realPath(worktreePath) else {
            for path in artifactPaths {
                outcome.skipped.append(.init(path: path, reason: "worktree is missing"))
            }
            return outcome
        }
        for path in artifactPaths {
            outcome.merge(reclaimArtifact(at: path, canonicalRoot: root, worktreePath: worktreePath, now: now))
        }
        return outcome
    }

    /// Deletes `<artifact>.astra-reclaiming-<uuid>` directories an interrupted
    /// pass left behind. Only exact leftover names of a known rule, strictly
    /// inside the worktree and never through a symlink, are touched.
    func sweepLeftovers(_ leftoverPaths: [String], inWorktree worktreePath: String) -> WorktreeReclaimOutcome {
        var outcome = WorktreeReclaimOutcome()
        guard let root = WorktreePath.realPath(worktreePath) else { return outcome }
        let artifactNames = Set(rules.map(\.directoryName))
        for path in leftoverPaths {
            let name = (path as NSString).lastPathComponent
            guard let base = WorktreeFileSystem.reclaimLeftoverBaseName(name), artifactNames.contains(base),
                  WorktreeFileSystem.isRealDirectory(path),
                  let canonical = WorktreePath.realPath(path),
                  WorktreePath.isStrictlyInside(canonical, root: root) else {
                outcome.merge(skip(path, worktreePath: worktreePath, "not a reclaim leftover inside the worktree"))
                continue
            }
            outcome.merge(delete(canonical, originalPath: path, worktreePath: worktreePath, reason: "finished an interrupted reclaim"))
        }
        return outcome
    }

    private func reclaimArtifact(
        at path: String,
        canonicalRoot: String,
        worktreePath: String,
        now: Date
    ) -> WorktreeReclaimOutcome {
        func skip(_ reason: String) -> WorktreeReclaimOutcome {
            self.skip(path, worktreePath: worktreePath, reason)
        }
        // 1. A real directory, strictly inside the worktree, still anchored by
        //    its manifest. A symlinked artifact is refused outright.
        guard !WorktreeFileSystem.isSymbolicLink(path), WorktreeFileSystem.isRealDirectory(path) else {
            return skip("not a real directory")
        }
        guard let canonical = WorktreePath.realPath(path),
              WorktreePath.isStrictlyInside(canonical, root: canonicalRoot) else {
            return skip("outside the worktree")
        }
        guard let rule = WorktreeArtifactRule.rule(matchingDirectoryAtPath: canonical, in: rules) else {
            return skip("no longer next to its manifest")
        }

        // 2. TOCTOU guard: re-probe right before acting, then hold SwiftPM's
        //    lock(s) across the rename so a build that starts meanwhile waits
        //    and then sees a clean tree.
        if let signal = probe.buildSignal(forArtifactAt: canonical, rule: rule, now: now) {
            return skip(signal.summary)
        }
        var heldLocks: [SwiftPMWorkspaceLock.HeldLock] = []
        defer { heldLocks.forEach { $0.release() } }
        if rule.ecosystem == .swiftPM {
            for scratch in SwiftPMWorkspaceLock.guardedScratchPaths(forArtifactAt: canonical) {
                let lockFile = SwiftPMWorkspaceLock.lockFileURL(
                    forScratchPath: scratch,
                    temporaryDirectory: probe.temporaryDirectory
                )
                guard let lock = SwiftPMWorkspaceLock.tryAcquire(lockFile: lockFile) else {
                    return skip(WorktreeBuildSignal.swiftPMLockHeld(lockPath: lockFile.path).summary)
                }
                heldLocks.append(lock)
            }
        }

        // 3. Atomically rename it aside in the same directory.
        let parent = (canonical as NSString).deletingLastPathComponent
        let asideName = rule.directoryName + WorktreeFileSystem.reclaimingMarker + UUID().uuidString
        let aside = (parent as NSString).appendingPathComponent(asideName)
        guard rename(canonical, aside) == 0 else {
            let message = String(cString: strerror(errno))
            log("failed", path: path, worktreePath: worktreePath, fields: ["reason": "rename: \(message)"], level: .warning)
            return WorktreeReclaimOutcome(failures: [.init(path: path, message: message)])
        }
        heldLocks.forEach { $0.release() }
        heldLocks.removeAll()

        // 4. Delete it for good. Trash would free nothing.
        return delete(aside, originalPath: path, worktreePath: worktreePath, reason: "idle build artifacts")
    }

    private func delete(
        _ path: String,
        originalPath: String,
        worktreePath: String,
        reason: String
    ) -> WorktreeReclaimOutcome {
        let bytes = WorktreeStorageInspector.allocatedBytes(under: path)
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            log("failed", path: originalPath, worktreePath: worktreePath, fields: ["reason": error.localizedDescription], level: .warning)
            return WorktreeReclaimOutcome(failures: [.init(path: originalPath, message: error.localizedDescription)])
        }
        log("reclaimed", path: originalPath, worktreePath: worktreePath, fields: ["bytes": "\(bytes)", "reason": reason], level: .info)
        return WorktreeReclaimOutcome(reclaimed: [.init(path: originalPath, bytes: bytes)])
    }

    private func skip(_ path: String, worktreePath: String, _ reason: String) -> WorktreeReclaimOutcome {
        log("skipped", path: path, worktreePath: worktreePath, fields: ["reason": reason], level: .debug)
        return WorktreeReclaimOutcome(skipped: [.init(path: path, reason: reason)])
    }

    /// Logs the worktree's folder name and the artifact's path inside it: the
    /// log sanitizer redacts absolute paths.
    private func log(_ result: String, path: String, worktreePath: String, fields: [String: String], level: LogLevel) {
        var all = fields
        all["result"] = result
        all["worktree"] = (worktreePath as NSString).lastPathComponent
        let root = worktreePath.hasSuffix("/") ? worktreePath : worktreePath + "/"
        all["artifact"] = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : (path as NSString).lastPathComponent
        AppLogger.audit(.gitWorktreeReclaim, category: "Git", fields: all, level: level, fieldMaxLength: 400)
    }
}
