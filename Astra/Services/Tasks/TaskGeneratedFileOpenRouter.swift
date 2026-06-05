import Foundation

enum TaskGeneratedFileOpenRoute: Equatable {
    case shelf(path: String)
    case system(path: String)
}

enum TaskGeneratedFileOpenRouter {
    static func route(
        path: String,
        destination: TaskGeneratedFileShelfDestination?,
        canOpenInShelf: Bool
    ) -> TaskGeneratedFileOpenRoute {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard destination != nil, canOpenInShelf else {
            return .system(path: normalizedPath)
        }
        return .shelf(path: normalizedPath)
    }

    static func route(fileURL url: URL, canOpenInShelf: Bool) -> TaskGeneratedFileOpenRoute? {
        guard url.isFileURL,
              canOpenInShelf,
              TaskGeneratedFiles.shelfDestination(for: url.path) != nil else {
            return nil
        }
        return .shelf(path: url.path)
    }

    static func textShelfItems(_ items: [TaskFileItem]) -> [TaskFileItem] {
        items.filter { $0.destination == .files }
    }

    static func canOpenTextShelfItems(_ items: [TaskFileItem], canOpenInShelf: Bool) -> Bool {
        canOpenInShelf && !textShelfItems(items).isEmpty
    }
}
