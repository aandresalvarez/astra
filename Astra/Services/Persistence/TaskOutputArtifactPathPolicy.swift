import Foundation

enum TaskOutputArtifactPathPolicy {
    static func normalizedRelativePath(_ relativePath: String) -> String {
        relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isDisplayableUserArtifactRelativePath(_ relativePath: String) -> Bool {
        displayableUserArtifactRelativePath(relativePath) != nil
    }

    static func displayableUserArtifactRelativePath(_ relativePath: String) -> String? {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty,
              !isRuntimeDiagnosticRelativePath(normalized),
              TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: normalized) else {
            return nil
        }
        return normalized
    }

    static func isRuntimeDiagnosticRelativePath(_ relativePath: String) -> Bool {
        let normalized = normalizedRelativePath(relativePath)
        return normalized == "diagnostics"
            || normalized.hasPrefix("diagnostics/")
            || normalized == "cache/projects.json"
            || normalized.hasPrefix(".astra/")
            || normalized.hasPrefix(".agentflow/")
            || normalized.hasPrefix(".claude/")
    }
}
