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

    public init(
        id: AgentRuntimeID,
        displayName: String,
        executableName: String,
        installHint: String,
        authHint: String,
        prerequisite: CLIPrerequisite? = nil,
        defaultModel: String? = nil,
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
        self.defaultModel = defaultModel ?? defaultModels.first ?? "default"
        self.defaultModels = defaultModels
        self.supportsAstraRunProtocol = supportsAstraRunProtocol
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
