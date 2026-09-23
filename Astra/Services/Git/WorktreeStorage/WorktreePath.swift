import Darwin
import Foundation
import ASTRACore

/// Path identity for worktrees. Git reports fully resolved paths
/// (`/private/var/...`), while a task's `executionRootPath` is only
/// tilde-expanded and standardized, and imported or copied values aren't
/// normalized at all — so raw `==` misses real matches.
enum WorktreePath {
    /// `realpath(3)`: every symlink resolved, `/private` spelling kept. Nil when
    /// the path doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Canonical spelling for comparisons, including paths that no longer
    /// exist on disk.
    static func canonical(_ path: String) -> String {
        if let real = realPath(path) { return real }
        return ExecutionSandbox.canonicalize(path) ?? WorkspacePathPresentation.standardizedPath(path)
    }

    /// True when two spellings name the same location, including symlink
    /// aliases whose final components differ (`/repos/current` →
    /// `/Volumes/worktrees/feature`). Callers comparing one path against many
    /// canonicalize once instead (see `WorktreeScope`).
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = WorkspacePathPresentation.standardizedPath(lhs)
        let right = WorkspacePathPresentation.standardizedPath(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || canonical(left) == canonical(right)
    }

    /// The checkout containing `path`: the nearest directory at or above it
    /// that holds a `.git` entry (a directory for a primary checkout, a file
    /// for a linked worktree). Nil when there is none. Spelled like `path`.
    static func containingCheckoutRoot(of path: String) -> String? {
        // Not `standardizedPath`: it rewrites `/private/var` as `/var`, and
        // the result must keep git's spelling to match its worktree list.
        var directory = (path as NSString).expandingTildeInPath
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        while !directory.isEmpty, directory != "/" {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            if WorktreeFileSystem.isRealDirectory(dotGit) || WorktreeFileSystem.isFile(dotGit) {
                return directory
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// True when `path` is strictly inside `root`. Both must already be
    /// canonical.
    static func isStrictlyInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.count > prefix.count && path.hasPrefix(prefix)
    }
}

/// The locations a worktree owns: its root and everything under it, except
/// other worktrees nested inside it (the primary checkout contains
/// `.claude/worktrees/*`). Canonicalizes once, so matching many task paths
/// against it is cheap.
struct WorktreeScope {
    let root: String
    private let nested: [String]

    init(path: String, otherWorktreePaths: [String] = []) {
        let root = WorktreePath.canonical(path)
        self.root = root
        nested = otherWorktreePaths
            .map(WorktreePath.canonical)
            .filter { WorktreePath.isStrictlyInside($0, root: root) }
    }

    /// Whether an already-canonical path falls inside this worktree.
    func contains(canonicalPath path: String) -> Bool {
        guard path == root || WorktreePath.isStrictlyInside(path, root: root) else { return false }
        return !nested.contains { path == $0 || WorktreePath.isStrictlyInside(path, root: $0) }
    }
}
