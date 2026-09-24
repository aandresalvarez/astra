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

    /// An artifact already renamed aside, waiting to be deleted.
    struct Prepared: Equatable, Sendable {
        let originalPath: String
        let asidePath: String
        let worktreePath: String
    }

    /// Reclaims the given artifact directories of one worktree. Synchronous and
    /// slow on large trees; run it off the main actor.
    func reclaim(artifactPaths: [String], inWorktree worktreePath: String, now: Date = Date()) -> WorktreeReclaimOutcome {
        var (prepared, outcome) = prepare(artifactPaths: artifactPaths, inWorktree: worktreePath, now: now)
        outcome.merge(finish(prepared))
        return outcome
    }

    /// The fast half: validates each artifact, then renames it aside under
    /// SwiftPM's lock. Nothing is deleted yet, so a caller can prepare every
    /// artifact right after its last in-use check and delete afterwards.
    /// A caller that already ran the full build-activity scan off the main
    /// actor passes `quickActivityCheck: true`: the check right before the
    /// rename then scans only as deep as `quickScanDepth(for:)`, so it stays
    /// cheap on the main actor while still catching a build that started
    /// since, including Cargo and npm, which have no lock to take.
    func prepare(
        artifactPaths: [String],
        inWorktree worktreePath: String,
        now: Date = Date(),
        quickActivityCheck: Bool = false
    ) -> (prepared: [Prepared], outcome: WorktreeReclaimOutcome) {
        var outcome = WorktreeReclaimOutcome()
        guard let root = WorktreePath.realPath(worktreePath) else {
            for path in artifactPaths {
                outcome.skipped.append(.init(path: path, reason: "worktree is missing"))
            }
            return ([], outcome)
        }
        var prepared: [Prepared] = []
        for path in artifactPaths {
            let (aside, result) = prepareArtifact(
                at: path,
                canonicalRoot: root,
                worktreePath: worktreePath,
                now: now,
                quickActivityCheck: quickActivityCheck
            )
            if let aside { prepared.append(aside) }
            outcome.merge(result)
        }
        return (prepared, outcome)
    }

    /// The slow half: deletes what `prepare` renamed aside.
    func finish(_ prepared: [Prepared]) -> WorktreeReclaimOutcome {
        var outcome = WorktreeReclaimOutcome()
        for item in prepared {
            outcome.merge(delete(
                item.asidePath,
                originalPath: item.originalPath,
                worktreePath: item.worktreePath,
                reason: "idle build artifacts"
            ))
        }
        return outcome
    }

    /// Deletes `<artifact>.astra-reclaiming-<uuid>` directories an interrupted
    /// pass left behind. Only exact leftover names of a known rule, still next
    /// to that rule's manifest, strictly inside the worktree and never through
    /// a symlink, are touched.
    func sweepLeftovers(_ leftoverPaths: [String], inWorktree worktreePath: String) -> WorktreeReclaimOutcome {
        var outcome = WorktreeReclaimOutcome()
        guard let root = WorktreePath.realPath(worktreePath) else { return outcome }
        for path in leftoverPaths {
            guard !WorktreeFileSystem.isSymbolicLink(path),
                  WorktreeArtifactRule.rule(matchingLeftoverAtPath: path, in: rules) != nil,
                  let canonical = WorktreePath.realPath(path),
                  WorktreePath.isStrictlyInside(canonical, root: root) else {
                outcome.merge(skip(path, worktreePath: worktreePath, "not a reclaim leftover inside the worktree"))
                continue
            }
            outcome.merge(delete(canonical, originalPath: path, worktreePath: worktreePath, reason: "finished an interrupted reclaim"))
        }
        return outcome
    }

    private func prepareArtifact(
        at path: String,
        canonicalRoot: String,
        worktreePath: String,
        now: Date,
        quickActivityCheck: Bool
    ) -> (Prepared?, WorktreeReclaimOutcome) {
        func skip(_ reason: String) -> (Prepared?, WorktreeReclaimOutcome) {
            (nil, self.skip(path, worktreePath: worktreePath, reason))
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
        let scanDepth = quickActivityCheck
            ? WorktreeActivityProbe.quickScanDepth(for: rule)
            : WorktreeActivityProbe.shallowScanDepth
        if let signal = probe.buildSignal(forArtifactAt: canonical, rule: rule, now: now, scanDepth: scanDepth) {
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
            return (nil, WorktreeReclaimOutcome(failures: [.init(path: path, message: message)]))
        }
        // 4. `finish` deletes it for good. Trash would free nothing.
        return (Prepared(originalPath: path, asidePath: aside, worktreePath: worktreePath), WorktreeReclaimOutcome())
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
