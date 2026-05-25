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

    public static let claudeCode = AgentRuntimeID(staticRawValue: "claude_code")
    public static let copilotCLI = AgentRuntimeID(staticRawValue: "copilot_cli")

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .copilotCLI: "GitHub Copilot CLI"
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

    public var defaultModel: String {
        switch self {
        case .claudeCode: "claude-sonnet-4-6"
        case .copilotCLI: "claude-sonnet-4.6"
        default: "default"
        }
    }

    public var defaultModels: [String] {
        switch self {
        case .claudeCode:
            ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case .copilotCLI:
            [
                "claude-sonnet-4.6",
                "claude-sonnet-4.5",
                "claude-haiku-4.5",
                "claude-opus-4.7",
                "claude-opus-4.6",
                "claude-opus-4.5",
                "gpt-5.2-codex",
                "gpt-5.2",
                "gpt-5-mini",
                "gpt-4.1"
            ]
        default:
            [defaultModel]
        }
    }

    public var supportsAstraRunProtocol: Bool {
        switch self {
        case .claudeCode, .copilotCLI:
            true
        default:
            false
        }
    }
}

public struct AgentRuntimeDescriptor: Sendable, Equatable, Identifiable {
    public let id: AgentRuntimeID
    public let displayName: String
    public let executableName: String
    public let installHint: String
    public let authHint: String
    public let prerequisite: CLIPrerequisite
    public let defaultModels: [String]
    public let supportsAstraRunProtocol: Bool

    public init(
        id: AgentRuntimeID,
        displayName: String,
        executableName: String,
        installHint: String,
        authHint: String,
        prerequisite: CLIPrerequisite? = nil,
        defaultModels: [String],
        supportsAstraRunProtocol: Bool
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
        self.defaultModels = defaultModels
        self.supportsAstraRunProtocol = supportsAstraRunProtocol
    }

    public static let claudeCode = AgentRuntimeDescriptor(
        id: .claudeCode,
        displayName: AgentRuntimeID.claudeCode.displayName,
        executableName: "claude",
        installHint: "Install via npm: `npm install -g @anthropic-ai/claude-code`",
        authHint: "Run `claude /login` or set `ANTHROPIC_API_KEY`.",
        prerequisite: CommonCLIPrerequisites.claude,
        defaultModels: AgentRuntimeID.claudeCode.defaultModels,
        supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
    )

    public static let copilotCLI = AgentRuntimeDescriptor(
        id: .copilotCLI,
        displayName: AgentRuntimeID.copilotCLI.displayName,
        executableName: "copilot",
        installHint: "Install via Homebrew: `brew install copilot-cli` or npm: `npm install -g @github/copilot`",
        authHint: "Run `copilot` and use `/login`, or set a GitHub token with Copilot access.",
        prerequisite: CommonCLIPrerequisites.copilot,
        defaultModels: AgentRuntimeID.copilotCLI.defaultModels,
        supportsAstraRunProtocol: AgentRuntimeID.copilotCLI.supportsAstraRunProtocol
    )
}

public enum AgentRuntimeRegistry {
    public static let builtInDescriptors: [AgentRuntimeDescriptor] = [
        .claudeCode,
        .copilotCLI
    ]

    public static func descriptor(for runtime: AgentRuntimeID) -> AgentRuntimeDescriptor {
        builtInDescriptors.first { $0.id == runtime } ?? AgentRuntimeDescriptor(
            id: runtime,
            displayName: runtime.displayName,
            executableName: runtime.rawValue,
            installHint: "",
            authHint: "",
            defaultModels: runtime.defaultModels,
            supportsAstraRunProtocol: runtime.supportsAstraRunProtocol
        )
    }
}

public enum AgentEvent: Sendable, Equatable {
    case started(sessionID: String?, model: String?)
    case thinking(text: String)
    case text(text: String)
    case toolUse(name: String, id: String, inputSummary: String?)
    case toolResult(id: String, content: String)
    case fileChange(path: String, kind: String, summary: String?)
    case permissionRequested(tool: String, reason: String)
    case stats(inputTokens: Int, outputTokens: Int, costUSD: Double?, durationMs: Int?, turns: Int?)
    case astraProtocol(AstraRunProtocolParsedEvent)
    case completed(summary: String?)
    case failed(message: String)
    case unknown(provider: String, type: String, raw: String)
}
