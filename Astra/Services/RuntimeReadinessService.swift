import Foundation
import ASTRACore

enum RuntimeReadinessState: String, Sendable, Equatable {
    case ready
    case warning
    case blocked
}

struct RuntimeReadinessCheck: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let detail: String
    let state: RuntimeReadinessState
    let remediation: String?
}

struct RuntimeReadinessReport: Sendable, Equatable {
    let checks: [RuntimeReadinessCheck]

    var state: RuntimeReadinessState {
        if checks.contains(where: { $0.state == .blocked }) { return .blocked }
        if checks.contains(where: { $0.state == .warning }) { return .warning }
        return .ready
    }

    var summary: String {
        switch state {
        case .ready:
            return "Ready to run tasks"
        case .warning:
            return "Usable, with follow-up recommended"
        case .blocked:
            return "Needs attention before tasks will run reliably"
        }
    }
}

struct RuntimeReadinessConfiguration: Sendable, Equatable {
    var runtime: AgentRuntimeID
    var providerSettings: AgentRuntimeProviderSettings
    var claudeProvider: ClaudeProvider
    var vertexProjectID: String
    var vertexRegion: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String

    init(
        runtime: AgentRuntimeID,
        claudePath: String,
        copilotPath: String,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String
    ) {
        self.init(
            runtime: runtime,
            providerSettings: AgentRuntimeProviderSettings(
                executablePaths: [
                    .claudeCode: claudePath,
                    .copilotCLI: copilotPath
                ],
                homeDirectories: [
                    .copilotCLI: CopilotCLIRuntime.channelHome()
                ]
            ),
            claudeProvider: claudeProvider,
            vertexProjectID: vertexProjectID,
            vertexRegion: vertexRegion,
            vertexOpusModel: vertexOpusModel,
            vertexSonnetModel: vertexSonnetModel,
            vertexHaikuModel: vertexHaikuModel
        )
    }

    init(
        runtime: AgentRuntimeID,
        providerSettings: AgentRuntimeProviderSettings,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String
    ) {
        self.runtime = runtime
        self.providerSettings = providerSettings
        self.claudeProvider = claudeProvider
        self.vertexProjectID = vertexProjectID
        self.vertexRegion = vertexRegion
        self.vertexOpusModel = vertexOpusModel
        self.vertexSonnetModel = vertexSonnetModel
        self.vertexHaikuModel = vertexHaikuModel
    }

    var claudePath: String {
        providerSettings.executablePath(for: .claudeCode)
    }

    var copilotPath: String {
        providerSettings.executablePath(for: .copilotCLI)
    }

    func executablePath(for runtime: AgentRuntimeID) -> String {
        providerSettings.executablePath(for: runtime)
    }
}

struct RuntimeReadinessService {
    private let runner: BinaryRunner
    private let timeout: TimeInterval
    private let detectExecutable: @Sendable (String) -> String
    private let isExecutable: @Sendable (String) -> Bool

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        timeout: TimeInterval = 5,
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimeReadinessService.defaultDetectExecutable($0)
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
    }

    func check(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessReport {
        let probes = RuntimeReadinessProbeContext(
            runner: runner,
            timeout: timeout,
            detectExecutable: detectExecutable,
            isExecutable: isExecutable
        )
        return await AgentRuntimeAdapterRegistry
            .adapter(for: configuration.runtime)
            .readinessReport(configuration: configuration, probes: probes)
    }

    private static func defaultDetectExecutable(_ binary: String) -> String {
        switch binary {
        case "claude":
            return RuntimePathResolver.detectClaudePath()
        case "copilot":
            return RuntimePathResolver.detectCopilotPath()
        default:
            return RuntimePathResolver.detectExecutablePath(named: binary)
        }
    }
}
