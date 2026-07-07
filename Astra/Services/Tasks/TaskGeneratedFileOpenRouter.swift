import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

enum TaskGeneratedFileOpenRoute: Equatable {
    case shelf(path: String)
    case system(path: String)
}

enum TaskGeneratedFileOpenRouter {
    static func canOpenInShelf(
        destination: TaskGeneratedFileShelfDestination?,
        policy: ShelfAvailabilityPolicy,
        context: ShelfAvailabilityPolicy.Context
    ) -> Bool {
        guard let destination else { return false }
        var routeContext = context
        if destination == .query {
            routeContext.hasQueryShelfContent = true
        }
        return policy.canPresent(destination.shelfID, in: routeContext)
    }

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
