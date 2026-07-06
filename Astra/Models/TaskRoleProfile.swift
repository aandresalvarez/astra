import Foundation
import ASTRACore

public enum TaskRoleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case planner
    case worker
    case verifier
    case browserTester = "browser_tester"
    case summarizer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .planner: "Planner"
        case .worker: "Worker"
        case .verifier: "Verifier"
        case .browserTester: "Browser Tester"
        case .summarizer: "Summarizer"
        }
    }

    public var detail: String {
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

    public var symbolName: String {
        switch self {
        case .planner: "list.bullet.clipboard"
        case .worker: "hammer"
        case .verifier: "checkmark.seal"
        case .browserTester: "safari"
        case .summarizer: "text.alignleft"
        }
    }
}

public struct TaskRoleProfile: Codable, Equatable, Sendable {
    public init(role: TaskRoleID, runtimeID: String, model: String, tokenBudget: Int, policyLevelRaw: String) {
        self.role = role
        self.runtimeID = runtimeID
        self.model = model
        self.tokenBudget = tokenBudget
        self.policyLevelRaw = policyLevelRaw
    }

    public var role: TaskRoleID
    public var runtimeID: String
    public var model: String
    public var tokenBudget: Int
    public var policyLevelRaw: String

    /// Goes through the `AgentRuntimeRegistrySeam` seam (ASTRACore) rather
    /// than calling `AgentRuntimeAdapterRegistry` directly, since this file
    /// would otherwise depend on the Runtime subsystem's adapter catalog —
    /// see docs/architecture/swiftpm-target-extraction-models-persistence.md,
    /// Finding 1. `.claudeCode` is the current value of
    /// `TaskExecutionDefaults.runtime` (Settings), inlined here rather than
    /// referenced, since the seam protocol takes an explicit fallback and
    /// must not itself depend on Settings; if `TaskExecutionDefaults.runtime`
    /// ever changes, update this literal to match.
    public var runtime: AgentRuntimeID {
        AgentRuntimeRegistrySeam.required.registeredRuntime(rawValue: runtimeID, fallback: .claudeCode)
    }

    public var policyLevel: AgentPolicyLevel {
        AgentPolicyLevel.normalized(policyLevelRaw).userFacingLevel
    }
}

public struct TaskRoleProfileSelection: Equatable, Sendable {
    public init(profile: TaskRoleProfile, source: String) {
        self.profile = profile
        self.source = source
    }

    public var profile: TaskRoleProfile
    public var source: String
}

public enum TaskRoleProfileEventTypes {
    public static let selected = TaskEventTypes.RoleProfile.selected.rawValue
    public static let changed = TaskEventTypes.RoleProfile.changed.rawValue
}

public struct TaskRoleProfileEventPayload: Codable, Equatable, Sendable {
    public init(version: Int = 1, role: TaskRoleID, runtimeID: String, model: String, tokenBudget: Int, policyLevelRaw: String, source: String) {
        self.version = version
        self.role = role
        self.runtimeID = runtimeID
        self.model = model
        self.tokenBudget = tokenBudget
        self.policyLevelRaw = policyLevelRaw
        self.source = source
    }

    public var version: Int = 1
    public var role: TaskRoleID
    public var runtimeID: String
    public var model: String
    public var tokenBudget: Int
    public var policyLevelRaw: String
    public var source: String
}
