import AppKit
import ASTRAModels

/// Both folder actions share the configured-roots guard. Choosing a primary
/// folder repairs an empty workspace; adding an extra folder never replaces it.
@MainActor
enum WorkspaceRailFolderPicker {
    enum Purpose { case primary, additional }

    static func choose(_ purpose: Purpose, for workspace: Workspace,
                       selectPath: (Purpose) -> String? = present) -> WorkspaceConfiguredRoots.Outcome {
        guard let path = selectPath(purpose) else { return .unchanged }
        switch purpose {
        case .primary: return WorkspaceConfiguredRoots.setPrimaryPath(path, on: workspace)
        case .additional: return WorkspaceConfiguredRoots.addAdditionalPaths([path], to: workspace)
        }
    }

    private static func present(_ purpose: Purpose) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = purpose == .primary ? "Choose this workspace's primary folder"
            : "Choose a folder the agent can also read from or execute in"
        panel.prompt = purpose == .primary ? "Choose Folder" : "Add Folder"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
