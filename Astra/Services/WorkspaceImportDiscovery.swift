import Foundation

struct WorkspaceImportCandidate: Equatable {
    var folderURL: URL
    var configURL: URL?

    var displayName: String {
        folderURL.lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

enum WorkspaceImportDiscovery {
    static let legacyAgentFlowConfigFileName = ".agentflow-workspace.json"

    static func candidates(
        for urls: [URL],
        fileManager: FileManager = .default
    ) -> [WorkspaceImportCandidate] {
        var seen = Set<String>()
        var results: [WorkspaceImportCandidate] = []

        for url in urls {
            for candidate in candidates(for: url, fileManager: fileManager) {
                let path = normalizedPath(candidate.folderURL)
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                results.append(candidate)
            }
        }

        return results
    }

    static func candidates(
        for url: URL,
        fileManager: FileManager = .default
    ) -> [WorkspaceImportCandidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "json" else { return [] }
            return [WorkspaceImportCandidate(folderURL: url.deletingLastPathComponent(), configURL: url)]
        }

        if let direct = configuredWorkspaceCandidate(for: url, fileManager: fileManager) {
            return [direct]
        }

        let directChildren = childDirectories(in: url, fileManager: fileManager)
        let importsChildrenByConvention = url.lastPathComponent.localizedCaseInsensitiveCompare("Workspaces") == .orderedSame
        let children = directChildren.compactMap {
            workspaceCandidate(for: $0, allowBareFolder: importsChildrenByConvention, fileManager: fileManager)
        }

        return children.isEmpty
            ? [WorkspaceImportCandidate(folderURL: url, configURL: nil)]
            : children
    }

    private static func workspaceCandidate(
        for url: URL,
        allowBareFolder: Bool,
        fileManager: FileManager
    ) -> WorkspaceImportCandidate? {
        if let configured = configuredWorkspaceCandidate(for: url, fileManager: fileManager) {
            return configured
        }
        guard allowBareFolder || hasWorkspaceMarkers(at: url, fileManager: fileManager) else {
            return nil
        }
        return WorkspaceImportCandidate(folderURL: url, configURL: nil)
    }

    private static func configuredWorkspaceCandidate(
        for url: URL,
        fileManager: FileManager
    ) -> WorkspaceImportCandidate? {
        for name in [WorkspaceFileLayout.workspaceConfigFileName, legacyAgentFlowConfigFileName] {
            let configURL = url.appendingPathComponent(name)
            if fileManager.fileExists(atPath: configURL.path) {
                return WorkspaceImportCandidate(folderURL: url, configURL: configURL)
            }
        }
        return nil
    }

    private static func hasWorkspaceMarkers(at url: URL, fileManager: FileManager) -> Bool {
        let markerNames = [
            WorkspaceFileLayout.supportDirectoryName,
            ".agentflow",
            ".claude",
            "tasks",
            "memory.md",
            WorkspaceFileLayout.sshConnectionsFileName
        ]
        return markerNames.contains { name in
            fileManager.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }

    private static func childDirectories(in url: URL, fileManager: FileManager) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey]
        )) ?? []

        return children
            .filter { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                return values?.isDirectory == true && values?.isHidden != true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
