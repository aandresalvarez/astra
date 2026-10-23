import Foundation
import ASTRACore

enum CapabilityImportPresentation {
    static let actionTitle = "Import Capability"

    static func overviewDescription(for package: PluginPackage, contentSummary _: String) -> String {
        let description = package.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "No description provided." : description
    }

    static func shouldShowContentSummary(for package: PluginPackage) -> Bool {
        !package.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum CapabilityCreationPresentation {
    static let menuTitle = "New Capability"
    static let blankCapabilityTitle = "Blank Capability"
    static let mcpCapabilityTitle = "Create from MCP..."
    static let pasteSheetTitle = "Create from MCP"
    static let pasteSheetSubtitle = "Paste an MCP package command, registry target, server URL, or server JSON. ASTRA will prepare a draft capability for review."
    static let menuHelp = "Create a blank capability or start from an MCP package command, URL, or server JSON."
    static let primaryActionTitles = [CapabilityImportPresentation.actionTitle, menuTitle]
    static let mcpPasteSheetWidth = 560
    static let mcpPasteSheetMinimumHeight = 430
    static let mcpPasteTextEditorMinimumHeight = 150
}
