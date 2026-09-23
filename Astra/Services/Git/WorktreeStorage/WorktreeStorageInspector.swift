import Foundation

/// One measured build-artifact directory inside a worktree.
struct WorktreeArtifactMeasurement: Hashable, Sendable {
    let path: String
    /// Path relative to the worktree root, e.g. `Tests/ArchitectureFitnessTests/.build`.
    let relativePath: String
    let rule: WorktreeArtifactRule
    let bytes: Int64
}

/// What a worktree occupies on disk and how much of it is regenerable.
struct WorktreeStorageReport: Equatable, Sendable {
    let worktreePath: String
    let artifacts: [WorktreeArtifactMeasurement]
    /// `<artifact>.astra-reclaiming-<uuid>` directories left by an interrupted
    /// reclaim. The next pass deletes them.
    let interruptedReclaims: [String]
    /// Bytes in matched artifacts.
    let artifactBytes: Int64
    /// Everything under the worktree except `.git` and nested checkouts.
    let totalBytes: Int64
    /// False when the worktree directory is gone (git reports it prunable).
    let exists: Bool
    let measuredAt: Date

    static func missing(worktreePath: String, at date: Date) -> WorktreeStorageReport {
        WorktreeStorageReport(
            worktreePath: worktreePath,
            artifacts: [],
            interruptedReclaims: [],
            artifactBytes: 0,
            totalBytes: 0,
            exists: false,
            measuredAt: date
        )
    }
}

/// Measures worktrees; never modifies anything. The walk is synchronous and
/// can take seconds on a multi-gigabyte `.build`, so callers run it off the
/// main actor (see `WorktreeStorageWork`).
struct WorktreeStorageInspector: Sendable {
    var rules: [WorktreeArtifactRule] = WorktreeArtifactRule.all

    private static let walkKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
    ]

    /// Walks the worktree once. Matched artifacts are measured as a unit and
    /// not descended into; `.git`, nested checkouts (any directory holding its
    /// own `.git`, such as `.claude/worktrees/*`) and symlinks are skipped, so
    /// nothing is attributed to the wrong worktree or counted twice.
    func inspect(worktreePath: String, now: Date = Date()) -> WorktreeStorageReport {
        guard WorktreeFileSystem.isRealDirectory(worktreePath) else {
            return .missing(worktreePath: worktreePath, at: now)
        }
        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
        var artifacts: [WorktreeArtifactMeasurement] = []
        var leftovers: [String] = []
        var otherBytes: Int64 = 0
        var leftoverBytes: Int64 = 0

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Self.walkKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return .missing(worktreePath: worktreePath, at: now)
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(Self.walkKeys))
            // The enumerator never descends into a symlink. Don't call
            // `skipDescendants()` here: it applies to the most recent
            // *directory*, so it would skip the next real one.
            if values?.isSymbolicLink == true { continue }
            guard values?.isDirectory == true else {
                if values?.isRegularFile == true { otherBytes += Self.allocatedSize(values) }
                continue
            }
            let path = url.path
            let name = url.lastPathComponent
            if name == ".git" || Self.isNestedCheckout(path) {
                enumerator.skipDescendants()
            } else if WorktreeFileSystem.reclaimLeftoverBaseName(name) != nil {
                leftovers.append(path)
                leftoverBytes += Self.allocatedBytes(under: path)
                enumerator.skipDescendants()
            } else if let rule = WorktreeArtifactRule.rule(matchingDirectoryAtPath: path, in: rules) {
                artifacts.append(WorktreeArtifactMeasurement(
                    path: path,
                    relativePath: Self.relativePath(of: path, root: root.path),
                    rule: rule,
                    bytes: Self.allocatedBytes(under: path)
                ))
                enumerator.skipDescendants()
            }
        }

        let artifactBytes = artifacts.reduce(Int64(0)) { $0 + $1.bytes }
        return WorktreeStorageReport(
            worktreePath: worktreePath,
            artifacts: artifacts.sorted { $0.relativePath < $1.relativePath },
            interruptedReclaims: leftovers.sorted(),
            artifactBytes: artifactBytes,
            totalBytes: artifactBytes + otherBytes + leftoverBytes,
            exists: true,
            measuredAt: now
        )
    }

    /// Allocated bytes of every regular file under `path`, never following a
    /// symlink, so a link into another tree adds nothing.
    static func allocatedBytes(under path: String) -> Int64 {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Symlinks are listed but never descended into; count real files only.
            if values?.isSymbolicLink != true, values?.isRegularFile == true {
                total += allocatedSize(values)
            }
        }
        return total
    }

    private static func allocatedSize(_ values: URLResourceValues?) -> Int64 {
        Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private static func isNestedCheckout(_ directoryPath: String) -> Bool {
        let dotGit = (directoryPath as NSString).appendingPathComponent(".git")
        return WorktreeFileSystem.isRealDirectory(dotGit) || WorktreeFileSystem.isFile(dotGit)
            || WorktreeFileSystem.isSymbolicLink(dotGit)
    }

    private static func relativePath(of path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
