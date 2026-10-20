import Foundation

/// The hover card and context menu derive Finder availability from the same path.
enum WorkspaceFinderDestination {
    static func url(for path: String) -> URL? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
