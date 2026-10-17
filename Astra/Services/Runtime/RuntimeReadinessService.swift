import Foundation
import ASTRACore

enum RuntimeReadinessState: String, Sendable, Equatable {
    case ready
    case warning
    case blocked

    /// A warning means a probe was inconclusive, so the launch preflight may
    /// still try the provider. Only a confirmed blocker prevents submission.
    var allowsTaskLaunch: Bool { self != .blocked }

    /// The more severe of the two.
    func combined(with other: RuntimeReadinessState) -> RuntimeReadinessState {
        if self == .blocked || other == .blocked { return .blocked }
        if self == .warning || other == .warning { return .warning }
        return .ready
    }
}

enum RuntimeReadinessScope: Sendable, Equatable {
    case availability
    case diagnostic
}

/// A one-click repair the UI can offer next to a blocked check. The service
/// only names the fix; the view that owns the setting performs it.
enum RuntimeReadinessFixAction: Sendable, Equatable {
    case switchAntigravityToADC
}

struct RuntimeReadinessCheck: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let detail: String
    let state: RuntimeReadinessState
    let remediation: String?
    var fixAction: RuntimeReadinessFixAction? = nil
}

struct RuntimeReadinessReport: Sendable, Equatable {
    let checks: [RuntimeReadinessCheck]

    /// The report without its uncached checks: what a readiness cache may
    /// store. `RuntimeReadinessService.refreshingUncachedChecks` re-runs them.
    var cacheable: RuntimeReadinessReport {
        RuntimeReadinessReport(checks: checks.filter { !RuntimeReadinessService.uncachedCheckIDs.contains($0.id) })
    }

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
    var scope: RuntimeReadinessScope
    var providerSettings: AgentRuntimeProviderSettings
    var claudeProvider: ClaudeProvider
    var vertexProjectID: String
    var vertexRegion: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String
    var antigravityAuthMode: AntigravityAuthMode
    /// Billing project for the ADC route; see `AntigravityADCProjectStore`.
    var antigravityADCProject: String

    init(
        runtime: AgentRuntimeID,
        scope: RuntimeReadinessScope = .diagnostic,
        claudePath: String,
        copilotPath: String,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String,
        antigravityAuthMode: AntigravityAuthMode = .consumer,
        antigravityADCProject: String = ""
    ) {
        self.init(
            runtime: runtime,
            scope: scope,
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
            vertexHaikuModel: vertexHaikuModel,
            antigravityAuthMode: antigravityAuthMode,
            antigravityADCProject: antigravityADCProject
        )
    }

    init(
        runtime: AgentRuntimeID,
        scope: RuntimeReadinessScope = .diagnostic,
        providerSettings: AgentRuntimeProviderSettings,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String,
        antigravityAuthMode: AntigravityAuthMode = .consumer,
        antigravityADCProject: String = ""
    ) {
        self.runtime = runtime
        self.scope = scope
        self.providerSettings = providerSettings
        self.claudeProvider = claudeProvider
        self.vertexProjectID = vertexProjectID
        self.vertexRegion = vertexRegion
        self.vertexOpusModel = vertexOpusModel
        self.vertexSonnetModel = vertexSonnetModel
        self.vertexHaikuModel = vertexHaikuModel
        self.antigravityAuthMode = antigravityAuthMode
        self.antigravityADCProject = antigravityADCProject
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
    private let copilotStateHome: String

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        timeout: TimeInterval = 5,
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimeReadinessService.defaultDetectExecutable($0)
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        copilotStateHome: String = CopilotCLIRuntime.defaultHome()
    ) {
        self.runner = runner
        self.timeout = timeout
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
        self.copilotStateHome = copilotStateHome
    }

    func check(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessReport {
        let probes = RuntimeReadinessProbeContext(
            runner: runner,
            timeout: timeout,
            detectExecutable: detectExecutable,
            isExecutable: isExecutable
        )
        let probed = await AgentRuntimeAdapterRegistry
            .descriptorReadiness(for: configuration.runtime)
            .readinessReport(configuration: configuration, probes: probes)
        return RuntimeReadinessReport(checks: probed.checks + uncachedChecks(for: configuration.runtime))
    }

    /// Checks of local state the user can break at any moment, and cheap
    /// enough to re-run every time. Readiness caches store reports without
    /// them (`cacheable`): the composer's cache re-runs them on every answer,
    /// and the launch preflight leaves them to the final-plan guard
    /// (`guardedSandboxedPlan`), which checks every launch. A config that
    /// turns root-owned after a ready probe is caught on the next launch.
    static let uncachedCheckIDs: Set<String> = [CopilotHomeAccessCheck.readinessCheckID]

    func uncachedChecks(for runtime: AgentRuntimeID) -> [RuntimeReadinessCheck] {
        guard runtime == .copilotCLI else { return [] }
        // Copilot exits 1 with no output at all when it cannot read its own
        // config, so this is the only place the cause can surface before a
        // task fails.
        let report = CopilotHomeAccessCheck.inspect(home: copilotStateHome)
        // No task environment exists yet; the launch gate rules on providers.
        return CopilotHomeAccessCheck.readinessCheck(for: report, providersFileBlocks: false).map { [$0] } ?? []
    }

    /// A cached readiness state with the uncached checks re-run now.
    func refreshingUncachedChecks(
        _ state: RuntimeReadinessState,
        runtime: AgentRuntimeID
    ) -> RuntimeReadinessState {
        uncachedChecks(for: runtime).reduce(state) { $0.combined(with: $1.state) }
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
