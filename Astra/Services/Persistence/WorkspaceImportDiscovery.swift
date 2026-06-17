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
        fileManager: FileManager = .default,
        hostFileAccess: HostFileAccessBroker? = nil
    ) -> [WorkspaceImportCandidate] {
        let hostFileAccess = hostFileAccess ?? HostFileAccessBroker(fileManager: fileManager)
        var seen = Set<String>()
        var results: [WorkspaceImportCandidate] = []

        for url in urls {
            for candidate in candidates(for: url, fileManager: fileManager, hostFileAccess: hostFileAccess) {
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
        fileManager: FileManager = .default,
        hostFileAccess: HostFileAccessBroker? = nil
    ) -> [WorkspaceImportCandidate] {
        let hostFileAccess = hostFileAccess ?? HostFileAccessBroker(fileManager: fileManager)
        let selectionIntent = HostFileAccessIntent.explicitUserSelection
        var isDirectory: ObjCBool = false
        guard hostFileAccess.fileExists(at: url, isDirectory: &isDirectory, intent: selectionIntent) else {
            return []
        }

        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "json" else { return [] }
            return [WorkspaceImportCandidate(folderURL: url.deletingLastPathComponent(), configURL: url)]
        }

        if let direct = configuredWorkspaceCandidate(
            for: url,
            hostFileAccess: hostFileAccess,
            accessIntent: selectionIntent
        ) {
            return [direct]
        }

        let childScanIntent = HostFileAccessIntent.implicitScan(root: url)
        let directChildren = childDirectories(
            in: url,
            hostFileAccess: hostFileAccess,
            accessIntent: childScanIntent
        )
        let importsChildrenByConvention = url.lastPathComponent.localizedCaseInsensitiveCompare("Workspaces") == .orderedSame
        let children = directChildren.compactMap {
            workspaceCandidate(
                for: $0,
                allowBareFolder: importsChildrenByConvention,
                hostFileAccess: hostFileAccess,
                accessIntent: childScanIntent
            )
        }

        if importsChildrenByConvention {
            return children
        }

        return children.isEmpty
            ? [WorkspaceImportCandidate(folderURL: url, configURL: nil)]
            : children
    }

    private static func workspaceCandidate(
        for url: URL,
        allowBareFolder: Bool,
        hostFileAccess: HostFileAccessBroker,
        accessIntent: HostFileAccessIntent
    ) -> WorkspaceImportCandidate? {
        if let configured = configuredWorkspaceCandidate(
            for: url,
            hostFileAccess: hostFileAccess,
            accessIntent: accessIntent
        ) {
            return configured
        }
        guard allowBareFolder || hasWorkspaceMarkers(
            at: url,
            hostFileAccess: hostFileAccess,
            accessIntent: accessIntent
        ) else {
            return nil
        }
        return WorkspaceImportCandidate(folderURL: url, configURL: nil)
    }

    private static func configuredWorkspaceCandidate(
        for url: URL,
        hostFileAccess: HostFileAccessBroker,
        accessIntent: HostFileAccessIntent
    ) -> WorkspaceImportCandidate? {
        for name in [WorkspaceFileLayout.workspaceConfigFileName, legacyAgentFlowConfigFileName] {
            let configURL = url.appendingPathComponent(name)
            if hostFileAccess.fileExists(at: configURL, intent: accessIntent) {
                return WorkspaceImportCandidate(folderURL: url, configURL: configURL)
            }
        }
        return nil
    }

    private static func hasWorkspaceMarkers(
        at url: URL,
        hostFileAccess: HostFileAccessBroker,
        accessIntent: HostFileAccessIntent
    ) -> Bool {
        let markerNames = [
            WorkspaceFileLayout.supportDirectoryName,
            ".agentflow",
            ".claude",
            "tasks",
            "memory.md",
            WorkspaceFileLayout.sshConnectionsFileName
        ]
        return markerNames.contains { name in
            hostFileAccess.fileExists(at: url.appendingPathComponent(name), intent: accessIntent)
        }
    }

    private static func childDirectories(
        in url: URL,
        hostFileAccess: HostFileAccessBroker,
        accessIntent: HostFileAccessIntent
    ) -> [URL] {
        let children = (try? hostFileAccess.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            intent: accessIntent
        )) ?? []

        return children
            .filter { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isHidden != true && values?.isSymbolicLink != true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
