import Foundation

enum TaskGeneratedFileShelfDestination: Equatable {
    case browser
    case files
    case query

    var title: String {
        switch self {
        case .browser: "Open in Browser Shelf"
        case .files: "Open in Files Shelf"
        case .query: "Open in Query Shelf"
        }
    }

    var compactTitle: String {
        switch self {
        case .browser: "Browser"
        case .files: "Files"
        case .query: "Query"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: "globe"
        case .files: "doc.text"
        case .query: "cylinder.split.1x2"
        }
    }
}

enum TaskGeneratedFiles {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "qmd"]

    private static let filesShelfExtensions: Set<String> = [
        "md", "markdown", "qmd", "txt", "text", "log",
        "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "xml", "plist",
        "swift", "py", "js", "jsx", "ts", "tsx", "css", "scss", "html", "htm",
        "sh", "bash", "zsh", "fish", "sql", "r", "rb", "go", "rs",
        "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm",
        "php", "pl", "lua", "env", "ini", "cfg", "conf"
    ]

    private static let filesShelfFileNames: Set<String> = [
        ".env", ".gitignore", ".npmrc", ".zshrc", ".bashrc",
        "dockerfile", "makefile", "rakefile", "gemfile", "podfile",
        "readme", "license", "changelog"
    ]

    static func files(in folder: String, fileManager: FileManager = .default) -> [String] {
        guard !folder.isEmpty, fileManager.fileExists(atPath: folder) else { return [] }
        guard let enumerator = fileManager.enumerator(atPath: folder) else { return [] }

        var files: [String] = []
        while let rel = enumerator.nextObject() as? String {
            guard shouldDisplayTaskFolderFile(relativePath: rel) else { continue }
            let full = (folder as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: full, isDirectory: &isDir)
            if !isDir.boolValue {
                files.append(full)
            }
        }
        return files.sorted()
    }

    static func shouldDisplayTaskFolderFile(relativePath: String) -> Bool {
        let rel = relativePath.replacingOccurrences(of: "\\", with: "/")
        if rel == "session_history.md" || rel == "outputs" || rel.hasPrefix("outputs/") {
            return false
        }
        if rel == ".runtime-bin" || rel.hasPrefix(".runtime-bin/") {
            return false
        }
        return true
    }

    static func filesAsync(in folder: String) async -> [String] {
        await Task.detached(priority: .utility) {
            files(in: folder)
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
        ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isMarkdownFile(_ path: String) -> Bool {
        markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isSQLFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "sql"
    }

    static func isFilesShelfFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        return filesShelfExtensions.contains(ext)
            || filesShelfFileNames.contains(name)
            || name.hasPrefix(".env.")
    }

    static func shelfDestination(for path: String) -> TaskGeneratedFileShelfDestination? {
        if isHTMLFile(path) { return .browser }
        if isSQLFile(path) { return .query }
        if isFilesShelfFile(path) { return .files }
        return nil
    }

    static func shouldAutoLoadHTMLPreview(currentBrowserURL: String, targetPath: String) -> Bool {
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
