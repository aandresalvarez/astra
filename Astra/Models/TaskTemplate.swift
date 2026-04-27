import Foundation
import SwiftData

@Model
final class TaskTemplate {
    var id: UUID
    var name: String
    var icon: String
    var templateDescription: String
    var workspace: Workspace?

    // Phase goals (before/after are optional)
    var beforeGoal: String
    var mainGoal: String
    var afterGoal: String

    // Per-phase token budgets
    var beforeBudget: Int
    var mainBudget: Int
    var afterBudget: Int

    // Per-phase model overrides (empty = use workspace default)
    var beforeModel: String
    var mainModel: String
    var afterModel: String

    // Variables: JSON-encoded array of TemplateVariable
    var variablesJSON: String

    // Hooks: JSON-encoded TemplateHooks written to .claude/settings.local.json during execution
    var hooksJSON: String

    // Whether to pass before-phase output as context to the main phase
    var passContextToMain: Bool

    // Whether to pass main-phase output as context to the after phase
    var passContextToAfter: Bool

    // Default skills to attach when creating tasks from this template
    var defaultSkillIDs: [String] = []

    var createdAt: Date
    var updatedAt: Date

    init(
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
        self.beforeBudget = 20000
        self.mainBudget = 50000
        self.afterBudget = 20000
        self.beforeModel = ""
        self.mainModel = ""
        self.afterModel = ""
        self.variablesJSON = "[]"
        self.hooksJSON = "{}"
        self.passContextToMain = true
        self.passContextToAfter = true
        self.defaultSkillIDs = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Variable helpers

    var variables: [TemplateVariable] {
        get {
            guard let data = variablesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([TemplateVariable].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            variablesJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var hasBeforePhase: Bool { !beforeGoal.isEmpty }
    var hasAfterPhase: Bool { !afterGoal.isEmpty }

    /// Resolves a goal string by replacing {{variable}} placeholders with provided values
    func resolveGoal(_ goal: String, with values: [String: String]) -> String {
        var resolved = goal
        for (key, value) in values {
            resolved = resolved.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return resolved
    }
}

// MARK: - Supporting types

struct TemplateVariable: Codable, Identifiable {
    var id: UUID
    var name: String           // e.g. "vm_name"
    var label: String          // e.g. "VM Name"
    var defaultValue: String
    var isRequired: Bool

    init(name: String, label: String, defaultValue: String = "", isRequired: Bool = true) {
        self.id = UUID()
        self.name = name
        self.label = label
        self.defaultValue = defaultValue
        self.isRequired = isRequired
    }
}

struct TemplateHooks: Codable {
    var preToolUse: [TemplateHookEntry]?
    var postToolUse: [TemplateHookEntry]?
    var stop: [TemplateHookEntry]?
    var notification: [TemplateHookEntry]?

    enum CodingKeys: String, CodingKey {
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case notification = "Notification"
    }
}

struct TemplateHookEntry: Codable {
    var matcher: String
    var command: String
}
