import AppKit
import Foundation

struct WorkspaceImportPanelConfiguration: Equatable {
    var canChooseDirectories: Bool
    var canChooseFiles: Bool
    var allowsMultipleSelection: Bool
    var message: String
    var prompt: String

    static let workspaceImport = WorkspaceImportPanelConfiguration(
        canChooseDirectories: true,
        canChooseFiles: true,
        allowsMultipleSelection: true,
        message: "Select workspace folders, config files, or a parent Workspaces folder",
        prompt: "Import"
    )

    @MainActor
    func apply(to panel: NSOpenPanel) {
        panel.canChooseDirectories = canChooseDirectories
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.message = message
        panel.prompt = prompt
    }
}

@MainActor
enum WorkspaceImportPanel {
    static func selectedURLs(configuration: WorkspaceImportPanelConfiguration = .workspaceImport) -> [URL] {
        let panel = NSOpenPanel()
        configuration.apply(to: panel)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

@MainActor
enum WorkspaceDuplicateActionPrompt {
    static func ask(
        name: String,
        existingTaskCount: Int
    ) -> TaskLifecycleCoordinator.DuplicateAction {
        let alert = NSAlert()
        alert.messageText = "Workspace \"\(name)\" already exists"
        alert.informativeText = "The existing workspace has \(existingTaskCount) task(s). What would you like to do?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .duplicate
        default: return .skip
        }
    }
}
