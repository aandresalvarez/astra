import Foundation

enum TaskOutputArtifactVisibility: String, Hashable {
    case deliverable
    case diagnostic
    case internalState
}

enum TaskOutputArtifactPathPolicy {
    enum RelativePathContext {
        case taskFolder
        case workspace
    }

    static func normalizedRelativePath(_ relativePath: String) -> String {
        relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isDisplayableUserArtifactRelativePath(_ relativePath: String) -> Bool {
        displayableUserArtifactRelativePath(relativePath, context: .taskFolder) != nil
    }

    static func relativeDepth(of relativePath: String) -> Int {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty else { return 0 }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).count - 1
    }

    static func displayableUserArtifactRelativePath(
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

    static func visibility(
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

    static func isInternalStateRelativePath(
        _ relativePath: String,
        context: RelativePathContext = .taskFolder
    ) -> Bool {
        let normalized = normalizedRelativePath(relativePath)
        let name = (normalized as NSString).lastPathComponent.lowercased()

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
        if name == TaskForkManifest.fileName {
            return true
        }
        if name.hasPrefix("turn_") && name.hasSuffix(".md") {
            return true
        }
        return false
    }

    static func isRuntimeDiagnosticRelativePath(_ relativePath: String) -> Bool {
        isRuntimeDiagnosticRelativePath(relativePath, context: .taskFolder)
    }

    static func isRuntimeDiagnosticRelativePath(
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
            normalized == ".local-agent" || normalized.hasPrefix(".local-agent/") ||
            normalized == "jobs" || normalized.hasPrefix("jobs/")
    }

    static func displayableUserArtifactPath(
        _ path: String,
        taskFolder: String,
        fileManager: FileManager = .default
    ) -> String? {
        relativePath(path, under: taskFolder, fileManager: fileManager)
            .flatMap { displayableUserArtifactRelativePath($0, context: .taskFolder) }
    }

    static func isDisplayableUserArtifactPath(
        _ path: String,
        taskFolder: String,
        fileManager: FileManager = .default
    ) -> Bool {
        displayableUserArtifactPath(path, taskFolder: taskFolder, fileManager: fileManager) != nil
    }

    static func relativePath(
        _ path: String,
        under root: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard !path.isEmpty, !root.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let rootURL = URL(fileURLWithPath: root)
        let standardizedPath = url.standardizedFileURL.path
        let standardizedRoot = rootURL.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard (standardizedPath == standardizedRoot || standardizedPath.hasPrefix(standardizedRoot + "/")),
              (resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")) else {
            return nil
        }
        if standardizedPath == standardizedRoot {
            return ""
        }
        return String(standardizedPath.dropFirst(standardizedRoot.count + 1))
    }
}
