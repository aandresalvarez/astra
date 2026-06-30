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
    public static let localMLX = AgentRuntimeID(staticRawValue: "local_mlx")
    public static let codexCLI = AgentRuntimeID(staticRawValue: "codex_cli")
    public static let cursorCLI = AgentRuntimeID(staticRawValue: "cursor_cli")
    public static let openCodeCLI = AgentRuntimeID(staticRawValue: "opencode_cli")

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .copilotCLI: "GitHub Copilot CLI"
        case .antigravityCLI: "Google Antigravity CLI"
        case .localMLX: "Local MLX"
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
    public let executionCapabilities: AgentRuntimeExecutionCapabilities
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
        executionCapabilities: AgentRuntimeExecutionCapabilities = .providerHarness,
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
        self.executionCapabilities = executionCapabilities
        self.supportsNativeContinuation = supportsNativeContinuation
        self.supportsMCPServers = supportsMCPServers
    }

}

public struct AgentRuntimeExecutionCapabilities: Sendable, Equatable {
    public let supportsTextOnly: Bool
    public let supportsAstraBrokeredTools: Bool
    public let supportsProviderNativeTools: Bool
    public let supportsConnectors: Bool
    public let supportsBrowserRead: Bool
    public let supportsBrowserMutation: Bool
    public let supportsFileWrite: Bool
    public let supportsShell: Bool
    public let supportsNetwork: Bool

    public init(
        supportsTextOnly: Bool = true,
        supportsAstraBrokeredTools: Bool = false,
        supportsProviderNativeTools: Bool = false,
        supportsConnectors: Bool = false,
        supportsBrowserRead: Bool = false,
        supportsBrowserMutation: Bool = false,
        supportsFileWrite: Bool = false,
        supportsShell: Bool = false,
        supportsNetwork: Bool = false
    ) {
        self.supportsTextOnly = supportsTextOnly
        self.supportsAstraBrokeredTools = supportsAstraBrokeredTools
        self.supportsProviderNativeTools = supportsProviderNativeTools
        self.supportsConnectors = supportsConnectors
        self.supportsBrowserRead = supportsBrowserRead
        self.supportsBrowserMutation = supportsBrowserMutation
        self.supportsFileWrite = supportsFileWrite
        self.supportsShell = supportsShell
        self.supportsNetwork = supportsNetwork
    }

    public var canExecuteActions: Bool {
        supportsAstraBrokeredTools || supportsProviderNativeTools
    }

    public static let textOnly = AgentRuntimeExecutionCapabilities()

    public static let providerHarness = AgentRuntimeExecutionCapabilities(
        supportsTextOnly: true,
        supportsAstraBrokeredTools: false,
        supportsProviderNativeTools: true,
        supportsConnectors: true,
        supportsBrowserRead: true,
        supportsBrowserMutation: true,
        supportsFileWrite: true,
        supportsShell: true,
        supportsNetwork: true
    )

    public static let astraBrokeredTools = AgentRuntimeExecutionCapabilities(
        supportsTextOnly: true,
        supportsAstraBrokeredTools: true,
        supportsProviderNativeTools: false,
        supportsConnectors: true,
        supportsBrowserRead: true,
        supportsBrowserMutation: true,
        supportsFileWrite: true,
        supportsShell: true,
        supportsNetwork: true
    )
}

public enum AgentEvent: Sendable, Equatable {
    case control(type: String)
    case started(sessionID: String?, model: String?)
    case thinking(text: String)
    case text(text: String)
    case toolUse(name: String, id: String, inputSummary: String?)
    case toolResult(id: String, content: String)
    case fileChange(path: String, kind: String, summary: String?)
    case permissionRequested(tool: String, reason: String)
    case stats(inputTokens: Int, outputTokens: Int, costUSD: Double?, durationMs: Int?, turns: Int?)
    case diagnostic(kind: String, message: String)
    case astraProtocol(AstraRunProtocolParsedEvent)
    case completed(summary: String?)
    case failed(message: String)
    case unknown(provider: String, type: String, raw: String)
}
