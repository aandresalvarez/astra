import Foundation

enum TaskOutputWorkspaceDiscovery {
    static let scanEntryLimit = 800
    static let scanDepthLimit = 4

    static func filesChangedDuringRun(
        workspacePath: String,
        taskFolder: String,
        run: TaskRun,
        fileManager: FileManager = .default
    ) -> [TaskOutputDiscoveredFile] {
        guard !workspacePath.isEmpty else { return [] }

        let rootURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let root = PathBoundary(rootURL)
        let taskFolderRoot = taskFolder.isEmpty ? nil : PathBoundary(URL(fileURLWithPath: taskFolder, isDirectory: true))
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let intent = HostFileAccessIntent.astraManagedStorage(root: rootURL)

        var rootIsDirectory: ObjCBool = false
        guard hostFileAccess.fileExists(at: rootURL, isDirectory: &rootIsDirectory, intent: intent),
              rootIsDirectory.boolValue,
              let enumerator = hostFileAccess.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .creationDateKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles],
                intent: intent
              ) else {
            return []
        }

        var scannedEntries = 0
        var files: [TaskOutputDiscoveredFile] = []
        while let url = enumerator.nextObject() as? URL {
            scannedEntries += 1
            guard scannedEntries <= scanEntryLimit else { break }

            let item = PathItem(url)
            if taskFolderRoot?.contains(item) == true {
                enumerator.skipDescendants()
                continue
            }

            guard let relative = root.relativePath(for: item) else { continue }
            let depth = relativeDepth(of: relative)
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey]
            ) else {
                continue
            }

            if values.isDirectory == true {
                if depth >= scanDepthLimit {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard depth <= scanDepthLimit,
                  values.isRegularFile == true,
                  TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relative),
                  wasChangedDuringRun(values, run: run) else {
                continue
            }

            let attrs = try? fileManager.attributesOfItem(atPath: item.standardPath)
            files.append(TaskOutputDiscoveredFile(
                path: item.standardPath,
                relativePath: relative,
                type: ArtifactKind.forPath(item.standardPath).rawValue,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func wasChangedDuringRun(_ values: URLResourceValues, run: TaskRun) -> Bool {
        let lowerBound = run.startedAt.addingTimeInterval(-2)
        let upperBound = (run.completedAt ?? Date()).addingTimeInterval(2)
        return [values.creationDate, values.contentModificationDate].contains { date in
            guard let date, date >= lowerBound else { return false }
            return date <= upperBound
        }
    }

    private static func relativeDepth(of relativePath: String) -> Int {
        relativePath.split(separator: "/").count
    }
}

private struct PathItem {
    var standardPath: String
    var resolvedPath: String

    init(_ url: URL) {
        standardPath = Self.normalized(url.standardizedFileURL)
        resolvedPath = Self.normalized(url.resolvingSymlinksInPath().standardizedFileURL)
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

private struct PathBoundary {
    var standardPath: String
    var resolvedPath: String

    init(_ url: URL) {
        standardPath = PathBoundary.normalized(url.standardizedFileURL)
        resolvedPath = PathBoundary.normalized(url.resolvingSymlinksInPath().standardizedFileURL)
    }

    func contains(_ item: PathItem) -> Bool {
        Self.isPath(item.standardPath, inside: standardPath)
            || Self.isPath(item.resolvedPath, inside: resolvedPath)
    }

    func relativePath(for item: PathItem) -> String? {
        if let relative = Self.relativePath(item.standardPath, inside: standardPath) {
            return relative
        }
        return Self.relativePath(item.resolvedPath, inside: resolvedPath)
    }

    private static func relativePath(_ path: String, inside root: String) -> String? {
        guard isPath(path, inside: root), path != root else { return nil }
        return String(path.dropFirst(root.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
