import Foundation

/// Read-only probes of a Git checkout's on-disk layout. Paths are standardized
/// but not symlink-resolved, matching the keys admission claims use.
public enum GitCheckoutLayout {
    /// The nearest directory at or above `path` that holds a `.git` entry.
    public static func worktreeRoot(containing path: String) -> String? {
        guard let standardized = standardizedPath(path) else { return nil }
        var candidate = URL(fileURLWithPath: standardized, isDirectory: true)
        while true {
            let dotGit = candidate.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: dotGit) {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    /// The Git directory every worktree of the checkout containing `path`
    /// shares: refs, objects, and config. A main checkout's own `.git`
    /// directory is its common directory.
    ///
    /// Like Git's own discovery, a Git directory with no `.git` entry of its
    /// own, such as a submodule's `.git/modules/<name>`, is its own
    /// repository rather than part of the one that stores it.
    public static func commonDirectory(for path: String) -> String? {
        guard let standardized = standardizedPath(path) else { return nil }
        var candidate = URL(fileURLWithPath: standardized, isDirectory: true)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return commonDirectory(ofWorktreeRoot: candidate.path)
            }
            if let common = commonDirectory(ofGitDirectory: candidate.path) { return common }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    /// The common directory of `path` when it is itself a Git directory: a
    /// `HEAD` file and, directly or through `commondir`, objects and refs.
    public static func commonDirectory(ofGitDirectory path: String) -> String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("HEAD"), isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        var common = path
        if let raw = try? String(contentsOfFile: (path as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
            guard let resolved = resolvedGitPath(raw, relativeTo: path) else { return nil }
            common = resolved
        }
        for name in ["objects", "refs"] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: (common as NSString).appendingPathComponent(name), isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
        }
        return standardizedPath(common)
    }

    private static func commonDirectory(ofWorktreeRoot worktreeRoot: String) -> String? {
        let dotGit = (worktreeRoot as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory)
        let resolvedGitDirectory = isDirectory.boolValue
            ? standardizedPath(dotGit)
            : linkedWorktreeGitDirectory(at: dotGit, root: worktreeRoot)
        guard let gitDirectory = resolvedGitDirectory else { return nil }
        // `commondir` exists only inside a linked worktree's admin directory
        // and normally holds a path relative to it (`../..`).
        let commonDirFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let raw = try? String(contentsOfFile: commonDirFile, encoding: .utf8) else {
            return gitDirectory
        }
        return resolvedGitPath(raw, relativeTo: gitDirectory) ?? gitDirectory
    }

    private static func linkedWorktreeGitDirectory(at dotGitFile: String, root: String) -> String? {
        guard let raw = try? String(contentsOfFile: dotGitFile, encoding: .utf8),
              raw.lowercased().hasPrefix("gitdir:") else {
            return nil
        }
        return resolvedGitPath(String(raw.dropFirst("gitdir:".count)), relativeTo: root)
    }

    private static func resolvedGitPath(_ rawValue: String, relativeTo base: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return standardizedPath(value.hasPrefix("/") ? value : (base as NSString).appendingPathComponent(value))
    }

    private static func standardizedPath(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
