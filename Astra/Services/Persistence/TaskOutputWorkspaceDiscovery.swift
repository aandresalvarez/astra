import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

public enum TaskOutputWorkspaceDiscovery {
    public static let scanEntryLimit = 800
    public static let scanDepthLimit = 4

    @MainActor
    public static func filesChangedDuringRun(
        workspacePath: String,
        taskFolder: String,
        run: TaskRun,
        fileManager: FileManager = .default
    ) -> [TaskOutputDiscoveredFile] {
        guard !workspacePath.isEmpty, allowsWorkspaceInference(for: run) else { return [] }

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

            guard let rawRelative = root.relativePath(for: item) else { continue }
            let relative = TaskOutputArtifactPathPolicy.normalizedRelativePath(rawRelative)
            let depth = TaskOutputArtifactPathPolicy.relativeDepth(of: relative)
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey]
            ) else {
                continue
            }

            if values.isDirectory == true {
                if TaskOutputArtifactPathPolicy.isRuntimeDiagnosticRelativePath(relative, context: .workspace) ||
                    depth >= scanDepthLimit {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard depth <= scanDepthLimit,
                  values.isRegularFile == true,
                  TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                    relative,
                    context: .workspace
                  ) != nil,
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

    /// A modification time is not ownership evidence when this run accepted
    /// concurrent writers. Read the durable request rather than the current
    /// composer selection; later delivery checks must keep the same boundary.
    @MainActor
    private static func allowsWorkspaceInference(for run: TaskRun) -> Bool {
        guard let task = run.task, let context = task.modelContext else { return true }
        let taskID = task.id
        let runID = run.id
        do {
            // A later attempt moves both request.runID and source.run. The
            // immutable identity event keeps the original accepted request.
            if let request = try TaskRunRequestAssociation.request(for: run, in: context) {
                return permitsWorkspaceInference(request)
            }
            // Pre-event attempts can still be resolved before reassociation.
            let userMessage = TaskEventTypes.Conversation.userMessage.rawValue
            let requestPrefix = "execution.request."
            let sourceEvents = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate {
                $0.task?.id == taskID && $0.run?.id == runID
                    && ($0.type == userMessage || $0.type.starts(with: requestPrefix))
            }))
            let sourceIDs = sourceEvents.filter { $0.task?.persistentModelID == task.persistentModelID }.map(\.id)
            let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate {
                $0.taskID == taskID && ($0.runID == runID || sourceIDs.contains($0.messageEventID))
            }))
            var owners = TaskTurnRequestOwnership.Resolver(candidates:
                try TaskTurnRequestOwnership.candidates(taskID: taskID, in: context))
            for request in requests {
                guard let owner = owners.resolve(request) else { return false }
                guard owner.persistentModelID == task.persistentModelID else { continue }
                if !permitsWorkspaceInference(request) { return false }
            }
            return true
        } catch {
            // An unreadable ownership record cannot authorize attribution.
            return false
        }
    }

    private static func permitsWorkspaceInference(_ request: TaskTurnRequest) -> Bool {
        guard let claims = request.decodedResourceClaims else { return false }
        return !claims.contains { $0.kind == .workspace && $0.readConsistency == .live }
    }

    private static func wasChangedDuringRun(_ values: URLResourceValues, run: TaskRun) -> Bool {
        let lowerBound = run.startedAt.addingTimeInterval(-2)
        let upperBound = (run.completedAt ?? Date()).addingTimeInterval(2)
        return [values.creationDate, values.contentModificationDate].contains { date in
            guard let date, date >= lowerBound else { return false }
            return date <= upperBound
        }
    }
}

private struct PathItem {
    public var standardPath: String
    public var resolvedPath: String

    public init(_ url: URL) {
        standardPath = Self.normalized(url.standardizedFileURL)
        resolvedPath = Self.normalized(url.resolvingSymlinksInPath().standardizedFileURL)
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

private struct PathBoundary {
    public var standardPath: String
    public var resolvedPath: String

    public init(_ url: URL) {
        standardPath = PathBoundary.normalized(url.standardizedFileURL)
        resolvedPath = PathBoundary.normalized(url.resolvingSymlinksInPath().standardizedFileURL)
    }

    public func contains(_ item: PathItem) -> Bool {
        Self.isPath(item.standardPath, inside: standardPath)
            || Self.isPath(item.resolvedPath, inside: resolvedPath)
    }

    public func relativePath(for item: PathItem) -> String? {
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
