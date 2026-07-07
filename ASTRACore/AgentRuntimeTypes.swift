import Foundation

public struct AgentRuntimeID: RawRepresentable, Codable, Sendable, Hashable, Identifiable {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    private init(staticRawValue: String) {
        self.rawValue = staticRawValue
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        if let rawValue = try? decoder.singleValueContainer().decode(String.self) {
            guard let runtime = AgentRuntimeID(rawValue: rawValue) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Agent runtime ID cannot be empty.")
                )
            }
            self = runtime
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        guard let runtime = AgentRuntimeID(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: container,
                debugDescription: "Agent runtime ID cannot be empty."
            )
        }
        self = runtime
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claudeCode = AgentRuntimeID(staticRawValue: "claude_code")
    public static let copilotCLI = AgentRuntimeID(staticRawValue: "copilot_cli")
    public static let antigravityCLI = AgentRuntimeID(staticRawValue: "antigravity_cli")
    public static let codexCLI = AgentRuntimeID(staticRawValue: "codex_cli")
    public static let cursorCLI = AgentRuntimeID(staticRawValue: "cursor_cli")
    public static let openCodeCLI = AgentRuntimeID(staticRawValue: "opencode_cli")

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .copilotCLI: "GitHub Copilot CLI"
        case .antigravityCLI: "Google Antigravity CLI"
        case .codexCLI: "Codex CLI"
        case .cursorCLI: "Cursor CLI"
        case .openCodeCLI: "OpenCode CLI"
        default: rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
        }
    }
}

public struct RunPhase: Codable, Sendable, Hashable, Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let run = RunPhase(rawValue: "run")
    public static let resume = RunPhase(rawValue: "resume")
    public static let approvedPlan = RunPhase(rawValue: "approved_plan")
}

public struct AgentRuntimeDescriptor: Sendable, Equatable, Identifiable {
    public let id: AgentRuntimeID
    public let displayName: String
    public let executableName: String
    public let installHint: String
    public let authHint: String
    public let prerequisite: CLIPrerequisite
    public let defaultModel: String
    public let defaultModels: [String]
    public let supportsAstraRunProtocol: Bool
    public let supportsNativeContinuation: Bool
    /// Whether capability-package MCP servers are materialized into this
    /// runtime's launches. Runtimes without support surface the skip
    /// explicitly instead of silently dropping declared servers.
    public let supportsMCPServers: Bool

    public init(
        id: AgentRuntimeID,
        displayName: String,
        executableName: String,
        installHint: String,
        authHint: String,
        prerequisite: CLIPrerequisite? = nil,
        defaultModel: String? = nil,
        defaultModels: [String],
        supportsAstraRunProtocol: Bool,
        supportsNativeContinuation: Bool = false,
        supportsMCPServers: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.installHint = installHint
        self.authHint = authHint
        self.prerequisite = prerequisite ?? CLIPrerequisite(
            binary: executableName,
            displayName: displayName,
            purpose: "Runs tasks when \(displayName) is the selected provider.",
            installHint: installHint,
            authHint: authHint
        )
        self.defaultModel = defaultModel ?? defaultModels.first ?? "default"
        self.defaultModels = defaultModels
        self.supportsAstraRunProtocol = supportsAstraRunProtocol
        self.supportsNativeContinuation = supportsNativeContinuation
        self.supportsMCPServers = supportsMCPServers
    }

}

public enum AgentEvent: Sendable, Equatable {
    case control(type: String)
    case started(sessionID: String?, model: String?)
    case thinking(text: String)
    case text(text: String)
    case toolUse(name: String, id: String, inputSummary: String?)
    case toolResult(id: String, content: String)
    /// `oldString`/`newString` carry a precise before/after diff when the
    /// originating provider's structured tool input has them (currently only
    /// Claude's `Edit` tool). Other providers always pass `nil` here and rely
    /// on `summary` alone.
    case fileChange(path: String, kind: String, summary: String?, oldString: String? = nil, newString: String? = nil)
    case permissionRequested(tool: String, reason: String)
    case stats(inputTokens: Int, outputTokens: Int, costUSD: Double?, durationMs: Int?, turns: Int?)
    case astraProtocol(AstraRunProtocolParsedEvent)
    case completed(summary: String?)
    case failed(message: String)
    /// In-process teammate orchestration events. Currently only Claude Code's
    /// CLI emits `local_agent`/`in_process_teammate` system events; the other
    /// five runtimes never produce these, so this case is Claude-only in
    /// practice but lives on the shared type so Claude can route through the
    /// single provider-agnostic recording dispatcher like every other runtime.
    case teamEvent(AgentTeamEvent)
    case unknown(provider: String, type: String, raw: String)
}

/// Structured payload for `AgentEvent.teamEvent`. Mirrors the team-oriented
/// cases that used to live directly on `ParsedEvent` (Claude's in-process
/// teammate feature: `TeamCreate`/`TeamDelete`/`SendMessage` tool calls plus
/// `local_agent`/`in_process_teammate` system lifecycle events).
public enum AgentTeamEvent: Sendable, Equatable {
    case teammateStarted(taskId: String, name: String, prompt: String)
    case teammateCompleted(taskId: String, name: String)
    case teamCreated(name: String, description: String)
    case teamDeleted(name: String)
    case teamMessage(from: String, to: String, content: String)
}
