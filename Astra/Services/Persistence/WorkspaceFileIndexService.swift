import Foundation
import ASTRACore
import ASTRAModels

public struct WorkspaceFileRoot: Identifiable, Hashable {
    public enum Kind: String, Hashable {
        case primary
        case additional
        case taskFolder
        case input
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let path: String
    public let isDirectory: Bool
    public let subtitle: String
    public let roleLabel: String
    public let isGitRepository: Bool

    public init(
        id: String,
        kind: Kind,
        title: String,
        path: String,
        isDirectory: Bool,
        subtitle: String = "",
        roleLabel: String = "",
        isGitRepository: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.isDirectory = isDirectory
        self.subtitle = subtitle
        self.roleLabel = roleLabel
        self.isGitRepository = isGitRepository
    }
}

public struct WorkspaceFileNode: Identifiable, Hashable {
    public let id: String
    public let rootID: String
    public let path: String
    public let relativePath: String
    public let name: String
    public let isDirectory: Bool
    public let depth: Int
    public let size: Int64
    public let modifiedAt: Date?
    public let destination: TaskGeneratedFileShelfDestination?

    public init(
        id: String,
        rootID: String,
        path: String,
        relativePath: String,
        name: String,
        isDirectory: Bool,
        depth: Int,
        size: Int64,
        modifiedAt: Date?,
        destination: TaskGeneratedFileShelfDestination?
    ) {
        self.id = id
        self.rootID = rootID
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.depth = depth
        self.size = size
        self.modifiedAt = modifiedAt
        self.destination = destination
    }

    public var parentRelativePath: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

public struct WorkspaceFileIndexError: Hashable {
    public let rootID: String
    public let path: String
    public let message: String
}

public struct WorkspaceFileIndexSnapshot {
    public let roots: [WorkspaceFileRoot]
    public let nodes: [WorkspaceFileNode]
    public let errors: [WorkspaceFileIndexError]
    public let isTruncated: Bool
}

public enum WorkspaceFileIndexService {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    private static let ignoredDirectoryNames: Set<String> = [
        ".git",
        ".hg",
        ".svn",
        ".build",
        ".runtime-bin",
        ".swiftpm",
        "DerivedData",
        "node_modules"
    ]

    public static func roots(workspace: Workspace?, task: AgentTask?, fileManager: FileManager = .default) -> [WorkspaceFileRoot] {
        var roots: [WorkspaceFileRoot] = []
        var seen: Set<String> = []

        @discardableResult
        func append(
            kind: WorkspaceFileRoot.Kind,
            title: String,
            rawPath: String,
            subtitle: String = "",
            roleLabel: String = "",
            isGitRepository: Bool = false
        ) -> Bool {
            let path = normalizedPath(rawPath)
            guard !path.isEmpty else { return false }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }
            let standardized = standardizedPath(path)
            guard seen.insert(standardized).inserted else { return false }
            roots.append(WorkspaceFileRoot(
                id: "\(kind.rawValue):\(standardized)",
                kind: kind,
                title: title,
                path: standardized,
                isDirectory: isDirectory.boolValue,
                subtitle: subtitle,
                roleLabel: roleLabel,
                isGitRepository: isGitRepository
            ))
            return true
        }

        if let workspace {
            for descriptor in WorkspacePathPresentation.descriptors(
                primaryPath: workspace.primaryPath,
                additionalPaths: workspace.additionalPaths
            ) {
                append(
                    kind: descriptor.role == .primary ? .primary : .additional,
                    title: descriptor.title,
                    rawPath: descriptor.path,
                    subtitle: descriptor.subtitle,
                    roleLabel: descriptor.roleLabel,
                    isGitRepository: WorkspacePathPresentation.isGitRepository(at: descriptor.path, fileManager: fileManager)
                )
            }
        }

        if let task {
            let access = TaskWorkspaceAccess(task: task)
            append(kind: .taskFolder, title: "Task Folder", rawPath: access.taskFolder)
            let checkpointFiles = TaskForkSourcePointerSeam.required.checkpointFilePaths(for: task, fileManager: fileManager)
            for path in checkpointFiles {
                append(
                    kind: .input,
                    title: "Fork Checkpoint File",
                    rawPath: path,
                    subtitle: "Source task checkpoint",
                    roleLabel: "Checkpoint"
                )
            }
            for path in TaskRelatedOutputFolders.legacyOutputFolders(for: task, workspace: task.workspace ?? workspace, fileManager: fileManager) {
                let name = URL(fileURLWithPath: path).lastPathComponent
                append(kind: .taskFolder, title: "Task Output \(name)", rawPath: path)
            }
            var inputIndex = 1
            for path in task.inputs {
                if append(kind: .input, title: "Input \(inputIndex)", rawPath: path) {
                    inputIndex += 1
                }
            }
        }

        return roots
    }

    public static func scan(
        roots: [WorkspaceFileRoot],
        maxDepth: Int = 8,
        maxNodes: Int = 5_000,
        includeHidden: Bool = false,
        fileManager: FileManager = .default,
        privacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> WorkspaceFileIndexSnapshot {
        let scanTask = Task(priority: .utility) {
            scanSync(
                roots: roots,
                maxDepth: maxDepth,
                maxNodes: maxNodes,
                includeHidden: includeHidden,
                fileManager: fileManager,
                hostFileAccess: HostFileAccessBroker(
                    fileManager: fileManager,
                    homeDirectory: privacyHomeDirectory
                )
            )
        }

        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    public static func scanSync(
        roots: [WorkspaceFileRoot],
        maxDepth: Int = 8,
        maxNodes: Int = 5_000,
        includeHidden: Bool = false,
        fileManager: FileManager = .default,
        privacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        hostFileAccess: HostFileAccessBroker? = nil
    ) -> WorkspaceFileIndexSnapshot {
        let hostFileAccess = hostFileAccess ?? HostFileAccessBroker(
            fileManager: fileManager,
            homeDirectory: privacyHomeDirectory
        )
        var nodes: [WorkspaceFileNode] = []
        var errors: [WorkspaceFileIndexError] = []
        var isTruncated = false

        for root in roots {
            guard !Task.isCancelled, !isTruncated else { break }
            scanRoot(
                root,
                maxDepth: maxDepth,
                maxNodes: maxNodes,
                includeHidden: includeHidden,
                hostFileAccess: hostFileAccess,
                nodes: &nodes,
                errors: &errors,
                isTruncated: &isTruncated
            )
        }

        let rootOrder = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($0.element.id, $0.offset) })
        nodes.sort { lhs, rhs in
            let lhsRoot = rootOrder[lhs.rootID] ?? 0
            let rhsRoot = rootOrder[rhs.rootID] ?? 0
            if lhsRoot != rhsRoot { return lhsRoot < rhsRoot }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        return WorkspaceFileIndexSnapshot(
            roots: roots,
            nodes: nodes,
            errors: errors,
            isTruncated: isTruncated
        )
    }

    public static func isPath(_ path: String, inside root: WorkspaceFileRoot) -> Bool {
        let resolvedPath = resolvingSymlinks(standardizedPath(path))
        let resolvedRoot = resolvingSymlinks(root.path)
        guard root.isDirectory else {
            return resolvedPath == resolvedRoot
        }
        return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private static func scanRoot(
        _ root: WorkspaceFileRoot,
        maxDepth: Int,
        maxNodes: Int,
        includeHidden: Bool,
        hostFileAccess: HostFileAccessBroker,
        nodes: inout [WorkspaceFileNode],
        errors: inout [WorkspaceFileIndexError],
        isTruncated: inout Bool
    ) {
        guard root.isDirectory else {
            scanFileRoot(root, maxNodes: maxNodes, nodes: &nodes, isTruncated: &isTruncated)
            return
        }

        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let resolvedRoot = resolvingSymlinks(root.path)
        let intent = HostFileAccessIntent.implicitScan(root: rootURL)
        guard let enumerator = hostFileAccess.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            intent: intent
        ) else {
            errors.append(WorkspaceFileIndexError(rootID: root.id, path: root.path, message: "Could not read folder"))
            return
        }

        for case let url as URL in enumerator {
            guard !Task.isCancelled, !isTruncated else { break }

            let relativePath = relativePath(for: url.path, rootPath: root.path)
            guard !relativePath.isEmpty else { continue }
            let depth = relativePath.split(separator: "/", omittingEmptySubsequences: true).count - 1

            guard depth <= maxDepth else {
                enumerator.skipDescendants()
                continue
            }

            if hostFileAccess.shouldSkip(url, intent: intent) {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory == true
            let name = url.lastPathComponent

            if shouldSkip(
                relativePath: relativePath,
                name: name,
                isDirectory: isDirectory,
                rootKind: root.kind,
                includeHidden: includeHidden
            ) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values?.isSymbolicLink == true {
                let resolvedPath = resolvingSymlinks(url.path)
                guard resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/") else {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }

            nodes.append(WorkspaceFileNode(
                id: "\(root.id):\(url.path)",
                rootID: root.id,
                path: standardizedPath(url.path),
                relativePath: relativePath,
                name: name,
                isDirectory: isDirectory,
                depth: max(0, depth),
                size: isDirectory ? 0 : Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate,
                destination: isDirectory ? nil : TaskGeneratedFileQuerySeam.required.shelfDestination(for: url.path)
            ))

            if nodes.count >= maxNodes {
                isTruncated = true
            }
        }
    }

    private static func scanFileRoot(
        _ root: WorkspaceFileRoot,
        maxNodes: Int,
        nodes: inout [WorkspaceFileNode],
        isTruncated: inout Bool
    ) {
        guard !Task.isCancelled, !isTruncated else { return }

        let url = URL(fileURLWithPath: root.path, isDirectory: false)
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let name = url.lastPathComponent
        nodes.append(WorkspaceFileNode(
            id: "\(root.id):\(root.path)",
            rootID: root.id,
            path: standardizedPath(root.path),
            relativePath: name,
            name: name,
            isDirectory: false,
            depth: 0,
            size: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate,
            destination: TaskGeneratedFileQuerySeam.required.shelfDestination(for: root.path)
        ))

        if nodes.count >= maxNodes {
            isTruncated = true
        }
    }

    private static func shouldSkip(
        relativePath: String,
        name: String,
        isDirectory: Bool,
        rootKind: WorkspaceFileRoot.Kind,
        includeHidden: Bool
    ) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        if isInternalWorkspacePath(normalized, rootKind: rootKind) {
            return true
        }
        if rootKind == .taskFolder,
           !TaskGeneratedFileQuerySeam.required.shouldDisplayTaskFolderFile(relativePath: normalized) {
            return true
        }
        if !includeHidden && hasHiddenPathComponent(normalized) {
            return true
        }
        guard isDirectory else { return false }
        return ignoredDirectoryNames.contains(name)
    }

    private static func isInternalWorkspacePath(
        _ relativePath: String,
        rootKind: WorkspaceFileRoot.Kind
    ) -> Bool {
        if rootKind != .taskFolder,
           let runtimeRelativePath = legacyTaskRuntimeRelativePath(relativePath),
           !TaskGeneratedFileQuerySeam.required.shouldDisplayTaskFolderFile(relativePath: runtimeRelativePath) {
            return true
        }
        if relativePath == ".astra/tasks" || relativePath.hasPrefix(".astra/tasks/") {
            return true
        }
        if relativePath == ".agentflow/tasks" || relativePath.hasPrefix(".agentflow/tasks/") {
            return true
        }
        return false
    }

    private static func legacyTaskRuntimeRelativePath(_ relativePath: String) -> String? {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 3,
              components[0] == "tasks" else {
            return nil
        }
        return components.dropFirst(2).joined(separator: "/")
    }

    private static func hasHiddenPathComponent(_ relativePath: String) -> Bool {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains { $0.hasPrefix(".") }
    }

    private static func relativePath(for path: String, rootPath: String) -> String {
        let normalizedFilePath = standardizedPath(path)
        let standardizedRoot = standardizedPath(rootPath)
        guard normalizedFilePath != standardizedRoot,
              normalizedFilePath.hasPrefix(standardizedRoot + "/") else {
            return ""
        }
        return String(normalizedFilePath.dropFirst(standardizedRoot.count + 1))
    }

    private static func normalizedPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: normalizedPath(path)).standardizedFileURL.path
    }

    private static func resolvingSymlinks(_ path: String) -> String {
        (standardizedPath(path) as NSString).resolvingSymlinksInPath
    }
}
