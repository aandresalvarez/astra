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

    /// True when two spellings name the same location. String checks come
    /// first; symlinks are resolved only when the final components agree, so
    /// comparing one worktree against many task paths stays cheap.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = WorkspacePathPresentation.standardizedPath(lhs)
        let right = WorkspacePathPresentation.standardizedPath(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        guard (left as NSString).lastPathComponent == (right as NSString).lastPathComponent else { return false }
        return canonical(left) == canonical(right)
    }

    /// True when `path` is strictly inside `root`. Both must already be
    /// canonical.
    static func isStrictlyInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.count > prefix.count && path.hasPrefix(prefix)
    }
}
