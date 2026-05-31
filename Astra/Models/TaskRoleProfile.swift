import Foundation
import ASTRACore

enum TaskRoleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case planner
    case worker
    case verifier
    case browserTester = "browser_tester"
    case summarizer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .planner: "Planner"
        case .worker: "Worker"
        case .verifier: "Verifier"
        case .browserTester: "Browser Tester"
        case .summarizer: "Summarizer"
        }
    }

    var detail: String {
        switch self {
        case .planner:
            "Turns a goal into a plan and validation contract."
        case .worker:
            "Runs the main implementation task."
        case .verifier:
            "Reviews evidence independently before completion."
        case .browserTester:
            "Checks user-facing behavior and browser-visible results."
        case .summarizer:
            "Writes handoffs, titles, and compact summaries."
        }
    }

    var symbolName: String {
        switch self {
        case .planner: "list.bullet.clipboard"
        case .worker: "hammer"
        case .verifier: "checkmark.seal"
        case .browserTester: "safari"
        case .summarizer: "text.alignleft"
        }
    }
}

struct TaskRoleProfile: Codable, Equatable, Sendable {
    var role: TaskRoleID
    var runtimeID: String
    var model: String
    var tokenBudget: Int
    var policyLevelRaw: String

    var runtime: AgentRuntimeID {
        AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
    }

    var policyLevel: AgentPolicyLevel {
        AgentPolicyLevel.normalized(policyLevelRaw).userFacingLevel
    }
}

struct TaskRoleProfileSelection: Equatable, Sendable {
    var profile: TaskRoleProfile
    var source: String
}

enum TaskRoleProfileEventTypes {
    static let selected = "role.profile.selected"
    static let changed = "role.profile.changed"
}

struct TaskRoleProfileEventPayload: Codable, Equatable, Sendable {
    var version: Int = 1
    var role: TaskRoleID
    var runtimeID: String
    var model: String
    var tokenBudget: Int
    var policyLevelRaw: String
    var source: String
}
