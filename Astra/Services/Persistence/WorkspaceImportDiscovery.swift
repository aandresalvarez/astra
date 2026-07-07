import Foundation
import ASTRACore

public struct WorkspaceImportCandidate: Equatable {
    public init(folderURL: URL, configURL: URL? = nil) {
        self.folderURL = folderURL
        self.configURL = configURL
    }

    public var folderURL: URL
    public var configURL: URL?

    public var displayName: String {
        folderURL.lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

public enum WorkspaceImportDiscovery {
    public static let legacyAgentFlowConfigFileName = ".agentflow-workspace.json"

    public static func candidates(
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

    public static func candidates(
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
            return [WorkspaceImportCandidate(folderURL: WorkspaceFileLayout.workspaceRoot(forConfigFile: url), configURL: url)]
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
        let configURLs = [
            URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: url.path)),
            URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: url.path)),
            url.appendingPathComponent(legacyAgentFlowConfigFileName)
        ]
        for configURL in configURLs {
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
