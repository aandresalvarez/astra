import Foundation
import ASTRACore

public enum WorkspaceGeneratedStateExcluder {
    private struct GitRepository {
        public var root: URL
        public var gitDirectory: URL
    }

    public static func ensureExcluded(workspacePath: String, fileManager: FileManager = .default) throws {
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard let repository = gitRepository(containing: workspaceURL, fileManager: fileManager) else { return }

        let generatedStatePattern = generatedStatePattern(
            workspaceURL: workspaceURL,
            repositoryRoot: repository.root
        )
        let excludeURL = commonGitDirectory(for: repository.gitDirectory)
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude")
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

    private static func gitRepository(containing workspaceURL: URL, fileManager: FileManager) -> GitRepository? {
        var current = workspaceURL.standardizedFileURL
        while true {
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory: URL?
                if isDirectory.boolValue {
                    gitDirectory = dotGit
                } else {
                    gitDirectory = resolvedGitFileDirectory(dotGit, repositoryRoot: current)
                }

                if let gitDirectory {
                    return GitRepository(root: current, gitDirectory: gitDirectory)
                }
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }

    private static func generatedStatePattern(workspaceURL: URL, repositoryRoot: URL) -> String {
        let workspacePath = workspaceURL.standardizedFileURL.path
        let rootPath = repositoryRoot.standardizedFileURL.path
        guard workspacePath != rootPath else {
            return "/\(WorkspaceFileLayout.supportDirectoryName)/"
        }

        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard workspacePath.hasPrefix(rootPrefix) else {
            return "/\(WorkspaceFileLayout.supportDirectoryName)/"
        }

        let relativeWorkspacePath = String(workspacePath.dropFirst(rootPrefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativeWorkspacePath.isEmpty else {
            return "/\(WorkspaceFileLayout.supportDirectoryName)/"
        }
        return "/\(escapedGitIgnorePath(relativeWorkspacePath))/\(WorkspaceFileLayout.supportDirectoryName)/"
    }

    private static func escapedGitIgnorePath(_ relativePath: String) -> String {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { escapedGitIgnoreComponent(String($0)) }
            .joined(separator: "/")
    }

    private static func escapedGitIgnoreComponent(_ component: String) -> String {
        var escaped = ""
        for character in component {
            switch character {
            case "\\", "#", "!", "*", "?", "[", "]", " ":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private static func resolvedGitFileDirectory(_ dotGit: URL, repositoryRoot: URL) -> URL? {
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
        return repositoryRoot
            .appendingPathComponent(rawPath, isDirectory: true)
            .standardizedFileURL
    }

    private static func commonGitDirectory(for gitDirectory: URL) -> URL {
        let commonDirURL = gitDirectory.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirURL, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first else {
            return gitDirectory
        }

        let rawPath = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return gitDirectory }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        }
        return gitDirectory
            .appendingPathComponent(rawPath, isDirectory: true)
            .standardizedFileURL
    }
}
