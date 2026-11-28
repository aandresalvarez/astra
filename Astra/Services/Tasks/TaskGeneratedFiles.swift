import Foundation
import ASTRACore
import ASTRAPersistence

// Bare cases moved to ASTRACore/TaskGeneratedFileShelfDestination.swift for
// Track A4 (ASTRAPersistence), which needs the case set as a stored-property
// type; this extension's Shelf-registry-dependent members stay app-side.
extension TaskGeneratedFileShelfDestination {
    var title: String {
        generatedFileDestination.title
    }

    var compactTitle: String {
        generatedFileDestination.compactTitle
    }

    var systemImage: String {
        generatedFileDestination.systemImage
    }

    init?(shelfID: ShelfID) {
        switch shelfID {
        case .browser:
            self = .browser
        case .files:
            self = .files
        case .query:
            self = .query
        case .plan, .appPreview:
            return nil
        }
    }

    var shelfID: ShelfID {
        switch self {
        case .browser:
            .browser
        case .files:
            .files
        case .query:
            .query
        }
    }

    private var generatedFileDestination: ShelfGeneratedFileDestinationMetadata {
        let descriptor = CoreShelfRegistry.requiredDescriptor(for: shelfID)
        guard let destination = descriptor.generatedFileDestination else {
            preconditionFailure("CoreShelfRegistry shelf '\(shelfID.rawValue)' is missing generated-file destination metadata")
        }
        return destination
    }
}

/// A task folder's displayable files, with what every transcript row needs
/// from the whole list worked out once per listing instead of once per row.
/// The list is the whole folder: 31,774 paths on one long task.
struct TaskGeneratedFileListing: Equatable, Sendable {
    static let empty = TaskGeneratedFileListing(paths: [])

    let paths: [String]
    /// Rows whose basename is in here lead with their parent folder
    /// (`TaskFileIndex.displayName`).
    let duplicateBasenames: Set<String>

    init(paths: [String]) {
        self.paths = paths
        duplicateBasenames = TaskFileIndex.duplicateBasenames(in: paths)
    }
}

enum TaskGeneratedFiles: Sendable {
    static func files(in folder: String, fileManager: FileManager = .default) -> [String] {
        files(in: folder, fileManager: fileManager, isCancelled: { false }) ?? []
    }

    static func files(in folder: String, fileManager: FileManager, isCancelled: () -> Bool) -> [String]? {
        entries(in: folder, fileManager: fileManager, isCancelled: isCancelled)?.map(\.path)
    }

    /// The listing's values the walk reads in bulk with each directory,
    /// instead of one stat per entry.
    private static let walkKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

    /// The walk behind `files(in:)`, sorted by path.
    ///
    /// Each entry the enumerator lists that is not a symlink is already named
    /// by its resolved path: the root is resolved before the walk starts and
    /// the enumerator never descends through a link. So its listing values
    /// settle it, with no syscall of its own. Resolving, stat-ing and reading
    /// the attributes of every entry again, several times over, was 9 s of
    /// the 14 s a 30,000-file task folder spent opening. A symlink, or an
    /// entry whose values cannot be read, is still resolved and checked one
    /// at a time, and so is everything when `fileManager` is not the default
    /// one, whose behaviour a test may have replaced.
    static func entries(
        in folder: String, fileManager: FileManager, isCancelled: () -> Bool
    ) -> [TaskGeneratedFileEntry]? {
        guard !folder.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: folder)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: rootURL)
        let readsListing = fileManager === FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard hostFileAccess.fileExists(at: rootURL, isDirectory: &rootIsDirectory, intent: accessIntent),
              rootIsDirectory.boolValue,
              let enumerator = hostFileAccess.enumerator(
                at: rootURL,
                includingPropertiesForKeys: walkKeys,
                intent: accessIntent
              ) else {
            return []
        }

        var entries: [TaskGeneratedFileEntry] = []
        // The broker's enumerator has already left out, with their subtrees,
        // the entries `shouldSkip` refuses for this intent.
        while let url = enumerator.nextObject() as? URL {
            guard !isCancelled() else { return nil }
            // Prune the whole subtree, before anything in it costs a syscall.
            // An agent that runs `python -m venv` in its task folder adds
            // ~15,000 entries that are all discarded by
            // `shouldDisplayTaskFolderFile` anyway. Filtering them one at a
            // time still walked every one.
            guard !TaskOutputArtifactPathPolicy.isGeneratedDependencyDirectoryName(url.lastPathComponent) else {
                enumerator.skipDescendants()
                continue
            }
            if readsListing, let values = try? url.resourceValues(forKeys: Set(walkKeys)),
               values.isSymbolicLink == false, let isDirectory = values.isDirectory {
                let itemPath = FilePathForm.isStandardizedAbsolute(url.path) ? url.path : url.standardizedFileURL.path
                guard itemPath.hasPrefix(rootPath),
                      shouldDisplayTaskFolderFile(relativePath: String(itemPath.dropFirst(rootPath.count))),
                      !isDirectory else { continue }
                entries.append(TaskGeneratedFileEntry(verifiedPath: itemPath, modifiedAt: values.contentModificationDate))
                continue
            }
            let itemURL = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard itemURL.path.hasPrefix(rootPath) else { continue }
            let rel = String(itemURL.path.dropFirst(rootPath.count))
            guard shouldDisplayTaskFolderFile(relativePath: rel) else { continue }
            var isDir: ObjCBool = false
            guard hostFileAccess.fileExists(at: itemURL, isDirectory: &isDir, intent: accessIntent) else {
                continue
            }
            if !isDir.boolValue {
                entries.append(TaskGeneratedFileEntry(unverifiedPath: itemURL.path))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    static func shouldDisplayTaskFolderFile(relativePath: String) -> Bool {
        TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
            relativePath,
            context: .taskFolder
        ) != nil
    }

    static func filesAsync(in folder: String) async -> [String] {
        await Task.detached(priority: .utility) {
            files(in: folder)
        }.value
    }

    /// `filesAsync` with the listing's derived facts, all off the main actor.
    static func listingAsync(in folder: String) async -> TaskGeneratedFileListing {
        await Task.detached(priority: .utility) {
            TaskGeneratedFileListing(paths: files(in: folder))
        }.value
    }

    static func markdownFiles(inInputs inputs: [String], fileManager: FileManager = .default) -> [String] {
        previewableFiles(inInputs: inputs, fileManager: fileManager, matches: isMarkdownFile)
    }

    static func sqlFiles(inInputs inputs: [String], fileManager: FileManager = .default) -> [String] {
        previewableFiles(inInputs: inputs, fileManager: fileManager, matches: isSQLFile)
    }

    private static func previewableFiles(
        inInputs inputs: [String],
        fileManager: FileManager,
        matches: (String) -> Bool
    ) -> [String] {
        var paths: [String] = []
        var seen: Set<String> = []

        for input in inputs {
            let path = (input as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }

            let candidates: [String]
            if isDirectory.boolValue {
                candidates = files(in: path, fileManager: fileManager).filter(matches)
            } else if matches(path) {
                candidates = [path]
            } else {
                candidates = []
            }

            for candidate in candidates where !seen.contains(candidate) {
                seen.insert(candidate)
                paths.append(candidate)
            }
        }

        return paths.sorted()
    }

    static func preferredHTMLFile(in paths: [String], taskFolder: String = "") -> String? {
        paths
            .filter(isHTMLFile)
            .sorted { lhs, rhs in
                htmlPreviewScore(for: lhs, taskFolder: taskFolder) < htmlPreviewScore(for: rhs, taskFolder: taskFolder)
            }
            .first
    }

    static func preferredMarkdownFile(in paths: [String], taskFolder: String = "") -> String? {
        paths
            .filter(isMarkdownFile)
            .sorted { lhs, rhs in
                markdownPreviewScore(for: lhs, taskFolder: taskFolder) < markdownPreviewScore(for: rhs, taskFolder: taskFolder)
            }
            .first
    }

    static func preferredSQLFile(in paths: [String], taskFolder: String = "") -> String? {
        paths
            .filter(isSQLFile)
            .sorted { lhs, rhs in
                markdownPreviewScore(for: lhs, taskFolder: taskFolder) < markdownPreviewScore(for: rhs, taskFolder: taskFolder)
            }
            .first
    }

    static func isHTMLFile(_ path: String) -> Bool {
        TaskGeneratedFilePathPolicy.isHTMLFile(path)
    }

    static func isMarkdownFile(_ path: String) -> Bool {
        TaskGeneratedFilePathPolicy.isMarkdownFile(path)
    }

    static func isSQLFile(_ path: String) -> Bool {
        TaskGeneratedFilePathPolicy.isSQLFile(path)
    }

    static func isFilesShelfFile(_ path: String) -> Bool {
        ShelfArtifactRouter.isFilesShelfFile(path)
    }

    static func shelfDestination(for path: String) -> TaskGeneratedFileShelfDestination? {
        ShelfArtifactRouter.shelfID(for: path).flatMap(TaskGeneratedFileShelfDestination.init(shelfID:))
    }

    static func shouldLoadGeneratedHTMLOnUserOpen(currentBrowserURL: String, targetPath: String) -> Bool {
        let trimmed = currentBrowserURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "about:blank" else {
            return true
        }

        guard let currentURL = URL(string: trimmed),
              currentURL.isFileURL else {
            return false
        }

        return currentURL.standardizedFileURL.path == URL(fileURLWithPath: targetPath).standardizedFileURL.path
    }

    static func htmlPreviewSignature(
        for path: String,
        taskID: UUID,
        fileManager: FileManager = .default
    ) -> String {
        previewSignature(for: path, taskID: taskID, fileManager: fileManager)
    }

    static func markdownPreviewSignature(
        for path: String,
        taskID: UUID,
        fileManager: FileManager = .default
    ) -> String {
        previewSignature(for: path, taskID: taskID, fileManager: fileManager)
    }

    private static func previewSignature(
        for path: String,
        taskID: UUID,
        fileManager: FileManager
    ) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = attributes?[.size] as? Int64 ?? 0
        return "\(taskID.uuidString)|\(path)|\(modifiedAt)|\(size)"
    }

    private static func htmlPreviewScore(for path: String, taskFolder: String) -> HTMLPreviewScore {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let relativePath = relativePath(for: path, taskFolder: taskFolder)
        return HTMLPreviewScore(
            namePriority: name == "index.html" || name == "index.htm" ? 0 : 1,
            depth: relativePath.split(separator: "/").count,
            relativePath: relativePath.lowercased()
        )
    }

    private static func markdownPreviewScore(for path: String, taskFolder: String) -> MarkdownPreviewScore {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let relativePath = relativePath(for: path, taskFolder: taskFolder)
        return MarkdownPreviewScore(
            namePriority: markdownNamePriority(name),
            depth: relativePath.split(separator: "/").count,
            relativePath: relativePath.lowercased()
        )
    }

    private static func markdownNamePriority(_ name: String) -> Int {
        switch name {
        case "readme.md", "readme.markdown", "index.md", "index.markdown":
            0
        default:
            1
        }
    }

    private static func relativePath(for path: String, taskFolder: String) -> String {
        guard !taskFolder.isEmpty else { return path }
        let prefix = taskFolder.hasSuffix("/") ? taskFolder : "\(taskFolder)/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    private struct HTMLPreviewScore: Comparable {
        let namePriority: Int
        let depth: Int
        let relativePath: String

        static func < (lhs: HTMLPreviewScore, rhs: HTMLPreviewScore) -> Bool {
            if lhs.namePriority != rhs.namePriority {
                return lhs.namePriority < rhs.namePriority
            }
            if lhs.depth != rhs.depth {
                return lhs.depth < rhs.depth
            }
            return lhs.relativePath < rhs.relativePath
        }
    }

    private struct MarkdownPreviewScore: Comparable {
        let namePriority: Int
        let depth: Int
        let relativePath: String

        static func < (lhs: MarkdownPreviewScore, rhs: MarkdownPreviewScore) -> Bool {
            if lhs.namePriority != rhs.namePriority {
                return lhs.namePriority < rhs.namePriority
            }
            if lhs.depth != rhs.depth {
                return lhs.depth < rhs.depth
            }
            return lhs.relativePath < rhs.relativePath
        }
    }
}
