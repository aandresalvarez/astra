import Foundation
import ASTRACore

public enum TaskOutputArtifactVisibility: String, Hashable {
    case deliverable
    case diagnostic
    case internalState
}

public enum TaskOutputArtifactPathPolicy {
    public enum RelativePathContext {
        case taskFolder
        case workspace
    }

    /// Directories whose contents are machine-generated dependency or cache
    /// trees. Nothing inside one is a user deliverable, in either context.
    ///
    /// The exclusion list below this used to name only ASTRA's own scratch
    /// directories, which held for as long as agents wrote files by hand. One
    /// that ran `python -m venv` inside its task folder produced 14,917 files /
    /// 691 MB, and every artifact pass then treated all of them as output: the
    /// visibility filter pinned the main thread at 100% CPU resolving symlinks
    /// for them, and artifact reconciliation persisted 13,295 `Artifact` rows,
    /// which is what took run finalization from under a second to over ten.
    ///
    /// Matched per path *component* at any depth — a `node_modules` under a
    /// subproject is as generated as one at the root — and only for names that
    /// carry no ambiguity. `target`, `dist`, and `build` are left out on
    /// purpose: a user's own output legitimately lands in those.
    ///
    /// Spelled lowercased because `hasGeneratedDependencyComponent` lowercases
    /// each candidate before looking it up; the volume is usually
    /// case-insensitive, so `DerivedData` and `derivedData` have to compare
    /// equal.
    public static let generatedDependencyDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".gradle",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".swiftpm",
        ".terraform",
        ".tox",
        ".venv",
        "__pycache__",
        "deriveddata",
        "node_modules",
        "pods",
        "site-packages",
        "venv"
    ]

    /// True when any component of `relativePath` names a generated dependency
    /// directory.
    ///
    /// Pure string work, no filesystem access, so it is safe to run ahead of
    /// the symlink-resolving checks on a folder holding five figures of
    /// entries — which is exactly where it earns its keep.
    public static func hasGeneratedDependencyComponent(_ relativePath: String) -> Bool {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty else { return false }
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true)
        where generatedDependencyDirectoryNames.contains(component.lowercased()) {
            return true
        }
        return false
    }

    /// True when `name` is a single path component naming a generated
    /// dependency directory. For directory walkers, which get to prune the
    /// whole subtree rather than filter it entry by entry.
    public static func isGeneratedDependencyDirectoryName(_ name: String) -> Bool {
        generatedDependencyDirectoryNames.contains(name.lowercased())
    }

    /// A root directory with its symlink resolution already paid for.
    ///
    /// `relativePath(_:under:)` compares both the standardized and the
    /// symlink-resolved form of each side, and the root's half of that is
    /// identical for every candidate in a filter pass. Resolving it per call
    /// was half of a main-thread hang: a task folder sits several symlinked
    /// levels deep, so each resolve is a fistful of `getattrlist` calls, paid
    /// once per path classified. Build one of these outside the loop and hand
    /// it to the overload that takes it.
    public struct ResolvedRoot: Hashable, Sendable {
        public let standardized: String
        public let resolved: String

        public init(_ root: String) {
            guard !root.isEmpty else {
                standardized = ""
                resolved = ""
                return
            }
            let url = URL(fileURLWithPath: root)
            standardized = url.standardizedFileURL.path
            resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        public var isEmpty: Bool { standardized.isEmpty }
    }

    public static func normalizedRelativePath(_ relativePath: String) -> String {
        relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func isDisplayableUserArtifactRelativePath(_ relativePath: String) -> Bool {
        displayableUserArtifactRelativePath(relativePath, context: .taskFolder) != nil
    }

    public static func relativeDepth(of relativePath: String) -> Int {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty else { return 0 }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).count - 1
    }

    public static func displayableUserArtifactRelativePath(
        _ relativePath: String,
        context: RelativePathContext = .taskFolder
    ) -> String? {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty,
              visibility(for: normalized, context: context) == .deliverable else {
            return nil
        }
        return normalized
    }

    public static func visibility(
        for relativePath: String,
        context: RelativePathContext = .taskFolder
    ) -> TaskOutputArtifactVisibility {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty else { return .internalState }

        if isInternalStateRelativePath(normalized, context: context) {
            return .internalState
        }
        if isRuntimeDiagnosticRelativePath(normalized, context: context) {
            return .diagnostic
        }
        return .deliverable
    }

    public static func isInternalStateRelativePath(
        _ relativePath: String,
        context: RelativePathContext = .taskFolder
    ) -> Bool {
        let normalized = normalizedRelativePath(relativePath)
        let name = (normalized as NSString).lastPathComponent.lowercased()

        // Applies to both contexts and at any depth, unlike the anchored
        // prefixes below it. See `generatedDependencyDirectoryNames`.
        if hasGeneratedDependencyComponent(normalized) {
            return true
        }

        if normalized == ".astra" || normalized.hasPrefix(".astra/") ||
            normalized == ".agentflow" || normalized.hasPrefix(".agentflow/") ||
            normalized == ".claude" || normalized.hasPrefix(".claude/") {
            return true
        }

        guard context == .taskFolder else { return false }

        if normalized == "session_history.md" ||
            normalized == "outputs" || normalized.hasPrefix("outputs/") ||
            normalized == "turns" || normalized.hasPrefix("turns/") ||
            normalized == "fork_sources/history" || normalized.hasPrefix("fork_sources/history/") {
            return true
        }

        if name == "current_state.json" || name == "current_state.md" {
            return true
        }
        // Matches `TaskForkManifest.fileName` (Astra/Services/Tasks/TaskForkManifestService.swift).
        if name == "fork_manifest.json" {
            return true
        }
        if name.hasPrefix("turn_") && name.hasSuffix(".md") {
            return true
        }
        return false
    }

    public static func isRuntimeDiagnosticRelativePath(_ relativePath: String) -> Bool {
        isRuntimeDiagnosticRelativePath(relativePath, context: .taskFolder)
    }

    public static func isRuntimeDiagnosticRelativePath(
        _ relativePath: String,
        context: RelativePathContext
    ) -> Bool {
        let normalized = normalizedRelativePath(relativePath)
        if normalized == "diagnostics" || normalized.hasPrefix("diagnostics/") {
            return true
        }
        if normalized == "run_resource_manifest.json" ||
            normalized.hasPrefix("run_resource_manifest_") && normalized.hasSuffix(".json") ||
            normalized == "cache/projects.json" {
            return true
        }

        guard context == .taskFolder else { return false }
        return normalized == ".runtime" || normalized.hasPrefix(".runtime/") ||
            normalized == ".runtime-bin" || normalized.hasPrefix(".runtime-bin/") ||
            normalized == "jobs" || normalized.hasPrefix("jobs/")
    }

    public static func displayableUserArtifactPath(
        _ path: String,
        taskFolder: String,
        fileManager: FileManager = .default
    ) -> String? {
        relativePath(path, under: taskFolder, fileManager: fileManager)
            .flatMap { displayableUserArtifactRelativePath($0, context: .taskFolder) }
    }

    public static func isDisplayableUserArtifactPath(
        _ path: String,
        taskFolder: String,
        fileManager: FileManager = .default
    ) -> Bool {
        displayableUserArtifactPath(path, taskFolder: taskFolder, fileManager: fileManager) != nil
    }

    /// Convenience for the one-shot callers. Anything classifying more than a
    /// handful of paths against the same root should build a `ResolvedRoot`
    /// once and use the overload below instead.
    public static func relativePath(
        _ path: String,
        under root: String,
        fileManager: FileManager = .default
    ) -> String? {
        relativePath(path, under: ResolvedRoot(root))
    }

    public static func relativePath(_ path: String, under root: ResolvedRoot) -> String? {
        guard !path.isEmpty, !root.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let standardizedPath = url.standardizedFileURL.path
        // The only filesystem work left in here: the root arrived resolved.
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

        if let relative = relativePath(path: standardizedPath, root: root.standardized),
           relativePath(path: resolvedPath, root: root.resolved) != nil {
            return relative
        }
        if let relative = relativePath(path: resolvedPath, root: root.resolved) {
            return relative
        }
        return nil
    }

    /// The lexical half of `relativePath(_:under:)`: textual containment only,
    /// with no filesystem access and therefore no symlink-escape check.
    ///
    /// For discarding a path cheaply. Anything this admits still has to go
    /// through the resolving form before it is trusted, because a path that
    /// reads as inside the root can resolve to somewhere else entirely.
    public static func lexicalRelativePath(_ path: String, under root: ResolvedRoot) -> String? {
        guard !path.isEmpty, !root.isEmpty else { return nil }
        return relativePath(
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            root: root.standardized
        )
    }

    private static func relativePath(path: String, root: String) -> String? {
        guard path == root || path.hasPrefix(root + "/") else {
            return nil
        }
        if path == root {
            return ""
        }
        return String(path.dropFirst(root.count + 1))
    }
}
