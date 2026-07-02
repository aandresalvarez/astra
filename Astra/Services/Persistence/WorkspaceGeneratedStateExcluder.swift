import Foundation

enum WorkspaceGeneratedStateExcluder {
    private static let generatedStatePattern = "\(WorkspaceFileLayout.supportDirectoryName)/"

    static func ensureExcluded(workspacePath: String, fileManager: FileManager = .default) throws {
        guard let excludeURL = gitInfoExcludeURL(workspacePath: workspacePath, fileManager: fileManager) else { return }
        try fileManager.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        guard !existing
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .contains(generatedStatePattern) else {
            return
        }

        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += "\(generatedStatePattern)\n"
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private static func gitInfoExcludeURL(workspacePath: String, fileManager: FileManager) -> URL? {
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let dotGit = workspaceURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }

        let gitDirectory: URL?
        if isDirectory.boolValue {
            gitDirectory = dotGit
        } else {
            gitDirectory = resolvedGitFileDirectory(dotGit, workspaceURL: workspaceURL)
        }
        return gitDirectory?
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude")
    }

    private static func resolvedGitFileDirectory(_ dotGit: URL, workspaceURL: URL) -> URL? {
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first,
              line.lowercased().hasPrefix("gitdir:") else {
            return nil
        }

        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        }
        return workspaceURL
            .appendingPathComponent(rawPath, isDirectory: true)
            .standardizedFileURL
    }
}
