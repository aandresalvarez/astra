import Foundation
import SwiftData

@Model
final class LocalTool {
    var id: UUID
    var name: String
    var toolDescription: String
    var icon: String
    var toolType: String  // "script", "cli", "mcp"
    var command: String   // path or command to run
    var arguments: String // default arguments
    var isGlobal: Bool = false
    var originPackageID: String?
    var originPackageVersion: String?
    var originComponentID: String?
    var originComponentKind: String?
    var originSourceKind: String?
    var createdAt: Date
    var updatedAt: Date

    var skill: Skill?
    var workspace: Workspace?

    init(
        name: String = "",
        toolDescription: String = "",
        icon: String = "terminal",
        toolType: String = "cli",
        command: String = "",
        arguments: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.toolDescription = toolDescription
        self.icon = icon
        self.toolType = toolType
        self.command = command
        self.arguments = arguments
        self.originPackageID = nil
        self.originPackageVersion = nil
        self.originComponentID = nil
        self.originComponentKind = nil
        self.originSourceKind = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Full command string for display
    var displayCommand: String {
        arguments.isEmpty ? command : "\(command) \(arguments)"
    }

    /// Icon based on tool type
    static func iconForType(_ type: String) -> String {
        switch type {
        case "script": return "doc.text.fill"
        case "mcp": return "puzzlepiece.extension"
        case "cli": return "terminal"
        default: return "wrench"
        }
    }
}
