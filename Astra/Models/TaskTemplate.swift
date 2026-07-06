import Foundation
import SwiftData
import ASTRACore

@Model
public final class TaskTemplate {
    public var id: UUID
    public var name: String
    public var icon: String
    public var templateDescription: String
    public var workspace: Workspace?

    // Phase goals (before/after are optional)
    public var beforeGoal: String
    public var mainGoal: String
    public var afterGoal: String

    // Per-phase token budgets
    public var beforeBudget: Int
    public var mainBudget: Int
    public var afterBudget: Int

    // Per-phase model overrides (empty = use workspace default)
    public var beforeModel: String
    public var mainModel: String
    public var afterModel: String

    // Variables: JSON-encoded array of TemplateVariable
    public var variablesJSON: String

    // Hooks: JSON-encoded TemplateHooks written to .claude/settings.local.json during execution
    public var hooksJSON: String

    // Whether to pass before-phase output as context to the main phase
    public var passContextToMain: Bool

    // Whether to pass main-phase output as context to the after phase
    public var passContextToAfter: Bool

    // Default skills to attach when creating tasks from this template
    public var defaultSkillIDs: [String] = []
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        mainGoal: String,
        workspace: Workspace? = nil,
        icon: String = "rectangle.3.group",
        templateDescription: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.templateDescription = templateDescription
        self.workspace = workspace
        self.beforeGoal = ""
        self.mainGoal = mainGoal
        self.afterGoal = ""
        self.beforeBudget = TaskExecutionDefaults.tokenBudget
        self.mainBudget = TaskExecutionDefaults.tokenBudget
        self.afterBudget = TaskExecutionDefaults.tokenBudget
        self.beforeModel = ""
        self.mainModel = ""
        self.afterModel = ""
        self.variablesJSON = "[]"
        self.hooksJSON = "{}"
        self.passContextToMain = true
        self.passContextToAfter = true
        self.defaultSkillIDs = []
        self.originPackageID = nil
        self.originPackageVersion = nil
        self.originComponentID = nil
        self.originComponentKind = nil
        self.originSourceKind = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Variable helpers

    public var variables: [TemplateVariable] {
        get {
            guard let data = variablesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([TemplateVariable].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            variablesJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    public var hasBeforePhase: Bool { !beforeGoal.isEmpty }
    public var hasAfterPhase: Bool { !afterGoal.isEmpty }

    /// Resolves a goal string by replacing {{variable}} placeholders with provided values
    public func resolveGoal(_ goal: String, with values: [String: String]) -> String {
        var resolved = goal
        for (key, value) in values {
            resolved = resolved.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return resolved
    }
}

// MARK: - Supporting types

public struct TemplateVariable: Codable, Identifiable {
    public var id: UUID
    public var name: String           // e.g. "vm_name"
    public var label: String          // e.g. "VM Name"
    public var defaultValue: String
    public var isRequired: Bool

    public init(name: String, label: String, defaultValue: String = "", isRequired: Bool = true) {
        self.id = UUID()
        self.name = name
        self.label = label
        self.defaultValue = defaultValue
        self.isRequired = isRequired
    }
}

public struct TemplateHooks: Codable {
    public init(preToolUse: [TemplateHookEntry]?, postToolUse: [TemplateHookEntry]?, stop: [TemplateHookEntry]?, notification: [TemplateHookEntry]?) {
        self.preToolUse = preToolUse
        self.postToolUse = postToolUse
        self.stop = stop
        self.notification = notification
    }

    public var preToolUse: [TemplateHookEntry]?
    public var postToolUse: [TemplateHookEntry]?
    public var stop: [TemplateHookEntry]?
    public var notification: [TemplateHookEntry]?

    public enum CodingKeys: String, CodingKey {
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case notification = "Notification"
    }
}

public struct TemplateHookEntry: Codable {
    public init(matcher: String, command: String) {
        self.matcher = matcher
        self.command = command
    }

    public var matcher: String
    public var command: String
}
