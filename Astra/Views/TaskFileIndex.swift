import Foundation

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
        switch change.changeType.lowercased() {
        case "write": return "created"
        case "edit": return "edited"
        default: return change.changeType.lowercased()
        }
    }

    static func headerItems(
        runs: [TaskRunSnapshot],
        generatedFilePaths: [String],
        inputs: [String],
        fileManager: FileManager = .default
    ) -> [TaskFileItem] {
        var seen = Set<String>()
        var items: [TaskFileItem] = []

        func append(path rawPath: String, source: String, change: StoredFileChange? = nil) {
            let path = normalizedPath(rawPath)
            guard !path.isEmpty, seen.insert(path).inserted else { return }

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
        fileManager: FileManager = .default
    ) -> [TaskFileItem] {
        var files: [TaskFileItem] = []
        var seen = Set<String>()

        if let latestRun {
            for change in latestRun.fileChanges {
                let path = normalizedPath(change.path)
                guard !path.isEmpty, seen.insert(path).inserted else { continue }
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
            files.append(file)
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
            files.append(file)
        }

        return files
    }

    static func scanTaskFolder(_ folder: String, fileManager: FileManager = .default) -> [TaskFileItem] {
        guard !folder.isEmpty, fileManager.fileExists(atPath: folder) else { return [] }
        guard let enumerator = fileManager.enumerator(atPath: folder) else { return [] }

        var files: [TaskFileItem] = []
        while let relativePath = enumerator.nextObject() as? String {
            guard TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relativePath) else { continue }
            let fullPath = (folder as NSString).appendingPathComponent(relativePath)
            var isDirectory = ObjCBool(false)
            fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }

            files.append(fileItem(
                path: fullPath,
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

    private static func shouldIncludeReferencedPath(_ path: String) -> Bool {
        if path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") ||
            path.hasPrefix("/System/") || path.hasPrefix("/Library/") ||
            path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/private/") {
            return false
        }
        return !path.contains("/.claude/")
    }
}
