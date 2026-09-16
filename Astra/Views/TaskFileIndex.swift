import Foundation
import ASTRAModels
import ASTRAPersistence
import ASTRACore

struct TaskFileItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let source: String
    let change: StoredFileChange?
    let destination: TaskGeneratedFileShelfDestination?

    var id: String { path }

    init(
        path: String,
        name: String? = nil,
        isDirectory: Bool = false,
        size: Int64 = 0,
        source: String,
        change: StoredFileChange? = nil,
        destination: TaskGeneratedFileShelfDestination? = nil
    ) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.source = source
        self.change = change
        self.destination = destination
    }
}

enum TaskFileIndex {
    private static let filePathRegex = try? NSRegularExpression(pattern: #"(?:/[\w.@\-]+){2,}(?:\.\w+)?"#)

    static func sourceLabel(for change: StoredFileChange) -> String {
        change.kind.sourceLabel
    }

    static func headerItems(
        runs: [TaskRunSnapshot],
        generatedFilePaths: [String],
        inputs: [String],
        taskFolder: String = "",
        workspacePath: String = "",
        fileManager: FileManager = .default
    ) -> [TaskFileItem] {
        var seen = Set<String>()
        var items: [TaskFileItem] = []

        func append(path rawPath: String, source: String, change: StoredFileChange? = nil) {
            let path = normalizedPath(rawPath)
            guard !path.isEmpty,
                  shouldIncludeUserFacingPath(path, source: source, taskFolder: taskFolder, workspacePath: workspacePath),
                  seen.insert(path).inserted else { return }

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return }

            items.append(fileItem(
                path: path,
                isDirectory: false,
                source: source,
                change: change,
                fileManager: fileManager
            ))
        }

        for run in runs.reversed() {
            for change in run.fileChanges.reversed() {
                append(path: change.path, source: sourceLabel(for: change), change: change)
            }
        }

        for path in generatedFilePaths {
            append(path: path, source: "output")
        }

        for input in inputs {
            append(path: input, source: "input")
        }

        return items
    }

    static func mergedItems(
        latestRun: TaskRun?,
        taskFolderFiles: [TaskFileItem],
        inputs: [String],
        outputPathFiles: [TaskFileItem],
        taskFolder: String = "",
        fileManager: FileManager = .default
    ) -> [TaskFileItem] {
        var files: [TaskFileItem] = []
        var seen = Set<String>()

        if let latestRun {
            for change in latestRun.fileChanges {
                let path = normalizedPath(change.path)
                guard !path.isEmpty,
                      shouldIncludeUserFacingPath(path, taskFolder: taskFolder),
                      seen.insert(path).inserted else { continue }
                files.append(fileItem(
                    path: path,
                    isDirectory: false,
                    source: sourceLabel(for: change),
                    change: change,
                    fileManager: fileManager
                ))
            }
        }

        for file in taskFolderFiles where seen.insert(file.path).inserted {
            if shouldIncludeUserFacingPath(file.path, taskFolder: taskFolder) {
                files.append(file)
            }
        }

        for input in inputs {
            let path = normalizedPath(input)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }

            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            files.append(fileItem(
                path: path,
                isDirectory: exists && isDirectory.boolValue,
                source: "input",
                fileManager: fileManager
            ))
        }

        for file in outputPathFiles where seen.insert(file.path).inserted {
            if shouldIncludeUserFacingPath(file.path, taskFolder: taskFolder) {
                files.append(file)
            }
        }

        return files
    }

    static func scanTaskFolder(_ folder: String, fileManager: FileManager = .default) -> [TaskFileItem] {
        guard !folder.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: folder, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: rootURL)
        var rootIsDirectory = ObjCBool(false)
        guard hostFileAccess.fileExists(at: rootURL, isDirectory: &rootIsDirectory, intent: accessIntent),
              rootIsDirectory.boolValue,
              let enumerator = hostFileAccess.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                intent: accessIntent
              ) else { return [] }

        var files: [TaskFileItem] = []
        while let url = enumerator.nextObject() as? URL {
            // No second containment check, and no unconditional resolve: both
            // were already done, twice, before this line ran.
            //
            // `HostFileAccessBroker.enumerator` wraps its base in a filtering
            // enumerator that runs `shouldSkip` on every child and calls
            // `skipDescendants()` itself, so nothing outside the root can reach
            // here. `shouldSkip` for `.astraManagedStorage` resolves symlinks on
            // both the child *and* the root to do that — meaning this loop used
            // to pay five symlink resolutions per file: two inside the
            // enumerator, one here, and two more in the duplicate `shouldSkip`
            // below it. Each is a `getattrlist(2)` per path component, on the
            // main actor, over a folder that reached 13,295 artifacts. A freeze
            // sample caught the main thread inside `__getattrlist` on 6,333 of
            // 6,333 samples; four fifths of those calls were re-answering a
            // question the enumerator had already answered.
            //
            // What remains for an ordinary file is pure string work. The
            // `rootPath` prefix guard below still holds because the enumerator
            // builds every child by appending to `rootURL`, which was resolved
            // above.
            // Read off the enumerator's own URL: it carries the values prefetched
            // by `includingPropertiesForKeys`, and `standardizedFileURL` is a new
            // URL that does not, so reading through it would re-stat every child.
            let entryValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let entryURL = url.standardizedFileURL

            // One entry kind cannot be classified from its own attributes: a
            // symlink reports `isRegularFile == false` however ordinary the
            // file it points at. Dropping the per-file resolve took that with
            // it, so an in-folder link to a real artifact vanished from the
            // shelf while `TaskGeneratedFiles.files` — which still resolves —
            // went on listing it, and the two views of one folder disagreed.
            //
            // Resolve only the links. That is one extra `getattrlist` for the
            // handful of them a task folder holds, not for the 13,295 artifacts
            // the resolve was removed from, so the freeze this loop was rewritten
            // to fix stays fixed.
            //
            // Taking the *target's* path is deliberate and is what makes the two
            // lists agree: `TaskGeneratedFiles.files` records the resolved path,
            // so a shelf entry keyed on the link path would dedupe against
            // nothing and show the same artifact twice.
            let itemURL = entryValues?.isSymbolicLink == true
                ? entryURL.resolvingSymlinksInPath().standardizedFileURL
                : entryURL
            // Containment is not re-derived here for the unresolved case (see
            // above), but a link's target is a path the loop has not vetted.
            // `HostFileAccessBroker.shouldSkip` compares resolved paths, so the
            // enumerator has already excluded links that leave the root; this
            // prefix guard is what keeps that from being an assumption.
            guard itemURL.path.hasPrefix(rootPath) else { continue }
            let relativePath = String(itemURL.path.dropFirst(rootPath.count))
            guard TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relativePath) else { continue }

            let isRegularFile: Bool
            if entryValues?.isSymbolicLink == true {
                isRegularFile = (try? itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            } else {
                isRegularFile = entryValues?.isRegularFile == true
            }
            guard isRegularFile else { continue }

            files.append(fileItem(
                path: itemURL.path,
                isDirectory: false,
                source: "output",
                fileManager: fileManager
            ))
        }
        return files
    }

    static func referencedItems(in text: String, fileManager: FileManager = .default) -> [TaskFileItem] {
        guard !text.isEmpty,
              let regex = filePathRegex else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seen = Set<String>()
        var files: [TaskFileItem] = []

        for match in matches {
            let path = normalizedPath(nsText.substring(with: match.range))
            guard !path.isEmpty, seen.insert(path).inserted else { continue }

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  shouldIncludeReferencedPath(path) else {
                continue
            }

            files.append(fileItem(
                path: path,
                isDirectory: isDirectory.boolValue,
                source: isDirectory.boolValue ? "folder" : "referenced",
                fileManager: fileManager
            ))
        }

        return files
    }

    static func fileItem(
        path: String,
        isDirectory: Bool,
        source: String,
        change: StoredFileChange? = nil,
        fileManager: FileManager = .default
    ) -> TaskFileItem {
        let size: Int64
        if isDirectory {
            size = 0
        } else {
            size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }

        return TaskFileItem(
            path: path,
            isDirectory: isDirectory,
            size: size,
            source: source,
            change: change,
            destination: isDirectory ? nil : TaskGeneratedFiles.shelfDestination(for: path)
        )
    }

    static func normalizedPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    static func displayName(for path: String, duplicateBasenames: Set<String> = []) -> String {
        let url = URL(fileURLWithPath: path)
        let basename = url.lastPathComponent
        guard duplicateBasenames.contains(basename.lowercased()) else {
            return basename
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? basename : "\(parent)/\(basename)"
    }

    private static func shouldIncludeUserFacingPath(
        _ path: String,
        source: String = "",
        taskFolder: String,
        workspacePath: String = ""
    ) -> Bool {
        if source == "input" {
            return true
        }

        if !taskFolder.isEmpty,
           let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: taskFolder) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .taskFolder
            ) != nil
        }

        if !workspacePath.isEmpty,
           let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: workspacePath) {
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
                relative,
                context: .workspace
            ) != nil
        }

        return true
    }

    private static func shouldIncludeReferencedPath(_ path: String) -> Bool {
        if path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") ||
            path.hasPrefix("/System/") || path.hasPrefix("/Library/") ||
            path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/private/") {
            return false
        }
        return !path.contains("/.claude/")
    }
}
