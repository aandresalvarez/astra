import Foundation

/// Errors surfaced by ContentView's Workspace App detail-area actions (run / export) when the
/// required workspace context isn't available. Extracted from ContentView to keep that large
/// owner under its line budget; the type is module-internal and only used there.
enum WorkspaceAppUIError: LocalizedError {
    case noWorkspace
    case exportUnavailableFromDetail

    var errorDescription: String? {
        switch self {
        case .noWorkspace:
            return "Select a workspace before running this app action."
        case .exportUnavailableFromDetail:
            return "Export this app from the App Studio sharing flow."
        }
    }
}
