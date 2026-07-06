import Foundation
import SwiftData

@Model
public final class LocalTool {
    public var id: UUID
    public var name: String
    public var toolDescription: String
    public var icon: String
    public var toolType: String  // "script", "cli", "mcp"
    public var command: String   // path or command to run
    public var arguments: String // default arguments
    public var isGlobal: Bool = false
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var skill: Skill?
    public var workspace: Workspace?

    public init(
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
    public var displayCommand: String {
        arguments.isEmpty ? command : "\(command) \(arguments)"
    }

    /// Icon based on tool type
    public static func iconForType(_ type: String) -> String {
        switch type {
        case "script": return "doc.text.fill"
        case "mcp": return "puzzlepiece.extension"
        case "cli": return "terminal"
        default: return "wrench"
        }
    }
}
