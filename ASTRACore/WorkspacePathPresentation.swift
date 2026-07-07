import Foundation

// Moved from `Astra/Services/Persistence/WorkspacePathPresentation.swift` as
// part of Track A2 (breaking the Models↔Runtime cycle): this is a pure
// Foundation-only path-formatting utility with no dependency on anything
// Runtime- or Persistence-specific, and the new `ASTRACore`
// `ExecutionEnvironmentPathMapper`/`ExecutionEnvironmentMount` (also moved in
// this change) call `standardizedPath`. No logic changed — only `public`
// added so the app target's existing call sites keep compiling unchanged.

public struct WorkspacePathDescriptor: Identifiable, Hashable {
    public enum Role: String, Hashable {
        case primary
        case additional

        public var label: String {
            switch self {
            case .primary: "Primary"
            case .additional: "Additional"
            }
        }
    }

    public let id: String
    public let role: Role
    public let index: Int
    public let path: String
    public let title: String
    public let subtitle: String
    public let abbreviatedPath: String

    public var roleLabel: String { role.label }

    public init(
        id: String,
        role: Role,
        index: Int,
        path: String,
        title: String,
        subtitle: String,
        abbreviatedPath: String
    ) {
        self.id = id
        self.role = role
        self.index = index
        self.path = path
        self.title = title
        self.subtitle = subtitle
        self.abbreviatedPath = abbreviatedPath
    }
}

public enum WorkspacePathPresentation {
    public static func descriptors(primaryPath: String, additionalPaths: [String]) -> [WorkspacePathDescriptor] {
        let rawEntries = ([primaryPath] + additionalPaths).enumerated().compactMap { index, rawPath -> RawEntry? in
            let path = standardizedPath(rawPath)
            guard !path.isEmpty else { return nil }
            let role: WorkspacePathDescriptor.Role = index == 0 ? .primary : .additional
            return RawEntry(role: role, index: index, path: path)
        }

        var seen: Set<String> = []
        let entries = rawEntries.filter { entry in
            seen.insert(entry.path).inserted
        }
        let titleMap = disambiguatedTitles(for: entries)

        return entries.map { entry in
            let abbreviatedPath = abbreviatePath(entry.path)
            let title = titleMap[entry.path] ?? folderName(for: entry.path)
            return WorkspacePathDescriptor(
                id: entry.path,
                role: entry.role,
                index: entry.index,
                path: entry.path,
                title: title,
                subtitle: "\(entry.role.label) - \(abbreviatedPath)",
                abbreviatedPath: abbreviatedPath
            )
        }
    }

    public static func descriptor(
        for path: String,
        primaryPath: String,
        additionalPaths: [String]
    ) -> WorkspacePathDescriptor? {
        let standardized = standardizedPath(path)
        return descriptors(primaryPath: primaryPath, additionalPaths: additionalPaths)
            .first { $0.path == standardized }
    }

    public static func isGitRepository(at path: String, fileManager: FileManager = .default) -> Bool {
        let standardized = standardizedPath(path)
        guard !standardized.isEmpty else { return false }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let gitPath = URL(fileURLWithPath: standardized, isDirectory: true)
            .appendingPathComponent(".git")
            .path
        return fileManager.fileExists(atPath: gitPath)
    }

    public static func standardizedPath(_ rawPath: String) -> String {
        let expanded = NSString(string: rawPath)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    public static func abbreviatePath(_ path: String) -> String {
        let standardized = standardizedPath(path)
        guard !standardized.isEmpty else { return "" }
        let home = NSHomeDirectory()
        let homePrefix = home + "/"
        let displayPath: String
        if standardized == home {
            displayPath = "~"
        } else if standardized.hasPrefix(homePrefix) {
            displayPath = "~/" + standardized.dropFirst(homePrefix.count)
        } else {
            displayPath = standardized
        }

        let components = displayPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 4 else { return displayPath }
        let prefix = displayPath.hasPrefix("~/") ? "~" : (displayPath.hasPrefix("/") ? "" : components.first ?? "")
        let suffix = components.suffix(3).joined(separator: "/")
        return prefix.isEmpty ? "/.../\(suffix)" : "\(prefix)/.../\(suffix)"
    }

    private struct RawEntry: Hashable {
        public let role: WorkspacePathDescriptor.Role
        public let index: Int
        public let path: String
    }

    private static func disambiguatedTitles(for entries: [RawEntry]) -> [String: String] {
        let groupedByFolder = Dictionary(grouping: entries, by: { folderName(for: $0.path).lowercased() })
        var titles: [String: String] = [:]

        for (_, duplicates) in groupedByFolder {
            if duplicates.count == 1, let entry = duplicates.first {
                titles[entry.path] = folderName(for: entry.path)
                continue
            }

            let parentTitles = duplicates.map { entry in
                let folder = folderName(for: entry.path)
                let parent = parentFolderName(for: entry.path)
                return (entry, parent.isEmpty ? folder : "\(parent)/\(folder)")
            }
            let groupedByParentTitle = Dictionary(grouping: parentTitles, by: { $0.1.lowercased() })
            for (entry, parentTitle) in parentTitles {
                if groupedByParentTitle[parentTitle.lowercased()]?.count == 1 {
                    titles[entry.path] = parentTitle
                } else {
                    titles[entry.path] = abbreviatePath(entry.path)
                }
            }
        }

        return titles
    }

    private static func folderName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func parentFolderName(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = URL(fileURLWithPath: parent).lastPathComponent
        return name == "/" ? "" : name
    }
}
