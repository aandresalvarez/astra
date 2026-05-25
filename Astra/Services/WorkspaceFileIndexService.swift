import Foundation

struct WorkspaceFileRoot: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case primary
        case additional
        case taskFolder
        case input
    }

    let id: String
    let kind: Kind
    let title: String
    let path: String
    let isDirectory: Bool
}

struct WorkspaceFileNode: Identifiable, Hashable {
    let id: String
    let rootID: String
    let path: String
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let depth: Int
    let size: Int64
    let modifiedAt: Date?
    let destination: TaskGeneratedFileShelfDestination?

    var parentRelativePath: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

struct WorkspaceFileIndexError: Hashable {
    let rootID: String
    let path: String
    let message: String
}

struct WorkspaceFileIndexSnapshot {
    let roots: [WorkspaceFileRoot]
    let nodes: [WorkspaceFileNode]
    let errors: [WorkspaceFileIndexError]
    let isTruncated: Bool
}

enum WorkspaceFileIndexService {
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

    static func roots(workspace: Workspace?, task: AgentTask?, fileManager: FileManager = .default) -> [WorkspaceFileRoot] {
        var roots: [WorkspaceFileRoot] = []
        var seen: Set<String> = []

        @discardableResult
        func append(kind: WorkspaceFileRoot.Kind, title: String, rawPath: String) -> Bool {
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
                isDirectory: isDirectory.boolValue
            ))
            return true
        }

        if let workspace {
            append(kind: .primary, title: "Primary", rawPath: workspace.primaryPath)
            for (index, path) in workspace.additionalPaths.enumerated() {
                append(kind: .additional, title: "Additional \(index + 1)", rawPath: path)
            }
        }

        if let task {
            let access = TaskWorkspaceAccess(task: task)
            append(kind: .taskFolder, title: "Task Folder", rawPath: access.taskFolder)
            var inputIndex = 1
            for path in task.inputs {
                if append(kind: .input, title: "Input \(inputIndex)", rawPath: path) {
                    inputIndex += 1
                }
            }
        }

        return roots
    }

    static func scan(
        roots: [WorkspaceFileRoot],
        maxDepth: Int = 8,
        maxNodes: Int = 5_000,
        includeHidden: Bool = false,
        fileManager: FileManager = .default
    ) async -> WorkspaceFileIndexSnapshot {
        let scanTask = Task(priority: .utility) {
            scanSync(
                roots: roots,
                maxDepth: maxDepth,
                maxNodes: maxNodes,
                includeHidden: includeHidden,
                fileManager: fileManager
            )
        }

        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    static func scanSync(
        roots: [WorkspaceFileRoot],
        maxDepth: Int = 8,
        maxNodes: Int = 5_000,
        includeHidden: Bool = false,
        fileManager: FileManager = .default
    ) -> WorkspaceFileIndexSnapshot {
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
                fileManager: fileManager,
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

    static func isPath(_ path: String, inside root: WorkspaceFileRoot) -> Bool {
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
        fileManager: FileManager,
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
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
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
                destination: isDirectory ? nil : TaskGeneratedFiles.shelfDestination(for: url.path)
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
            destination: TaskGeneratedFiles.shelfDestination(for: root.path)
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
           !TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: normalized) {
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
           relativePath == "tasks" || relativePath.hasPrefix("tasks/") {
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
