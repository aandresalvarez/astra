import Foundation
import SwiftData
import ASTRACore

struct AgentRuntimePolicyCapabilities: Equatable, Sendable {
    var supportsOutputFormatJSON: Bool
    var supportsStreamingFlag: Bool
    var supportsNoAskUser: Bool
    var supportsSilent: Bool
    var supportsSecretEnvVars: Bool
    var supportsAllowAll: Bool
    var supportsAllowAllTools: Bool
    var supportsAllowAllPaths: Bool
    var supportsAllowAllURLs: Bool
    var requiresAllowAllToolsForPrompt: Bool

    static let conservative = AgentRuntimePolicyCapabilities(
        supportsOutputFormatJSON: false,
        supportsStreamingFlag: false,
        supportsNoAskUser: false,
        supportsSilent: false,
        supportsSecretEnvVars: false,
        supportsAllowAll: false,
        supportsAllowAllTools: false,
        supportsAllowAllPaths: false,
        supportsAllowAllURLs: false,
        requiresAllowAllToolsForPrompt: true
    )

    init(
        supportsOutputFormatJSON: Bool,
        supportsStreamingFlag: Bool,
        supportsNoAskUser: Bool,
        supportsSilent: Bool,
        supportsSecretEnvVars: Bool,
        supportsAllowAll: Bool,
        supportsAllowAllTools: Bool,
        supportsAllowAllPaths: Bool,
        supportsAllowAllURLs: Bool,
        requiresAllowAllToolsForPrompt: Bool
    ) {
        self.supportsOutputFormatJSON = supportsOutputFormatJSON
        self.supportsStreamingFlag = supportsStreamingFlag
        self.supportsNoAskUser = supportsNoAskUser
        self.supportsSilent = supportsSilent
        self.supportsSecretEnvVars = supportsSecretEnvVars
        self.supportsAllowAll = supportsAllowAll
        self.supportsAllowAllTools = supportsAllowAllTools
        self.supportsAllowAllPaths = supportsAllowAllPaths
        self.supportsAllowAllURLs = supportsAllowAllURLs
        self.requiresAllowAllToolsForPrompt = requiresAllowAllToolsForPrompt
    }

    init(copilotCLI capabilities: CopilotCLICapabilities) {
        self.init(
            supportsOutputFormatJSON: capabilities.supportsOutputFormatJSON,
            supportsStreamingFlag: capabilities.supportsStreamingFlag,
            supportsNoAskUser: capabilities.supportsNoAskUser,
            supportsSilent: capabilities.supportsSilent,
            supportsSecretEnvVars: capabilities.supportsSecretEnvVars,
            supportsAllowAll: capabilities.supportsAllowAll,
            supportsAllowAllTools: capabilities.supportsAllowAllTools,
            supportsAllowAllPaths: capabilities.supportsAllowAllPaths,
            supportsAllowAllURLs: capabilities.supportsAllowAllURLs,
            requiresAllowAllToolsForPrompt: capabilities.requiresAllowAllToolsForPrompt
        )
    }
}

protocol AgentRuntimeDescriptorReadiness {
    var id: AgentRuntimeID { get }
    var descriptor: AgentRuntimeDescriptor { get }
    var readinessCheckID: String { get }
    var availableModelsStorageKey: String { get }
    var modelsCheckedAtStorageKey: String { get }
    var budgetProfile: AgentRuntimeBudgetProfile { get }
    var modelAvailabilityAuthority: RuntimeModelAvailabilityAuthority { get }

    func readinessReport(
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessReport
    func modelAvailabilityCheck(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck
    func installPlan(detectExecutable: @Sendable (String) -> String) -> RuntimeCLIInstallPlan?
}

protocol AgentRuntimePolicyRendering {
    func policyAdapter(runtimeCapabilities: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter
    func providerConfigOwnership(workspacePath: String) -> PolicyConfigOwnership
    func existingProviderConfigSummary(workspacePath: String) -> String?
    func policyCapabilities(executablePath: String) -> AgentRuntimePolicyCapabilities
}

protocol AgentRuntimeProcessLaunchPlanning {
    var id: AgentRuntimeID { get }
    var descriptor: AgentRuntimeDescriptor { get }

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings
    func sharedLaunchStateKey(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeSharedStateKey?
    func missingExecutableAuditReason() -> String
    func missingExecutableStopReason() -> String?
    func missingExecutableMessage(executablePath: String) -> String
    func defaultStartEventPayload(task: AgentTask) -> String
    func connectorPreflightContextText(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage: String?,
        phase: String
    ) -> String
    func shouldCheckWorkspaceDirectory(phase: String) -> Bool
    func shouldPrepareIsolation(phase: String) -> Bool
    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan
}

protocol AgentRuntimeProcessEventParsing {
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent]
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String?
}

protocol AgentRuntimeWorkerEventRecording {
    var recordsStreamTelemetry: Bool { get }
    var recordsInferredFileChanges: Bool { get }
    var recordsEstimatedUsageWhenProviderUsageMissing: Bool { get }

    func parseWorkerStreamEvents(line: String, parsesJSONLines: Bool) -> AgentRuntimeStreamEventBatch
    func processWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        pipeline: AgentRuntimeEventPipelineBox
    ) -> [AgentRuntimeRecordedEvent]
    func flushWorkerStreamEvents(pipeline: AgentRuntimeEventPipelineBox) -> AgentRuntimeStreamEventBatch
    @MainActor
    func recordWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        mode: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    )
    func callbackEvent(from event: AgentRuntimeRecordedEvent) -> ParsedEvent?
}

protocol AgentUtilityRuntimeAdapter {
    func runUtilityPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult
}

protocol AgentRuntimePostRunDiagnostics {
    var id: AgentRuntimeID { get }
    var descriptor: AgentRuntimeDescriptor { get }

    func shouldValidateSuccessfulRun(phase: String) -> Bool
    func requiresVisibleResultForSuccessfulRun(phase: String) -> Bool
    func manualCompletionPayload(phase: String) -> String
    func failurePayloadPrefix(phase: String, exitCode: Int) -> String
    func timeoutPayload(phase: String, timeoutSeconds: TimeInterval) -> String
    func maxTurnsPayload(phase: String, task: AgentTask) -> String
    func shouldClearStaleSessionOnFailure(phase: String, result: AgentProcessResult) -> Bool
    func performsPostRunFollowUps(phase: String) -> Bool
    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage: String?,
        phase: String
    ) -> String
    @MainActor
    func recordPostProcessEvents(context: AgentRuntimePostProcessContext)
    @MainActor
    func logStreamTelemetry(
        snapshot: AgentRuntimeStreamTelemetrySnapshot,
        task: AgentTask,
        run: TaskRun,
        phase: String,
        exitCode: Int
    )
}

protocol AgentRuntimeAdapter: AgentRuntimeDescriptorReadiness,
    AgentRuntimePolicyRendering,
    AgentRuntimeProcessLaunchPlanning,
    AgentRuntimeProcessEventParsing,
    AgentRuntimeWorkerEventRecording,
    AgentUtilityRuntimeAdapter,
    AgentRuntimePostRunDiagnostics {}

extension AgentRuntimeDescriptorReadiness {
    var availableModelsStorageKey: String {
        AppStorageKeys.runtimeAvailableModelsKey(for: id)
    }

    var modelsCheckedAtStorageKey: String {
        AppStorageKeys.runtimeModelsCheckedAtKey(for: id)
    }

    var modelAvailabilityAuthority: RuntimeModelAvailabilityAuthority { .authoritative }

    func installPlan(detectExecutable _: @Sendable (String) -> String) -> RuntimeCLIInstallPlan? {
        nil
    }
}

extension AgentRuntimeProcessLaunchPlanning {
    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty
                ? RuntimePathResolver.detectExecutablePath(named: descriptor.executableName)
                : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func sharedLaunchStateKey(context _: AgentRuntimeProcessLaunchContext) -> AgentRuntimeSharedStateKey? {
        nil
    }

    func missingExecutableAuditReason() -> String {
        "provider_cli_not_found"
    }

    func missingExecutableStopReason() -> String? {
        nil
    }

    func missingExecutableMessage(executablePath: String) -> String {
        "\(id.displayName) CLI not found at '\(executablePath)'. Check Settings."
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        "Agent started working on: \(task.goal)"
    }

    func connectorPreflightContextText(
        task: AgentTask,
        promptOverride _: String?,
        startPayload _: String,
        sessionMessage: String?,
        phase _: String
    ) -> String {
        sessionMessage ?? task.goal
    }

    func shouldCheckWorkspaceDirectory(phase _: String) -> Bool {
        true
    }

    func shouldPrepareIsolation(phase: String) -> Bool {
        phase == "run"
    }
}

extension AgentRuntimePolicyRendering {
    func policyCapabilities(executablePath _: String) -> AgentRuntimePolicyCapabilities {
        .conservative
    }
}

extension AgentRuntimePostRunDiagnostics {
    func shouldValidateSuccessfulRun(phase: String) -> Bool {
        phase == "run"
    }

    func requiresVisibleResultForSuccessfulRun(phase _: String) -> Bool {
        false
    }

    func manualCompletionPayload(phase: String) -> String {
        phase == "resume" ? "Follow-up completed." : "Agent finished."
    }

    func failurePayloadPrefix(phase: String, exitCode: Int) -> String {
        phase == "resume" ? "Follow-up failed (exit \(exitCode))." : "Agent exited with code \(exitCode)."
    }

    func timeoutPayload(phase: String, timeoutSeconds: TimeInterval) -> String {
        let label = phase == "resume" ? "Resume" : "Task"
        return "\(label) idle timeout - no output for \(Int(timeoutSeconds))s. Process killed."
    }

    func maxTurnsPayload(phase: String, task: AgentTask) -> String {
        if phase == "resume" {
            return "Max turns reached (\(task.maxTurns)) during resume. Process killed."
        }
        return "Max turns reached (\(task.maxTurns)). Process killed."
    }

    func shouldClearStaleSessionOnFailure(phase: String, result: AgentProcessResult) -> Bool {
        false
    }

    func performsPostRunFollowUps(phase _: String) -> Bool {
        false
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride _: String?,
        startPayload _: String?,
        sessionMessage: String?,
        phase _: String
    ) -> String {
        sessionMessage ?? task.goal
    }

    @MainActor
    func recordPostProcessEvents(context _: AgentRuntimePostProcessContext) {
    }

    @MainActor
    func logStreamTelemetry(
        snapshot _: AgentRuntimeStreamTelemetrySnapshot,
        task _: AgentTask,
        run _: TaskRun,
        phase _: String,
        exitCode _: Int
    ) {
    }
}

extension AgentRuntimeWorkerEventRecording {
    var recordsStreamTelemetry: Bool { false }

    var recordsInferredFileChanges: Bool { false }

    var recordsEstimatedUsageWhenProviderUsageMissing: Bool { false }
}

extension AgentRuntimeAdapter {
    func detectedExecutable(named binary: String, detectExecutable: @Sendable (String) -> String) -> String? {
        let path = detectExecutable(binary).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

protocol AgentRuntimeAdapterProvider {
    var providerID: String { get }
    var runtimeAdapters: [any AgentRuntimeAdapter] { get }
}

struct StaticAgentRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID: String
    let runtimeAdapters: [any AgentRuntimeAdapter]

    init(providerID: String, runtimeAdapters: [any AgentRuntimeAdapter]) {
        self.providerID = providerID
        self.runtimeAdapters = runtimeAdapters
    }
}

struct AgentRuntimeAdapterRegistrationIssue: Equatable, Sendable {
    let runtimeID: AgentRuntimeID
    let providerID: String
    let message: String
}

struct AgentRuntimeAdapterCatalog {
    let adapters: [any AgentRuntimeAdapter]
    let registrationIssues: [AgentRuntimeAdapterRegistrationIssue]

    init(adapters: [any AgentRuntimeAdapter]) {
        self.init(providers: [
            StaticAgentRuntimeAdapterProvider(
                providerID: "direct",
                runtimeAdapters: adapters
            )
        ])
    }

    init(providers: [any AgentRuntimeAdapterProvider]) {
        var registeredAdapters: [any AgentRuntimeAdapter] = []
        var registeredProviderIDsByRuntime: [AgentRuntimeID: String] = [:]
        var issues: [AgentRuntimeAdapterRegistrationIssue] = []

        for provider in providers {
            for adapter in provider.runtimeAdapters {
                if let existingProviderID = registeredProviderIDsByRuntime[adapter.id] {
                    issues.append(AgentRuntimeAdapterRegistrationIssue(
                        runtimeID: adapter.id,
                        providerID: provider.providerID,
                        message: "Runtime '\(adapter.id.rawValue)' is already registered by provider '\(existingProviderID)'."
                    ))
                    continue
                }

                registeredProviderIDsByRuntime[adapter.id] = provider.providerID
                registeredAdapters.append(adapter)
            }
        }

        self.adapters = registeredAdapters
        self.registrationIssues = issues
    }

    var runtimeIDs: [AgentRuntimeID] {
        adapters.map(\.id)
    }

    var descriptors: [AgentRuntimeDescriptor] {
        adapters.map(\.descriptor)
    }

    func hasAdapter(for runtime: AgentRuntimeID) -> Bool {
        adapterIfRegistered(for: runtime) != nil
    }

    func registeredRuntime(
        rawValue: String?,
        fallback: AgentRuntimeID = TaskExecutionDefaults.runtime
    ) -> AgentRuntimeID {
        if let runtime = rawValue.flatMap(AgentRuntimeID.init(rawValue:)),
           hasAdapter(for: runtime) {
            return runtime
        }
        if hasAdapter(for: fallback) {
            return fallback
        }
        return runtimeIDs.first ?? fallback
    }

    func adapterIfRegistered(for runtime: AgentRuntimeID) -> (any AgentRuntimeAdapter)? {
        adapters.first { $0.id == runtime }
    }

    func descriptor(for runtime: AgentRuntimeID) -> AgentRuntimeDescriptor {
        adapterIfRegistered(for: runtime)?.descriptor ?? fallbackDescriptor(for: runtime)
    }

    func defaultModels(for runtime: AgentRuntimeID) -> [String] {
        descriptor(for: runtime).defaultModels
    }

    func defaultModel(for runtime: AgentRuntimeID) -> String {
        descriptor(for: runtime).defaultModel
    }

    func supportsAstraRunProtocol(for runtime: AgentRuntimeID) -> Bool {
        descriptor(for: runtime).supportsAstraRunProtocol
    }

    func supportsNativeContinuation(for runtime: AgentRuntimeID) -> Bool {
        descriptor(for: runtime).supportsNativeContinuation
    }

    func adapter(for runtime: AgentRuntimeID) -> any AgentRuntimeAdapter {
        guard let adapter = adapterIfRegistered(for: runtime) else {
            preconditionFailure("No AgentRuntimeAdapter registered for runtime '\(runtime.rawValue)'")
        }
        return adapter
    }

    func descriptorReadiness(for runtime: AgentRuntimeID) -> any AgentRuntimeDescriptorReadiness {
        adapter(for: runtime)
    }

    func policyRenderer(for runtime: AgentRuntimeID) -> any AgentRuntimePolicyRendering {
        adapter(for: runtime)
    }

    func processLauncher(for runtime: AgentRuntimeID) -> any AgentRuntimeProcessLaunchPlanning {
        adapter(for: runtime)
    }

    func processEventParser(for runtime: AgentRuntimeID) -> any AgentRuntimeProcessEventParsing {
        adapter(for: runtime)
    }

    func workerEventRecorder(for runtime: AgentRuntimeID) -> any AgentRuntimeWorkerEventRecording {
        adapter(for: runtime)
    }

    func utilityRuntime(for runtime: AgentRuntimeID) -> any AgentUtilityRuntimeAdapter {
        adapter(for: runtime)
    }

    func postRunDiagnostics(for runtime: AgentRuntimeID) -> any AgentRuntimePostRunDiagnostics {
        adapter(for: runtime)
    }

    private func fallbackDescriptor(for runtime: AgentRuntimeID) -> AgentRuntimeDescriptor {
        AgentRuntimeDescriptor(
            id: runtime,
            displayName: runtime.displayName,
            executableName: runtime.rawValue,
            installHint: "",
            authHint: "",
            defaultModel: "default",
            defaultModels: ["default"],
            supportsAstraRunProtocol: false
        )
    }
}

struct ClaudeCodeRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "claude-code"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [ClaudeCodeRuntimeAdapter()]
    }
}

struct CopilotCLIRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "copilot-cli"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [CopilotCLIRuntimeAdapter()]
    }
}

struct AntigravityCLIRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "antigravity-cli"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [AntigravityCLIRuntimeAdapter()]
    }
}

enum BuiltInAgentRuntimeAdapterProviders {
    static var all: [any AgentRuntimeAdapterProvider] {
        [
            ClaudeCodeRuntimeAdapterProvider(),
            CopilotCLIRuntimeAdapterProvider(),
            AntigravityCLIRuntimeAdapterProvider(),
            CodexCLIRuntimeAdapterProvider(),
            CursorCLIRuntimeAdapterProvider(),
            OpenCodeCLIRuntimeAdapterProvider()
        ]
    }
}

enum AgentRuntimeAdapterRegistry {
    private static let liveCatalog = AgentRuntimeAdapterCatalog(providers: BuiltInAgentRuntimeAdapterProviders.all)

    static var runtimeIDs: [AgentRuntimeID] {
        liveCatalog.runtimeIDs
    }

    static var descriptors: [AgentRuntimeDescriptor] {
        liveCatalog.descriptors
    }

    static var allAdapters: [any AgentRuntimeAdapter] {
        liveCatalog.adapters
    }

    static var registrationIssues: [AgentRuntimeAdapterRegistrationIssue] {
        liveCatalog.registrationIssues
    }

    static func hasAdapter(for runtime: AgentRuntimeID) -> Bool {
        liveCatalog.hasAdapter(for: runtime)
    }

    static func registeredRuntime(
        rawValue: String?,
        fallback: AgentRuntimeID = TaskExecutionDefaults.runtime
    ) -> AgentRuntimeID {
        liveCatalog.registeredRuntime(rawValue: rawValue, fallback: fallback)
    }

    static func adapterIfRegistered(for runtime: AgentRuntimeID) -> (any AgentRuntimeAdapter)? {
        liveCatalog.adapterIfRegistered(for: runtime)
    }

    static func descriptor(for runtime: AgentRuntimeID) -> AgentRuntimeDescriptor {
        liveCatalog.descriptor(for: runtime)
    }

    static func defaultModels(for runtime: AgentRuntimeID) -> [String] {
        liveCatalog.defaultModels(for: runtime)
    }

    static func defaultModel(for runtime: AgentRuntimeID) -> String {
        liveCatalog.defaultModel(for: runtime)
    }

    static func supportsAstraRunProtocol(for runtime: AgentRuntimeID) -> Bool {
        liveCatalog.supportsAstraRunProtocol(for: runtime)
    }

    static func supportsNativeContinuation(for runtime: AgentRuntimeID) -> Bool {
        liveCatalog.supportsNativeContinuation(for: runtime)
    }

    static func adapter(for runtime: AgentRuntimeID) -> any AgentRuntimeAdapter {
        liveCatalog.adapter(for: runtime)
    }

    static func descriptorReadiness(for runtime: AgentRuntimeID) -> any AgentRuntimeDescriptorReadiness {
        liveCatalog.descriptorReadiness(for: runtime)
    }

    static func policyRenderer(for runtime: AgentRuntimeID) -> any AgentRuntimePolicyRendering {
        liveCatalog.policyRenderer(for: runtime)
    }

    static func processLauncher(for runtime: AgentRuntimeID) -> any AgentRuntimeProcessLaunchPlanning {
        liveCatalog.processLauncher(for: runtime)
    }

    static func processEventParser(for runtime: AgentRuntimeID) -> any AgentRuntimeProcessEventParsing {
        liveCatalog.processEventParser(for: runtime)
    }

    static func workerEventRecorder(for runtime: AgentRuntimeID) -> any AgentRuntimeWorkerEventRecording {
        liveCatalog.workerEventRecorder(for: runtime)
    }

    static func utilityRuntime(for runtime: AgentRuntimeID) -> any AgentUtilityRuntimeAdapter {
        liveCatalog.utilityRuntime(for: runtime)
    }

    static func postRunDiagnostics(for runtime: AgentRuntimeID) -> any AgentRuntimePostRunDiagnostics {
        liveCatalog.postRunDiagnostics(for: runtime)
    }
}

struct RuntimeExecutableCheckResult {
    let executable: String?
    let check: RuntimeReadinessCheck

    var isReady: Bool { executable != nil && check.state == .ready }
}

struct AgentRuntimeProcessLaunchContext {
    let prompt: String
    let task: AgentTask
    let workspacePath: String
    let executablePath: String
    let providerHomeDirectory: String
    let permissionPolicy: PermissionPolicy
    let executionPolicy: AgentRuntimeExecutionPolicy
    let permissionManifest: RunPermissionManifest?
    let timeoutSeconds: TimeInterval
    let phase: String
    let contextText: String
    let nativeContinuationSessionID: String?
    let runID: UUID?
    let liveApprovalsEnabled: Bool

    init(
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        providerHomeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        timeoutSeconds: TimeInterval,
        phase: String = "run",
        contextText: String = "",
        nativeContinuationSessionID: String? = nil,
        runID: UUID? = nil,
        liveApprovalsEnabled: Bool = false
    ) {
        self.prompt = prompt
        self.task = task
        self.workspacePath = workspacePath
        self.executablePath = executablePath
        self.providerHomeDirectory = providerHomeDirectory
        self.permissionPolicy = permissionPolicy
        self.executionPolicy = executionPolicy
        self.permissionManifest = permissionManifest
        self.timeoutSeconds = timeoutSeconds
        self.phase = phase
        self.contextText = contextText
        self.nativeContinuationSessionID = nativeContinuationSessionID
        self.runID = runID
        self.liveApprovalsEnabled = liveApprovalsEnabled
    }
}

struct AgentRuntimeLaunchSettings {
    let executablePath: String
    let homeDirectory: String
}

struct AgentRuntimePostProcessContext {
    let homeDirectory: String
    let task: AgentTask
    let run: TaskRun
    let runStartedAt: Date
    let modelContext: ModelContext
    let recordingState: AgentEventRecordingState
    let onEvent: (ParsedEvent) -> Void
}
struct AgentRuntimeProcessLaunchPlan: Equatable {
    let runtime: AgentRuntimeID
    let executablePath: String
    let arguments: [String]
    let currentDirectory: String
    let environment: [String: String]
    let browserShimDirectory: String?
    let providerVersion: String?
    let parsesJSONLines: Bool
    let directoriesToCreate: [String]
    let sandboxReadablePaths: [String]
    /// Files carved back out of a writable root as read-only (write-deny over
    /// write-allow). See `CopilotCLIRuntime.configWriteDenyPaths`.
    let sandboxProtectedWriteDenyPaths: [String]
    let providerDetectedFields: [String: String]
    let commandPlannedFields: [String: String]
    var interactiveAsk: AgentRuntimeInteractiveAskPlan?
    var pathMapper: ExecutionEnvironmentPathMapper?
    var executionEnvironment: WorkspaceExecutionEnvironment

    init(
        runtime: AgentRuntimeID,
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        browserShimDirectory: String?,
        providerVersion: String?,
        parsesJSONLines: Bool,
        directoriesToCreate: [String] = [],
        sandboxReadablePaths: [String] = [],
        sandboxProtectedWriteDenyPaths: [String] = [],
        providerDetectedFields: [String: String] = [:],
        commandPlannedFields: [String: String] = [:],
        interactiveAsk: AgentRuntimeInteractiveAskPlan? = nil,
        pathMapper: ExecutionEnvironmentPathMapper? = nil,
        executionEnvironment: WorkspaceExecutionEnvironment = .host
    ) {
        self.runtime = runtime
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.browserShimDirectory = browserShimDirectory
        self.providerVersion = providerVersion
        self.parsesJSONLines = parsesJSONLines
        self.directoriesToCreate = directoriesToCreate
        self.sandboxReadablePaths = sandboxReadablePaths
        self.sandboxProtectedWriteDenyPaths = sandboxProtectedWriteDenyPaths
        self.providerDetectedFields = providerDetectedFields
        self.commandPlannedFields = commandPlannedFields
        self.interactiveAsk = interactiveAsk
        self.pathMapper = pathMapper
        self.executionEnvironment = executionEnvironment
    }

    func addingGitCredentialContext(_ context: GitCredentialSandboxContext) -> AgentRuntimeProcessLaunchPlan {
        guard !context.isEmpty else { return self }
        var readable = sandboxReadablePaths
        readable.append(contentsOf: context.readablePaths)
        readable = Self.uniqueNonEmpty(readable)

        var plannedFields = commandPlannedFields
        plannedFields["git_credential_context"] = "true"
        plannedFields["git_credential_readable_path_count"] = String(context.readablePaths.count)
        plannedFields["git_credential_writable_path_count"] = String(context.writablePaths.count)
        plannedFields["git_credential_transports"] = context.transports.map(\.rawValue).joined(separator: ",")
        if !context.diagnostics.isEmpty {
            plannedFields["git_credential_diagnostics"] = context.diagnostics.joined(separator: ",")
        }

        return AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: parsesJSONLines,
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: readable,
            sandboxProtectedWriteDenyPaths: sandboxProtectedWriteDenyPaths,
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: plannedFields,
            interactiveAsk: interactiveAsk
        )
    }

    func enablingProviderNativeGitCredentialReads(
        for context: GitCredentialSandboxContext,
        permissionPolicy: PermissionPolicy
    ) -> AgentRuntimeProcessLaunchPlan {
        guard context.needsExternalCredentialAccess,
              permissionPolicy != .autonomous else {
            return self
        }

        var updatedArguments = arguments
        var plannedFields = commandPlannedFields
        switch runtime {
        case .codexCLI:
            let config = "sandbox_permissions=[\"disk-full-read-access\"]"
            guard !updatedArguments.contains(config) else { return self }
            let insertIndex = updatedArguments.firstIndex(of: "--skip-git-repo-check")
                ?? max(0, updatedArguments.count - 1)
            updatedArguments.insert(contentsOf: ["--config", config], at: insertIndex)
            plannedFields["git_provider_native_read_access"] = "codex_disk_full_read"
        case .copilotCLI:
            guard commandPlannedFields["supports_allow_all_paths"] == "true",
                  !updatedArguments.contains("--allow-all-paths") else {
                return self
            }
            updatedArguments.append("--allow-all-paths")
            plannedFields["git_provider_native_read_access"] = "copilot_allow_all_paths"
        default:
            return self
        }

        return AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: updatedArguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: parsesJSONLines,
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: sandboxReadablePaths,
            sandboxProtectedWriteDenyPaths: sandboxProtectedWriteDenyPaths,
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: plannedFields,
            interactiveAsk: interactiveAsk
        )
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }
}

enum AgentRuntimeRecordingMode {
    case initial
    case followUp
}

enum AgentRuntimeRecordedEvent {
    case parsed(ParsedEvent)
    case agent(AgentEvent)

    var parsedEvent: ParsedEvent? {
        if case .parsed(let event) = self {
            return event
        }
        return nil
    }

    var agentEvent: AgentEvent? {
        if case .agent(let event) = self {
            return event
        }
        return nil
    }
}

enum AgentRuntimeStreamEventRepresentation {
    case parsed
    case agent
}

struct AgentRuntimeStreamEventBatch {
    let representation: AgentRuntimeStreamEventRepresentation
    let events: [AgentRuntimeRecordedEvent]

    init(representation: AgentRuntimeStreamEventRepresentation, events: [AgentRuntimeRecordedEvent]) {
        self.representation = representation
        self.events = events
    }

    init(parsedEvents: [ParsedEvent]) {
        representation = .parsed
        events = parsedEvents.map(AgentRuntimeRecordedEvent.parsed)
    }

    init(agentEvents: [AgentEvent]) {
        representation = .agent
        events = agentEvents.map(AgentRuntimeRecordedEvent.agent)
    }

    var parsedEvents: [ParsedEvent] {
        events.compactMap(\.parsedEvent)
    }

    var agentEvents: [AgentEvent] {
        events.compactMap(\.agentEvent)
    }

    func recordParsed(to capture: AgentRuntimeStreamDebugCapture?, rawLine: String) {
        switch representation {
        case .parsed:
            capture?.recordParsed(parsedEvents, rawLine: rawLine)
        case .agent:
            capture?.recordParsed(agentEvents, rawLine: rawLine)
        }
    }

    func recordEmitted(to capture: AgentRuntimeStreamDebugCapture?) {
        switch representation {
        case .parsed:
            capture?.recordEmitted(parsedEvents)
        case .agent:
            capture?.recordEmitted(agentEvents)
        }
    }

    func recordParsed(to telemetry: AgentRuntimeStreamTelemetry?) {
        telemetry?.recordParsed(agentEvents)
    }

    func recordEmitted(to telemetry: AgentRuntimeStreamTelemetry?) {
        telemetry?.recordEmitted(agentEvents)
    }
}

struct RuntimeReadinessProbeContext {
    let runner: any BinaryRunner
    let timeout: TimeInterval
    let detectExecutable: @Sendable (String) -> String
    let isExecutable: @Sendable (String) -> Bool
    let processEnvironment: [String: String]

    init(
        runner: any BinaryRunner,
        timeout: TimeInterval,
        detectExecutable: @Sendable @escaping (String) -> String,
        isExecutable: @Sendable @escaping (String) -> Bool
    ) {
        self.runner = runner
        self.timeout = timeout
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
        self.processEnvironment = RuntimeProcessEnvironment.enriched()
    }

    func run(
        path: String,
        args: [String],
        timeout overrideTimeout: TimeInterval? = nil,
        environment: [String: String]? = nil
    ) async -> RunResult {
        await runner.run(path: path, args: args, timeout: overrideTimeout ?? timeout, environment: environment ?? processEnvironment)
    }

    func checkExecutable(
        id: String,
        title: String,
        executable: String?,
        args: [String],
        missingDetail: String,
        installHint: String
    ) async -> RuntimeExecutableCheckResult {
        guard let executable, !executable.isEmpty, isExecutable(executable) else {
            return RuntimeExecutableCheckResult(
                executable: nil,
                check: RuntimeReadinessCheck(
                    id: id,
                    title: title,
                    detail: missingDetail,
                    state: .blocked,
                    remediation: installHint
                )
            )
        }

        let result = await runner.run(path: executable, args: args, timeout: timeout, environment: processEnvironment)
        guard result.isSuccess else {
            return RuntimeExecutableCheckResult(
                executable: executable,
                check: RuntimeReadinessCheck(
                    id: id,
                    title: title,
                    detail: processFailureDetail(result),
                    state: .blocked,
                    remediation: "Verify the configured path: \(executable)"
                )
            )
        }

        return RuntimeExecutableCheckResult(
            executable: executable,
            check: RuntimeReadinessCheck(
                id: id,
                title: title,
                detail: versionSummary(result.stdout, fallback: "Available at \(executable)"),
                state: .ready,
                remediation: nil
            )
        )
    }

    func resolvedExecutable(configuredPath: String, binary: String) -> String? {
        let configured = trimmed(configuredPath)
        if !configured.isEmpty { return configured }
        let detected = detectExecutable(binary)
        return detected.isEmpty ? nil : detected
    }

    private func processFailureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .launchFailed(let reason):
            return "Could not launch: \(RuntimeReadinessRedactor.redacted(reason))"
        case .timedOut:
            return "Timed out after \(Int(timeout))s."
        case .cancelled:
            return "Cancelled."
        case .exited(let code):
            let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
            let trimmed = RuntimeReadinessRedactor.redacted(evidence)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Exited with status \(code)."
            }
            return "Exited with status \(code): \(String(trimmed.prefix(140)))"
        }
    }

    private func versionSummary(_ stdout: String, fallback: String) -> String {
        let firstLine = stdout
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return fallback }
        return RuntimeReadinessRedactor.redacted(firstLine)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RuntimeReadinessRedactor {
    static func redacted(_ value: String) -> String {
        var output = value
        output = output.replacingPattern(
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[redacted-email]",
            options: [.caseInsensitive]
        )
        output = output.replacingPattern(
            #"ya29\.[A-Za-z0-9._-]+"#,
            with: "[redacted-token]"
        )
        output = output.replacingPattern(
            #"sk-[A-Za-z0-9_-]+"#,
            with: "[redacted-key]"
        )
        return output
    }
}

enum RuntimeReadinessDiagnostics {
    static func detail(from result: RunResult, fallback: String) -> String {
        let diagnostic = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !diagnostic.isEmpty else { return fallback }
        return RuntimeReadinessRedactor.redacted(diagnostic)
    }

    static func showsAuthenticatedSession(_ output: String) -> Bool {
        let lower = output.lowercased()
        let compact = lower.filter { !$0.isWhitespace }
        let negativeSignals = [
            "\"loggedin\":false",
            "\"authenticated\":false",
            "not logged in",
            "not authenticated",
            "not signed in",
            "unauthenticated",
            "logged out",
            "login required",
            "authentication required",
            "no authenticated"
        ]
        if negativeSignals.contains(where: { lower.contains($0) || compact.contains($0) }) {
            return false
        }
        return compact.contains("\"loggedin\":true")
            || compact.contains("\"authenticated\":true")
            || lower.contains("logged in")
            || lower.contains("authenticated")
    }
}

struct ClaudeCodeRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        executableName: "claude",
        installHint: "Install via npm: `npm install -g @anthropic-ai/claude-code`",
        authHint: "Run `claude /login` or set `ANTHROPIC_API_KEY`.",
        prerequisite: CommonCLIPrerequisites.claude,
        defaultModel: "claude-sonnet-4-6",
        // Pre-probe fallback only; the CLI initialize handshake replaces
        // this list at app launch. Aliases track the CLI's current models
        // instead of rotting like pinned IDs; the pinned default stays for
        // no-cache resolution and cross-runtime bleed detection.
        defaultModels: [
            "default",
            "sonnet",
            "haiku",
            "claude-sonnet-4-6"
        ],
        supportsAstraRunProtocol: true,
        supportsNativeContinuation: true,
        supportsMCPServers: true
    )
    let readinessCheckID = "claude-cli"
    let availableModelsStorageKey = AppStorageKeys.claudeAvailableModels
    let modelsCheckedAtStorageKey = AppStorageKeys.claudeModelsCheckedAt
    // Claude Code includes runtime context in billed input, so low budgets need the launch overhead.
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .claudeCode, launchOverheadTokens: 120_000)

    func shouldCheckWorkspaceDirectory(phase: String) -> Bool {
        phase == "run"
    }

    func shouldClearStaleSessionOnFailure(phase: String, result: AgentProcessResult) -> Bool {
        guard phase == "resume" else { return false }
        return result.error?.contains("session") == true || result.error?.contains("not found") == true
    }

    func performsPostRunFollowUps(phase: String) -> Bool {
        phase == "run"
    }

    func policyAdapter(runtimeCapabilities _: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter {
        ClaudePolicyAdapter()
    }

    func providerConfigOwnership(workspacePath: String) -> PolicyConfigOwnership {
        ClaudeSettingsStore.configOwnership(at: workspacePath)
    }

    func existingProviderConfigSummary(workspacePath: String) -> String? {
        ClaudeSettingsStore.existingConfigSummary(at: workspacePath)
    }

    func readinessReport(
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessReport {
        var checks: [RuntimeReadinessCheck] = []
        let prerequisite = descriptor.prerequisite
        let executable = probes.resolvedExecutable(
            configuredPath: configuration.executablePath(for: id),
            binary: prerequisite.binary
        )

        let cliStatus = await probes.checkExecutable(
            id: readinessCheckID,
            title: prerequisite.displayName,
            executable: executable,
            args: prerequisite.livenessArgs,
            missingDetail: "\(prerequisite.displayName) was not found.",
            installHint: prerequisite.installHint
        )
        checks.append(cliStatus.check)

        if cliStatus.isReady, let executable = cliStatus.executable {
            checks.append(await checkClaudeAuth(executable: executable, configuration: configuration, probes: probes))
        }

        switch configuration.claudeProvider {
        case .anthropic:
            checks.append(RuntimeReadinessCheck(
                id: "provider-route",
                title: "Provider route",
                detail: "Anthropic route selected.",
                state: .ready,
                remediation: nil
            ))
        case .vertex:
            checks.append(contentsOf: vertexConfigurationChecks(configuration))
            let gcloud = await probes.checkExecutable(
                id: "gcloud-cli",
                title: "Google Cloud CLI",
                executable: probes.resolvedExecutable(configuredPath: "", binary: "gcloud"),
                args: ["--version"],
                missingDetail: "gcloud was not found on PATH.",
                installHint: CommonCLIPrerequisites.gcloud.installHint
            )
            checks.append(gcloud.check)
            if gcloud.isReady, let executable = gcloud.executable {
                checks.append(await checkVertexADC(gcloudPath: executable, probes: probes))
            }
        }

        return RuntimeReadinessReport(checks: checks)
    }

    func modelAvailabilityCheck(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let result = await ClaudeModelAvailabilityService().refreshAndPersist(
            configuration: ClaudeModelAvailabilityConfiguration(
                provider: configuration.claudeProvider,
                executablePath: configuration.executablePath(for: id),
                vertexOpusModel: configuration.vertexOpusModel,
                vertexSonnetModel: configuration.vertexSonnetModel,
                vertexHaikuModel: configuration.vertexHaikuModel
            )
        )
        switch result {
        case .available(let models):
            return RuntimeReadinessCheck(
                id: "claude-models",
                title: "Claude models",
                detail: "Available: \(models.map(\.value).joined(separator: ", "))",
                state: .ready,
                remediation: nil
            )
        case .unavailable(let reason):
            return RuntimeReadinessCheck(
                id: "claude-models",
                title: "Claude models",
                detail: "Using cached or default model choices until provider model access can be verified.",
                state: .warning,
                remediation: reason
            )
        }
    }

    func installPlan(detectExecutable: @Sendable (String) -> String) -> RuntimeCLIInstallPlan? {
        guard let npm = detectedExecutable(named: "npm", detectExecutable: detectExecutable) else {
            return nil
        }
        return RuntimeCLIInstallPlan(
            runtime: id,
            installerName: "npm",
            executablePath: npm,
            arguments: ["install", "-g", "@anthropic-ai/claude-code"],
            displayCommand: "npm install -g @anthropic-ai/claude-code"
        )
    }

    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: context.task,
            contextText: context.contextText
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let capabilityScope = TaskCapabilityResolver(task: context.task).promptScope(contextText: context.contextText)
        let allowed = context.executionPolicy.allowedTools(
            default: capabilityScope.resolver.resolvedProviderAllowedTools
        )
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let usesDockerWorkspaceExecutor = DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)
        let baseProviderAllowed = AgentRuntimeProcessRunner.providerAllowedTools(
            for: id,
            baseAllowedTools: allowed,
            permissionManifest: context.permissionManifest
        )
        let providerAllowed = usesDockerWorkspaceExecutor
            ? DockerWorkspaceMCPProjection.removingNativeShellTools(baseProviderAllowed)
            : baseProviderAllowed
        let runtimeSupportTools = AgentRuntimeProcessRunner.providerRuntimeSupportToolPermissions(
            for: id,
            permissionManifest: context.permissionManifest
        )
        let baseAskFirstToolPermissions = AgentRuntimeProcessRunner.providerAskFirstToolPermissions(
            for: id,
            permissionManifest: context.permissionManifest
        )
        let askFirstToolPermissions = usesDockerWorkspaceExecutor
            ? DockerWorkspaceMCPProjection.removingNativeShellTools(baseAskFirstToolPermissions)
            : baseAskFirstToolPermissions
        let artifactBootstrapTools = ProviderArtifactBootstrapPolicy.launchTools(
            task: context.task,
            permissionPolicy: effectivePermissionPolicy,
            providerAllowedTools: providerAllowed,
            askFirstTools: askFirstToolPermissions
        )
        // Capability-package MCP servers: render the per-launch config and
        // grant the projected tool names. Secrets stay out of the file via
        // ${KEY} env indirection (the CLI expands from the task environment).
        var mcpServers = MCPRuntimeProjection.enabledServers(
            for: context.task.workspace,
            packages: CapabilityRuntimeResourceMatcher.packageDefinitions(),
            approvalRecords: CapabilityApprovalStore().records()
        )
        if let workspaceServer = DockerWorkspaceMCPProjection.resolvedServer(
            task: context.task,
            environment: executionEnvironment,
            currentDirectory: context.workspacePath,
            runID: context.runID
        ) {
            mcpServers.append(workspaceServer)
        }
        // allowEmpty: strict mode must apply even with zero governed servers,
        // or a repository's own .mcp.json loads ungoverned on those runs.
        let mcpConfigURL = MCPRuntimeProjection.writeClaudeConfig(servers: mcpServers, taskID: context.task.id, allowEmpty: true)
        let mcpConfigReadablePaths = mcpConfigURL.map { [$0.deletingLastPathComponent().path] } ?? []
        let sandboxReadablePaths = mcpConfigReadablePaths + ClaudeCodeRuntime.authReadablePaths()
        let mcpAllowedTools = mcpConfigURL == nil ? [] : MCPRuntimeProjection.allowedToolPermissions(servers: mcpServers)
        let mcpDeniedTools = mcpConfigURL == nil ? [] : MCPRuntimeProjection.deniedToolPermissions(servers: mcpServers)
        let nativeDeniedTools = Array(Set(mcpDeniedTools + (usesDockerWorkspaceExecutor ? ["Bash"] : []))).sorted()
        // Live approvals use the stdio control protocol (stream-json input, so
        // the prompt travels over stdin). Resolved before the allow-list so it
        // can decide whether ask-first tools are gated at the provider prompt.
        let interactiveAsk: AgentRuntimeInteractiveAskPlan? = {
            guard context.liveApprovalsEnabled,
                  effectivePermissionPolicy != .autonomous,
                  let initialMessage = ClaudeControlProtocol.initialUserMessage(prompt: context.prompt) else {
                return nil
            }
            return AgentRuntimeInteractiveAskPlan(initialStdinMessage: initialMessage)
        }()
        // Withhold ask-first tools from the pre-allow set (launch --allowedTools
        // and settings.local.json) when the live channel will gate them at the
        // provider's permission prompt. Otherwise the provider never asks, the
        // tool runs ungated, and only a post-hoc kill remains. They stay visible
        // (re-added below) so the model can still invoke them and be prompted.
        let nativeAllowedTools = Array(Set(
            providerAllowed + runtimeSupportTools + artifactBootstrapTools + mcpAllowedTools
                + (interactiveAsk == nil ? askFirstToolPermissions : [])
        )).sorted()
        let usesArtifactBootstrapProfile = !artifactBootstrapTools.isEmpty
        let visibleToolSource = usesArtifactBootstrapProfile
            ? Array(Set(providerAllowed + runtimeSupportTools + artifactBootstrapTools + askFirstToolPermissions + mcpAllowedTools)).sorted()
            : Array(Set(nativeAllowedTools + askFirstToolPermissions)).sorted()
        let visibleTools = ClaudeVisibleToolProjection.visibleProviderTools(
            from: visibleToolSource,
            task: context.task,
            permissionPolicy: effectivePermissionPolicy
        )
        let workspaceExecutorEnvironment = DockerWorkspaceMCPProjection.environmentVariables(
            task: context.task,
            environment: executionEnvironment,
            currentDirectory: context.workspacePath,
            runID: context.runID
        )
        var processEnvironment = AgentRuntimeProcessRunner.environment(
            phase: context.phase,
            task: context.task,
            taskEnv: taskEnv,
            includeClaudeTeamFlag: true
        )
        for (key, value) in workspaceExecutorEnvironment {
            processEnvironment[key] = value
        }
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        var args = interactiveAsk == nil ? ["-p", context.prompt] : ["-p"]
        if let sessionID = context.nativeContinuationSessionID,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--resume", sessionID]
        }
        if interactiveAsk != nil {
            args += ["--input-format", "stream-json", "--permission-prompt-tool", "stdio"]
        }
        args += [
            "--model",
            AgentRuntimeProcessRunner.translatedModelForProvider(model),
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]
        if usesArtifactBootstrapProfile {
            args += ["--effort", "low"]
        }
        args += effectivePermissionPolicy.cliArguments
        AgentRuntimeProcessRunner.ensureSubAgentPermissions(
            at: context.workspacePath,
            policy: effectivePermissionPolicy,
            allowedTools: nativeAllowedTools
        )
        if context.task.maxTurns > 0 {
            args += ["--max-turns", String(context.task.maxTurns)]
        }
        if !visibleTools.isEmpty {
            args += ["--tools", visibleTools.joined(separator: ",")]
        }
        if !nativeAllowedTools.isEmpty {
            args += ["--allowedTools"] + nativeAllowedTools
        }
        // Unconditional (not gated on a successful config write): strict mode
        // blocks the repo's .mcp.json, so a failed render means no servers, not bypass.
        args += ["--strict-mcp-config"]
        if let mcpConfigURL {
            args += ["--mcp-config", mcpConfigURL.path]
        }
        if !nativeDeniedTools.isEmpty {
            args += ["--disallowedTools"] + nativeDeniedTools
        }
        return AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: context.executablePath,
            arguments: args,
            currentDirectory: context.workspacePath,
            environment: processEnvironment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: nil,
            parsesJSONLines: true,
            directoriesToCreate: [],
            sandboxReadablePaths: sandboxReadablePaths,
            providerDetectedFields: [
                "runtime": id.rawValue,
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: context.executablePath)),
                "executable_path": context.executablePath,
                "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(context.executablePath)
            ],
            commandPlannedFields: [
                "runtime": id.rawValue,
                "phase": context.phase,
                "model": model,
                "provider_model": AgentRuntimeProcessRunner.translatedModelForProvider(model),
                "permission_policy": effectivePermissionPolicy.rawValue,
                "artifact_bootstrap_profile": String(usesArtifactBootstrapProfile),
                "launch_effort": usesArtifactBootstrapProfile ? "low" : "default",
                "allowed_tools_count": String(providerAllowed.count),
                "base_allowed_tools_count": String(baseProviderAllowed.count),
                "docker_workspace_executor": String(usesDockerWorkspaceExecutor),
                "docker_workspace_tool": usesDockerWorkspaceExecutor ? DockerWorkspaceMCPProjection.providerToolPermission : "none",
                "docker_workspace_mcp_env_key_count": String(workspaceExecutorEnvironment.count),
                "docker_workspace_container_env_key_count": String(
                    DockerExecutionPlanner.credentialProjectionEnvironment(environment: executionEnvironment).count
                ),
                "docker_workspace_credential_projection_count": String(executionEnvironment.effectiveCredentialProjections.count),
                "native_shell_removed_for_workspace_executor": String(usesDockerWorkspaceExecutor),
                "provider_launch_allowed_tool_count": String(nativeAllowedTools.count),
                "runtime_support_tool_count": String(runtimeSupportTools.count),
                "runtime_support_tool_names": runtimeSupportTools.joined(separator: ","),
                "ask_first_tool_count": String(askFirstToolPermissions.count),
                "ask_first_tool_names": askFirstToolPermissions.joined(separator: ","),
                "artifact_bootstrap_tool_count": String(artifactBootstrapTools.count),
                "artifact_bootstrap_tool_names": artifactBootstrapTools.joined(separator: ","),
                "visible_tools_count": String(visibleTools.count),
                "visible_tool_names": visibleTools.joined(separator: ","),
                "uses_visible_tools_filter": String(!visibleTools.isEmpty),
                "allowed_tools_override": String(context.executionPolicy.allowedToolsOverride != nil),
                "task_env_count": String(taskEnv.count),
                "max_turns": String(context.task.maxTurns),
                "supports_native_continuation": String(descriptor.supportsNativeContinuation),
                "uses_native_continuation": String(context.nativeContinuationSessionID != nil),
                "native_session_prefix": context.nativeContinuationSessionID.map { String($0.prefix(8)) } ?? "none",
                "uses_live_approvals": String(interactiveAsk != nil),
                "mcp_server_count": String(mcpConfigURL == nil ? 0 : mcpServers.count),
                "mcp_config_rendered": String(mcpConfigURL != nil),
                "native_denied_tool_count": String(nativeDeniedTools.count),
                "native_denied_tool_names": nativeDeniedTools.joined(separator: ",")
            ],
            interactiveAsk: interactiveAsk
        )
    }

    func parseProcessEvents(line: String, parsesJSONLines _: Bool) -> [ParsedEvent] {
        StreamEventParser.parseAll(line: line)
    }

    func blockingProcessPermissionMessage(line _: String, parsesJSONLines _: Bool) -> String? {
        nil
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines _: Bool) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(parsedEvents: StreamEventParser.parseAll(line: line))
    }

    func processWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        pipeline: AgentRuntimeEventPipelineBox
    ) -> [AgentRuntimeRecordedEvent] {
        guard case .parsed(let parsed) = event else { return [] }
        return pipeline.process(parsed).map(AgentRuntimeRecordedEvent.parsed)
    }

    func flushWorkerStreamEvents(pipeline: AgentRuntimeEventPipelineBox) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(parsedEvents: pipeline.flushParsedEvents())
    }

    @MainActor
    func recordWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        mode: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        guard case .parsed(let parsed) = event else { return }
        switch mode {
        case .initial:
            AgentEventRecorder.recordClaudeRunEvent(
                parsed,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .followUp:
            AgentEventRecorder.recordClaudeFollowUpEvent(
                parsed,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        }
    }

    func callbackEvent(from event: AgentRuntimeRecordedEvent) -> ParsedEvent? {
        event.parsedEvent
    }

    func runUtilityPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty
            ? RuntimePathResolver.detectClaudePath()
            : configuredPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var args = [
            "-p",
            prompt,
            "--model",
            AgentRuntimeProcessRunner.translatedModelForProvider(configuration.model)
        ]
        if toolMode == .readOnly {
            args += [
                "--allowedTools",
                "Read,Glob,Grep",
                "--disallowedTools",
                "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"
            ]
        }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        process.environment = claudeUtilityEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Non-interactive helper: hand the CLI an empty stdin so it never blocks
        // waiting for input it will never receive (provider-agnostic safeguard).
        process.standardInput = FileHandle.nullDevice
        let result = await AsyncProcessRunner.run(
            process,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            timeoutSeconds: configuration.timeoutSeconds
        )
        return AgentUtilityRunResult(exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }

    private func checkClaudeAuth(
        executable: String,
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let result = await probes.run(
            path: executable,
            args: ["auth", "status"],
            environment: claudeProviderEnvironment(for: configuration)
        )

        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "claude-auth",
                title: "Claude authentication",
                detail: RuntimeReadinessDiagnostics.detail(
                    from: result,
                    fallback: "Claude auth status did not pass."
                ),
                state: .blocked,
                remediation: configuration.claudeProvider == .vertex
                    ? "Check Vertex project, region, ADC credentials, and model aliases."
                    : CommonCLIPrerequisites.claude.authHint
            )
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        if RuntimeReadinessDiagnostics.showsAuthenticatedSession(output) {
            return RuntimeReadinessCheck(
                id: "claude-auth",
                title: "Claude authentication",
                detail: "Claude reports an authenticated session.",
                state: .ready,
                remediation: nil
            )
        }

        return RuntimeReadinessCheck(
            id: "claude-auth",
            title: "Claude authentication",
            detail: RuntimeReadinessDiagnostics.detail(
                from: result,
                fallback: "Claude responded, but no authenticated session was detected."
            ),
            state: .blocked,
            remediation: configuration.claudeProvider == .vertex
                ? "Run `gcloud auth application-default login` and re-check."
                : CommonCLIPrerequisites.claude.authHint
        )
    }

    private func checkVertexADC(
        gcloudPath: String,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let result = await probes.run(
            path: gcloudPath,
            args: ["auth", "application-default", "print-access-token", "--quiet"]
        )

        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "vertex-adc",
                title: "Vertex ADC credentials",
                detail: "Application Default Credentials are not available.",
                state: .blocked,
                remediation: "Run `gcloud auth application-default login`."
            )
        }

        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RuntimeReadinessCheck(
                id: "vertex-adc",
                title: "Vertex ADC credentials",
                detail: "ADC command succeeded but returned no token.",
                state: .blocked,
                remediation: "Run `gcloud auth application-default login`."
            )
        }

        return RuntimeReadinessCheck(
            id: "vertex-adc",
            title: "Vertex ADC credentials",
            detail: "Application Default Credentials are available.",
            state: .ready,
            remediation: nil
        )
    }

    private func vertexConfigurationChecks(_ configuration: RuntimeReadinessConfiguration) -> [RuntimeReadinessCheck] {
        var checks: [RuntimeReadinessCheck] = []
        let project = trimmed(configuration.vertexProjectID)
        let region = trimmed(configuration.vertexRegion)
        let opus = trimmed(configuration.vertexOpusModel)
        let sonnet = trimmed(configuration.vertexSonnetModel)
        let haiku = trimmed(configuration.vertexHaikuModel)

        checks.append(RuntimeReadinessCheck(
            id: "vertex-project-region",
            title: "Vertex project and region",
            detail: project.isEmpty || region.isEmpty
                ? "Project ID and region are required for Vertex routing."
                : "Using project \(project) in \(region).",
            state: project.isEmpty || region.isEmpty ? .blocked : .ready,
            remediation: project.isEmpty || region.isEmpty ? "Fill GCP Project ID and Region." : nil
        ))

        let missingAliases = [
            ("Opus", opus),
            ("Sonnet", sonnet),
            ("Haiku", haiku)
        ]
        .filter { $0.1.isEmpty }
        .map(\.0)

        checks.append(RuntimeReadinessCheck(
            id: "vertex-model-aliases",
            title: "Vertex model aliases",
            detail: missingAliases.isEmpty
                ? "Opus, Sonnet, and Haiku aliases are configured."
                : "Missing \(missingAliases.joined(separator: ", ")) alias.",
            state: missingAliases.isEmpty ? .ready : .blocked,
            remediation: missingAliases.isEmpty
                ? nil
                : "Fill every Vertex model alias so ASTRA can translate Claude model IDs."
        ))

        return checks
    }

    private func claudeProviderEnvironment(for configuration: RuntimeReadinessConfiguration) -> [String: String] {
        var env = RuntimeProcessEnvironment.enriched()
        guard configuration.claudeProvider == .vertex else { return env }

        let project = trimmed(configuration.vertexProjectID)
        let region = trimmed(configuration.vertexRegion)
        if !project.isEmpty {
            env["ANTHROPIC_VERTEX_PROJECT_ID"] = project
        }
        if !region.isEmpty {
            env["CLOUD_ML_REGION"] = region
        }
        env["CLAUDE_CODE_USE_VERTEX"] = "1"

        let opus = trimmed(configuration.vertexOpusModel)
        let sonnet = trimmed(configuration.vertexSonnetModel)
        let haiku = trimmed(configuration.vertexHaikuModel)
        if !opus.isEmpty {
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus
            env["ANTHROPIC_MODEL"] = opus
        }
        if !sonnet.isEmpty {
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet
        }
        if !haiku.isEmpty {
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
            env["ANTHROPIC_SMALL_FAST_MODEL"] = haiku
        }
        return env
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func claudeUtilityEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.shellPathSuffix)"
        for (key, value) in AgentRuntimeProcessRunner.claudeProviderEnvironment() {
            env[key] = value
        }
        return env
    }
}

struct CopilotCLIRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .copilotCLI,
        displayName: "GitHub Copilot CLI",
        executableName: "copilot",
        installHint: "Install via Homebrew: `brew install copilot-cli` or npm: `npm install -g @github/copilot`",
        authHint: "Run `copilot` and use `/login`, or set a GitHub token with Copilot access.",
        prerequisite: CommonCLIPrerequisites.copilot,
        defaultModel: CopilotCLIRuntime.defaultModel,
        defaultModels: CopilotCLIRuntime.defaultModels,
        supportsAstraRunProtocol: true
    )
    let readinessCheckID = "copilot-cli"
    let availableModelsStorageKey = AppStorageKeys.copilotAvailableModels
    let modelsCheckedAtStorageKey = AppStorageKeys.copilotModelsCheckedAt
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .copilotCLI, launchOverheadTokens: 0)
    let recordsStreamTelemetry = true
    let recordsInferredFileChanges = true

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? CopilotCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func missingExecutableAuditReason() -> String {
        "copilot_cli_not_found"
    }

    func missingExecutableStopReason() -> String? {
        "missing_copilot"
    }

    func missingExecutableMessage(executablePath _: String) -> String {
        "GitHub Copilot CLI not found. Install with `brew install copilot-cli` or `npm install -g @github/copilot`, then authenticate with `copilot`."
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        "Copilot started working on: \(task.goal)"
    }

    func connectorPreflightContextText(
        task _: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage _: String?,
        phase _: String
    ) -> String {
        promptOverride ?? startPayload
    }

    func shouldPrepareIsolation(phase _: String) -> Bool {
        true
    }

    func policyCapabilities(executablePath: String) -> AgentRuntimePolicyCapabilities {
        AgentRuntimePolicyCapabilities(copilotCLI: CopilotCLIRuntime.capabilities(executablePath: executablePath))
    }

    func shouldValidateSuccessfulRun(phase _: String) -> Bool {
        true
    }

    func manualCompletionPayload(phase _: String) -> String {
        "Copilot finished."
    }

    func failurePayloadPrefix(phase _: String, exitCode: Int) -> String {
        "Copilot exited with code \(exitCode)."
    }

    func timeoutPayload(phase _: String, timeoutSeconds: TimeInterval) -> String {
        "Task idle timeout - no output for \(Int(timeoutSeconds))s. Process killed."
    }

    func maxTurnsPayload(phase _: String, task: AgentTask) -> String {
        "Max turns reached (\(task.maxTurns)). Process killed."
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: String
    ) -> String {
        promptOverride == nil ? task.goal : (startPayload ?? task.goal)
    }

    func policyAdapter(runtimeCapabilities: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter {
        CopilotPolicyAdapter(capabilities: runtimeCapabilities)
    }

    func providerConfigOwnership(workspacePath _: String) -> PolicyConfigOwnership {
        .generated
    }

    func existingProviderConfigSummary(workspacePath _: String) -> String? {
        nil
    }

    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: context.task,
            contextText: context.contextText
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let capabilityScope = TaskCapabilityResolver(task: context.task).promptScope(contextText: context.contextText)
        let allowed = context.executionPolicy.allowedTools(
            default: capabilityScope.resolver.resolvedProviderAllowedTools
        )
        let providerAllowed = AgentRuntimeProcessRunner.providerAllowedTools(
            for: id,
            baseAllowedTools: allowed,
            permissionManifest: context.permissionManifest
        )
        let runtimeSupportTools = AgentRuntimeProcessRunner.providerRuntimeSupportToolPermissions(
            for: id,
            permissionManifest: context.permissionManifest
        )
        let askFirstTools = context.permissionManifest?.providerRender.askFirstTools ?? []
        let artifactBootstrapTools = ProviderArtifactBootstrapPolicy.launchTools(
            task: context.task,
            permissionPolicy: effectivePermissionPolicy,
            providerAllowedTools: providerAllowed,
            askFirstTools: askFirstTools
        )
        let providerLaunchAllowed = Array(Set(providerAllowed + artifactBootstrapTools)).sorted()
        let pathPrefix = AgentRuntimeProcessRunner.pathPrefix(for: context.task, taskEnv: taskEnv)
        let executable = context.executablePath.isEmpty ? CopilotCLIRuntime.detectPath() : context.executablePath
        let providerVersion = CopilotCLIRuntime.versionSummary(executablePath: executable)
        let capabilities = CopilotCLIRuntime.capabilities(executablePath: executable)
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let additionalPaths = AgentRuntimeProcessRunner.copilotAdditionalPaths(for: context.task)
        let browserBridgeMetadata = BrowserBridgeRuntimeLaunchGuard.planMetadata(runtime: id, environment: taskEnv)
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let copilotStateHome = CopilotCLIRuntime.defaultHome(userHome: userHome)
        var localToolCommands = AgentRuntimeProcessRunner.copilotLocalToolCommands(for: context.task, contextText: context.contextText)
        if browserBridgeMetadata.isAttached {
            localToolCommands.append("astra-browser")
        }
        let surfacedAskFirstTools = askFirstTools
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: context.prompt,
            model: model,
            workspacePath: context.workspacePath,
            additionalPaths: additionalPaths,
            permissionPolicy: effectivePermissionPolicy,
            allowedTools: providerLaunchAllowed,
            timeoutSeconds: context.timeoutSeconds,
            capabilities: capabilities,
            taskEnvironment: taskEnv,
            copilotHome: context.providerHomeDirectory,
            copilotStateHome: copilotStateHome,
            userHome: userHome,
            pathPrefix: pathPrefix,
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(context.task, contextText: context.contextText)
                || browserBridgeMetadata.isAttached,
            localToolCommands: localToolCommands,
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: surfacedAskFirstTools,
            reasoningEffort: artifactBootstrapTools.isEmpty ? nil : "none",
            allowAllPathsForSSHConnections: AgentRuntimeProcessRunner.hasWorkspaceSSHConnections(for: context.task)
        )

        return AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: context.workspacePath,
            environment: plan.environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: CopilotCLIRuntime.directoriesToCreate(
                copilotHome: context.providerHomeDirectory,
                copilotStateHome: copilotStateHome,
                userHome: userHome
            ),
            sandboxReadablePaths: CopilotCLIRuntime.authReadablePaths(userHome: userHome),
            sandboxProtectedWriteDenyPaths: CopilotCLIRuntime.configWriteDenyPaths(userHome: userHome),
            providerDetectedFields: [
                "runtime": id.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
                "executable_path": executable,
                "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(executable)
            ],
            commandPlannedFields: [
                "runtime": id.rawValue,
                "phase": context.phase,
                "model": model,
                "parses_json_lines": String(plan.parsesJSONLines),
                "supports_output_format_json": String(capabilities.supportsOutputFormatJSON),
                "supports_streaming_flag": String(capabilities.supportsStreamingFlag),
                "supports_no_ask_user": String(capabilities.supportsNoAskUser),
                "supports_secret_env_vars": String(capabilities.supportsSecretEnvVars),
                "supports_allow_all": String(capabilities.supportsAllowAll),
                "supports_silent": String(capabilities.supportsSilent),
                "supports_allow_all_tools": String(capabilities.supportsAllowAllTools),
                "supports_allow_all_paths": String(capabilities.supportsAllowAllPaths),
                "supports_allow_all_urls": String(capabilities.supportsAllowAllURLs),
                "supports_available_tools": String(capabilities.supportsAvailableTools),
                "supports_excluded_tools": String(capabilities.supportsExcludedTools),
                "supports_reasoning_effort": String(capabilities.supportsReasoningEffort),
                "requires_allow_all_tools": String(capabilities.requiresAllowAllToolsForPrompt),
                "permission_policy": effectivePermissionPolicy.rawValue,
                "allowed_tools_count": String(providerAllowed.count),
                "provider_launch_allowed_tool_count": String(providerLaunchAllowed.count),
                "runtime_support_tool_count": String(runtimeSupportTools.count),
                "runtime_support_tool_names": runtimeSupportTools.joined(separator: ","),
                "ask_first_tool_count": String(askFirstTools.count),
                "ask_first_tool_names": askFirstTools.joined(separator: ","),
                "surfaced_ask_first_tool_count": String(surfacedAskFirstTools.count),
                "surfaced_ask_first_tool_names": surfacedAskFirstTools.joined(separator: ","),
                "artifact_bootstrap_tool_count": String(artifactBootstrapTools.count),
                "artifact_bootstrap_tool_names": artifactBootstrapTools.joined(separator: ","),
                "artifact_bootstrap_profile": String(!artifactBootstrapTools.isEmpty),
                "allowed_tools_override": String(context.executionPolicy.allowedToolsOverride != nil),
                "local_tool_commands_count": String(localToolCommands.count),
                "additional_paths_count": String(additionalPaths.count),
                "task_env_count": String(taskEnv.count),
                "uses_output_format_json": String(plan.arguments.contains("--output-format=json")),
                "uses_stream_flag": String(plan.arguments.contains("--stream=on")),
                "uses_no_ask_user": String(plan.arguments.contains("--no-ask-user")),
                "uses_reasoning_effort": String(plan.arguments.contains("--effort")),
                "uses_secret_env_vars": String(plan.arguments.contains("--secret-env-vars")),
                "uses_silent": String(plan.arguments.contains("--silent")),
                "uses_allow_all": String(plan.arguments.contains("--allow-all")),
                "uses_allow_all_tools": String(plan.arguments.contains("--allow-all-tools")),
                "uses_allow_all_paths": String(plan.arguments.contains("--allow-all-paths")),
                "uses_allow_all_urls": String(plan.arguments.contains("--allow-all-urls")),
                "uses_allow_tool": String(plan.arguments.contains("--allow-tool")),
                "uses_available_tools": String(plan.arguments.contains("--available-tools")),
                "uses_excluded_tools": String(plan.arguments.contains("--excluded-tools")),
                "excludes_task_tool": String(AgentRuntimeArgumentInspector.argumentList(plan.arguments, after: "--excluded-tools").contains("task"))
            ].merging(browserBridgeMetadata.commandPlannedFields) { current, _ in current }
        )
    }

    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        parsesJSONLines
            ? CopilotStreamEventParser.parseAll(line: line)
            : CopilotStreamEventParser.parsePlainText(line: line)
    }

    func blockingProcessPermissionMessage(line: String, parsesJSONLines _: Bool) -> String? {
        guard CopilotStreamEventParser.isBlockingPlainTextPermissionPrompt(line: line) else {
            return nil
        }
        return "Copilot is waiting for a permission approval ASTRA cannot answer directly: \(line)\n"
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines: Bool) -> AgentRuntimeStreamEventBatch {
        let events = parsesJSONLines
            ? CopilotStreamEventParser.parseAgentEvents(line: line)
            : CopilotStreamEventParser.parsePlainTextAgentEvents(line: line, appendingNewline: true)
        return AgentRuntimeStreamEventBatch(agentEvents: events)
    }

    func processWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        pipeline: AgentRuntimeEventPipelineBox
    ) -> [AgentRuntimeRecordedEvent] {
        guard case .agent(let agentEvent) = event else { return [] }
        return pipeline.process(agentEvent).map(AgentRuntimeRecordedEvent.agent)
    }

    func flushWorkerStreamEvents(pipeline: AgentRuntimeEventPipelineBox) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: pipeline.flushAgentEvents())
    }

    @MainActor
    func recordWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        mode _: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        guard case .agent(let agentEvent) = event else { return }
        AgentEventRecorder.recordCopilotEvent(
            agentEvent,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    func callbackEvent(from event: AgentRuntimeRecordedEvent) -> ParsedEvent? {
        guard let agentEvent = event.agentEvent else { return nil }
        return AgentEventRecorder.parsedEvent(from: agentEvent)
    }

    func runUtilityPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty
            ? CopilotCLIRuntime.detectPath()
            : configuredPath
        let copilotHome = configuration.homeDirectory(for: id).isEmpty
            ? CopilotCLIRuntime.channelHome()
            : configuration.homeDirectory(for: id)
        // Share terminal auth (~/.copilot) like the main launch path so Copilot
        // helper prompts stay authenticated after a plain `copilot` /login.
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let copilotStateHome = CopilotCLIRuntime.defaultHome(userHome: userHome)
        let capabilities = CopilotCLIRuntime.capabilities(executablePath: executable)
        let allowedTools = toolMode == .readOnly ? ["Read", "Glob", "Grep"] : []
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: prompt,
            model: AgentRuntimeProcessRunner.model(configuration.model, for: id),
            workspacePath: workspacePath,
            additionalPaths: [],
            permissionPolicy: .restricted,
            allowedTools: allowedTools,
            timeoutSeconds: configuration.timeoutSeconds,
            capabilities: capabilities,
            taskEnvironment: [:],
            copilotHome: copilotHome,
            copilotStateHome: copilotStateHome,
            userHome: userHome,
            disableCustomInstructions: true
        )

        try? FileManager.default.createDirectory(atPath: copilotHome, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        process.environment = plan.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Non-interactive helper: hand the CLI an empty stdin so it never blocks
        // waiting for input it will never receive (provider-agnostic safeguard).
        process.standardInput = FileHandle.nullDevice
        if plan.parsesJSONLines {
            return await runStreamingCopilotUtilityPrompt(
                process,
                stdout: stdoutPipe,
                stderr: stderrPipe,
                timeoutSeconds: configuration.timeoutSeconds
            )
        }

        let result = await AsyncProcessRunner.run(
            process,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            timeoutSeconds: configuration.timeoutSeconds
        )
        let output = plan.parsesJSONLines
            ? extractCopilotUtilityText(from: result.stdout)
            : result.stdout
        return AgentUtilityRunResult(exitCode: result.exitCode, output: output, error: result.stderr)
    }

    private func runStreamingCopilotUtilityPrompt(
        _ process: Process,
        stdout: Pipe,
        stderr: Pipe,
        timeoutSeconds: TimeInterval?
    ) async -> AgentUtilityRunResult {
        let state = CopilotUtilityStreamRunState()
        let stdoutLines = AgentLockedBuffer()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finish: @Sendable (AgentUtilityRunResult, Bool) -> Void = { result, shouldTerminate in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    if shouldTerminate {
                        AsyncProcessRunner.terminateProcessTree(process)
                    }
                    continuation.resume(returning: result)
                }

                let handleLine: @Sendable (String) -> Void = { line in
                    if let result = state.appendStdoutLineAndCompleteIfReady(line) {
                        finish(result, true)
                    }
                }

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty,
                          let chunk = String(data: data, encoding: .utf8) else { return }
                    stdoutLines.appendAndProcessLines(chunk, handleLine)
                }

                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty,
                          let chunk = String(data: data, encoding: .utf8) else { return }
                    state.appendStderr(chunk)
                }

                process.terminationHandler = { proc in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    if let chunk = String(
                        data: stdout.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ), !chunk.isEmpty {
                        stdoutLines.appendAndProcessLines(chunk, handleLine)
                    }
                    let remaining = stdoutLines.drainRemaining()
                    if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        handleLine(remaining)
                    }
                    if let chunk = String(
                        data: stderr.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ), !chunk.isEmpty {
                        state.appendStderr(chunk)
                    }
                    if let result = state.completeWithProcessExit(exitCode: Int(proc.terminationStatus)) {
                        finish(result, false)
                    }
                }

                do {
                    try process.run()
                    scheduleCopilotUtilityTimeout(
                        process: process,
                        timeoutSeconds: timeoutSeconds,
                        state: state,
                        finish: finish
                    )
                } catch {
                    if let result = state.completeWithLaunchError(error.localizedDescription) {
                        finish(result, false)
                    }
                }
            }
        } onCancel: {
            AsyncProcessRunner.terminateProcessTree(process)
        }
    }

    private func scheduleCopilotUtilityTimeout(
        process: Process,
        timeoutSeconds: TimeInterval?,
        state: CopilotUtilityStreamRunState,
        finish: @escaping @Sendable (AgentUtilityRunResult, Bool) -> Void
    ) {
        guard let timeoutSeconds, timeoutSeconds > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            if let result = state.completeWithTimeout(timeoutSeconds: timeoutSeconds) {
                finish(result, true)
            }
        }
    }

    @MainActor
    func recordPostProcessEvents(context: AgentRuntimePostProcessContext) {
        guard context.run.tokensUsed == 0 else {
            return
        }
        let homes = [context.homeDirectory, CopilotCLIRuntime.defaultHome()]
        var seenHomes: Set<String> = []
        var metrics: CopilotSessionMetrics?
        for home in homes {
            let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenHomes.insert(trimmed).inserted else { continue }
            metrics = CopilotSessionMetricsReader.finalMetrics(
                copilotHome: trimmed,
                taskID: context.task.id,
                runStartedAt: context.runStartedAt
            )
            if metrics != nil { break }
        }
        guard let metrics else { return }

        AgentEventRecorder.recordCopilotEvent(
            metrics.event,
            to: context.task,
            run: context.run,
            modelContext: context.modelContext,
            recordingState: context.recordingState
        )
        if let parsed = AgentEventRecorder.parsedEvent(from: metrics.event) {
            context.onEvent(parsed)
        }
        AppLogger.audit(.taskStats, category: "Worker", taskID: context.task.id, fields: [
            "source": "copilot_session_state",
            "session_id_prefix": String(metrics.sessionID.prefix(8)),
            "tokens_total": String(metrics.totalTokens),
            "tokens_input": String(metrics.inputTokens),
            "tokens_output": String(metrics.outputTokens),
            "turns": metrics.turns.map(String.init) ?? "unknown",
            "duration_ms": metrics.durationMs.map(String.init) ?? "unknown"
        ])
    }

    @MainActor
    func logStreamTelemetry(
        snapshot: AgentRuntimeStreamTelemetrySnapshot,
        task: AgentTask,
        run: TaskRun,
        phase: String,
        exitCode: Int
    ) {
        AgentRuntimeStreamDiagnostics.logCopilotStreamTelemetry(
            snapshot: snapshot,
            task: task,
            run: run,
            phase: phase,
            exitCode: exitCode
        )
    }

    private func extractCopilotUtilityText(from output: String) -> String {
        var pieces: [String] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            for event in CopilotStreamEventParser.parseAgentEvents(line: line) {
                switch event {
                case .text(let text):
                    pieces.append(text)
                case .completed(let summary):
                    if let summary, !summary.isEmpty {
                        pieces.append(summary)
                    }
                case .failed(let message):
                    pieces.append(message)
                default:
                    continue
                }
            }
        }
        let joined = pieces.joined()
        return joined.isEmpty ? output : joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class CopilotUtilityStreamRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var rawOutput = ""
    private var outputPieces: [String] = []
    private var stderrOutput = ""

    func appendStdoutLineAndCompleteIfReady(_ line: String) -> AgentUtilityRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }

        rawOutput += line
        rawOutput += "\n"

        var completedLine = false
        for event in CopilotStreamEventParser.parseAgentEvents(line: line) {
            switch event {
            case .text(let text):
                outputPieces.append(text)
            case .completed(let summary):
                completedLine = true
                if let summary, !summary.isEmpty {
                    outputPieces.append(summary)
                }
            default:
                continue
            }
        }

        let hasOutput = !renderedOutputLocked().isEmpty
        guard completedLine || (hasOutput && Self.isTerminalLine(line)) else {
            return nil
        }

        completed = true
        return makeResultLocked(exitCode: 0, error: stderrOutput)
    }

    func appendStderr(_ chunk: String) {
        lock.lock()
        stderrOutput += chunk
        lock.unlock()
    }

    func completeWithProcessExit(exitCode: Int) -> AgentUtilityRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }

        completed = true
        return makeResultLocked(exitCode: exitCode, error: stderrOutput)
    }

    func completeWithLaunchError(_ message: String) -> AgentUtilityRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }

        completed = true
        return AgentUtilityRunResult(exitCode: -1, output: "", error: message)
    }

    func completeWithTimeout(timeoutSeconds: TimeInterval) -> AgentUtilityRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }

        completed = true
        let timeoutText = "Process timed out after \(Int(timeoutSeconds.rounded())) seconds."
        return AgentUtilityRunResult(exitCode: -1, output: "", error: timeoutText)
    }

    private func makeResultLocked(exitCode: Int, error: String) -> AgentUtilityRunResult {
        AgentUtilityRunResult(
            exitCode: exitCode,
            output: renderedOutputLocked(),
            error: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func renderedOutputLocked() -> String {
        let parsed = outputPieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !parsed.isEmpty {
            return parsed
        }
        return rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTerminalLine(_ line: String) -> Bool {
        let terminalTypes: Set<String> = [
            "assistant.turn_end",
            "session.shutdown",
            "result",
            "completed",
            "complete"
        ]
        guard let object = jsonObject(from: line),
              let type = eventType(in: object)?.lowercased() else {
            return false
        }
        return terminalTypes.contains(type)
    }

    private static func eventType(in object: [String: Any]) -> String? {
        for key in ["type", "event", "kind", "sessionUpdate", "name"] {
            if let value = object[key] as? String {
                return value
            }
        }
        for key in ["data", "payload", "message"] {
            if let nested = object[key] as? [String: Any],
               let value = eventType(in: nested) {
                return value
            }
        }
        return nil
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct AntigravityCLIRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .antigravityCLI,
        displayName: "Google Antigravity CLI",
        executableName: "agy",
        installHint: "Install from the official Google Antigravity CLI setup docs: https://www.antigravity.google/docs/cli-getting-started",
        authHint: "Run `agy` once and complete Google Sign-In when prompted.",
        prerequisite: CommonCLIPrerequisites.antigravity,
        defaultModel: AntigravityCLIRuntime.defaultModelName(),
        defaultModels: AntigravityCLIRuntime.availableModelNames(),
        supportsAstraRunProtocol: true
    )
    let readinessCheckID = "antigravity-cli"
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .antigravityCLI, launchOverheadTokens: 0)
    let recordsInferredFileChanges = true
    let recordsEstimatedUsageWhenProviderUsageMissing = true
    let modelAvailabilityAuthority: RuntimeModelAvailabilityAuthority = .suggestions

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? AntigravityCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func sharedLaunchStateKey(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeSharedStateKey? {
        AgentRuntimeSharedStateKey(
            runtime: id,
            identifier: AntigravityCLIRuntime.settingsURL(
                providerHomeDirectory: context.providerHomeDirectory
            ).standardizedFileURL.path
        )
    }

    func missingExecutableAuditReason() -> String {
        "antigravity_cli_not_found"
    }

    func missingExecutableStopReason() -> String? {
        "missing_antigravity"
    }

    func missingExecutableMessage(executablePath _: String) -> String {
        "Google Antigravity CLI not found. Install it from the official setup docs, then run `agy` once to authenticate."
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        "Antigravity started working on: \(task.goal)"
    }

    func connectorPreflightContextText(
        task _: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage _: String?,
        phase _: String
    ) -> String {
        promptOverride ?? startPayload
    }

    func shouldPrepareIsolation(phase _: String) -> Bool {
        true
    }

    func shouldValidateSuccessfulRun(phase _: String) -> Bool {
        true
    }

    func requiresVisibleResultForSuccessfulRun(phase _: String) -> Bool {
        true
    }

    func manualCompletionPayload(phase _: String) -> String {
        "Antigravity finished."
    }

    func failurePayloadPrefix(phase _: String, exitCode: Int) -> String {
        "Antigravity exited with code \(exitCode)."
    }

    func timeoutPayload(phase _: String, timeoutSeconds: TimeInterval) -> String {
        "Task idle timeout - no output for \(Int(timeoutSeconds))s. Process killed."
    }

    func maxTurnsPayload(phase _: String, task: AgentTask) -> String {
        "Max turns reached (\(task.maxTurns)). Process killed."
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: String
    ) -> String {
        promptOverride == nil ? task.goal : (startPayload ?? task.goal)
    }

    func policyAdapter(runtimeCapabilities _: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter {
        AntigravityPolicyAdapter()
    }

    func providerConfigOwnership(workspacePath _: String) -> PolicyConfigOwnership {
        .generated
    }

    func existingProviderConfigSummary(workspacePath _: String) -> String? {
        nil
    }

    func readinessReport(
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessReport {
        let prerequisite = descriptor.prerequisite
        let executable = probes.resolvedExecutable(
            configuredPath: configuration.executablePath(for: id),
            binary: prerequisite.binary
        )
        let cliStatus = await probes.checkExecutable(
            id: readinessCheckID,
            title: prerequisite.displayName,
            executable: executable,
            args: prerequisite.livenessArgs,
            missingDetail: "\(prerequisite.displayName) was not found.",
            installHint: prerequisite.installHint
        )

        var checks = [cliStatus.check]
        if cliStatus.isReady {
            switch configuration.scope {
            case .availability:
                checks.append(antigravityAccountDeferredCheck())
            case .diagnostic:
                checks.append(await antigravityLiveAccountCheck(
                    executable: executable ?? "",
                    providerHomeDirectory: configuration.providerSettings.homeDirectory(for: id),
                    probes: probes
                ))
            }
        }
        return RuntimeReadinessReport(checks: checks)
    }

    func modelAvailabilityCheck(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty ? AntigravityCLIRuntime.detectPath() : configuredPath
        let models = AntigravityCLIRuntime.modelNames(executablePath: executable)
            ?? AntigravityCLIRuntime.availableModelNames()
        await RuntimeModelAvailability.persistObservedAvailableModels(models, for: id, authority: modelAvailabilityAuthority)
        return RuntimeReadinessCheck(
            id: "antigravity-models",
            title: "Antigravity models",
            detail: "Available: \(models.joined(separator: ", "))",
            state: .ready,
            remediation: nil
        )
    }

    func installPlan(detectExecutable _: @Sendable (String) -> String) -> RuntimeCLIInstallPlan? {
        nil
    }

    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: context.task,
            contextText: context.contextText
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let pathPrefix = AgentRuntimeProcessRunner.pathPrefix(for: context.task, taskEnv: taskEnv)
        let executable = context.executablePath.isEmpty ? AntigravityCLIRuntime.detectPath() : context.executablePath
        let providerVersion = AntigravityCLIRuntime.versionSummary(executablePath: executable)
        let modelSettingsURL = AntigravityCLIRuntime.settingsURL(
            providerHomeDirectory: context.providerHomeDirectory
        )
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let providerModel = AntigravityCLIRuntime.resolvedModelName(model, settingsURL: modelSettingsURL)
        let modelApplied = FileManager.default.isExecutableFile(atPath: executable)
            ? AntigravityCLIRuntime.applySelectedModel(providerModel, settingsURL: modelSettingsURL)
            : false
        let diagnosticLogPath = context.runID.flatMap {
            AntigravityCLIRuntime.diagnosticLogPath(task: context.task, runID: $0)
        }
        let additionalPaths = AgentRuntimeProcessRunner.runtimeAdditionalPaths(for: context.task)
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: context.prompt,
            workspacePath: context.workspacePath,
            additionalPaths: additionalPaths,
            permissionPolicy: effectivePermissionPolicy,
            timeoutSeconds: context.timeoutSeconds,
            taskEnvironment: taskEnv,
            providerHomeDirectory: context.providerHomeDirectory,
            pathPrefix: pathPrefix,
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(context.task, contextText: context.contextText)
                || taskEnv["ASTRA_BROWSER_URL"] != nil,
            diagnosticLogPath: diagnosticLogPath
        )

        return AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: context.workspacePath,
            environment: plan.environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: [AntigravityCLIRuntime.diagnosticLogDirectory(for: diagnosticLogPath)].compactMap { $0 },
            providerDetectedFields: [
                "runtime": id.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
                "executable_path": executable,
                "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(executable),
                "provider_home_configured": String(!context.providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ],
            commandPlannedFields: [
                "runtime": id.rawValue,
                "phase": context.phase,
                "model": model,
                "provider_model": providerModel,
                "model_applied": String(modelApplied),
                "permission_policy": effectivePermissionPolicy.rawValue,
                "parses_json_lines": String(plan.parsesJSONLines),
                "additional_paths_count": String(additionalPaths.count),
                "task_env_count": String(taskEnv.count),
                "uses_print": String(plan.arguments.contains("--print")),
                "uses_print_timeout": String(plan.arguments.contains("--print-timeout")),
                "uses_log_file": String(plan.arguments.contains("--log-file")),
                "diagnostic_log_configured": String(diagnosticLogPath != nil),
                "diagnostic_log_path": diagnosticLogPath ?? "",
                "uses_sandbox": String(plan.arguments.contains("--sandbox")),
                "uses_dangerously_skip_permissions": String(plan.arguments.contains("--dangerously-skip-permissions"))
            ]
        )
    }

    func parseProcessEvents(line: String, parsesJSONLines _: Bool) -> [ParsedEvent] {
        AntigravityCLIRuntime.parsePlainText(line: line)
    }

    func blockingProcessPermissionMessage(line: String, parsesJSONLines _: Bool) -> String? {
        AntigravityCLIRuntime.blockingPlainTextMessage(line: line)
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines _: Bool) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: AntigravityCLIRuntime.parsePlainTextAgentEvents(
            line: line,
            appendingNewline: true
        ))
    }

    func processWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        pipeline: AgentRuntimeEventPipelineBox
    ) -> [AgentRuntimeRecordedEvent] {
        guard case .agent(let agentEvent) = event else { return [] }
        return pipeline.process(agentEvent).map(AgentRuntimeRecordedEvent.agent)
    }

    func flushWorkerStreamEvents(pipeline: AgentRuntimeEventPipelineBox) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: pipeline.flushAgentEvents())
    }

    @MainActor
    func recordWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        mode _: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        guard case .agent(let agentEvent) = event else { return }
        AgentEventRecorder.recordAntigravityEvent(
            agentEvent,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    func callbackEvent(from event: AgentRuntimeRecordedEvent) -> ParsedEvent? {
        guard let agentEvent = event.agentEvent else { return nil }
        return AgentEventRecorder.parsedEvent(from: agentEvent)
    }

    func runUtilityPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode _: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty
            ? AntigravityCLIRuntime.detectPath()
            : configuredPath
        let modelSettingsURL = AntigravityCLIRuntime.settingsURL(
            providerHomeDirectory: configuration.homeDirectory(for: id)
        )
        let sharedStateKey = AgentRuntimeSharedStateKey(
            runtime: id,
            identifier: modelSettingsURL.standardizedFileURL.path
        )
        do {
            try await AgentRuntimeSharedStateGate.shared.acquire(sharedStateKey)
        } catch is CancellationError {
            return AgentUtilityRunResult(
                exitCode: -1,
                output: "",
                error: "Task cancelled before acquiring provider shared state."
            )
        } catch {
            return AgentUtilityRunResult(exitCode: -1, output: "", error: error.localizedDescription)
        }
        let model = AgentRuntimeProcessRunner.model(configuration.model, for: id)
        if FileManager.default.isExecutableFile(atPath: executable) {
            AntigravityCLIRuntime.applySelectedModel(model, settingsURL: modelSettingsURL)
        }
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: prompt,
            workspacePath: workspacePath,
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: configuration.timeoutSeconds,
            taskEnvironment: [:],
            providerHomeDirectory: configuration.homeDirectory(for: id)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        process.environment = plan.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Non-interactive helper: hand the CLI an empty stdin so it never blocks
        // waiting for input it will never receive (provider-agnostic safeguard).
        process.standardInput = FileHandle.nullDevice
        let result = await AsyncProcessRunner.run(
            process,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            timeoutSeconds: configuration.timeoutSeconds
        )
        await AgentRuntimeSharedStateGate.shared.release(sharedStateKey)
        return AgentUtilityRunResult(exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }

    private func antigravityLiveAccountCheck(
        executable: String,
        providerHomeDirectory: String,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let timeoutSeconds: TimeInterval = 30
        let args = [
            "--print",
            "Reply with ASTRA_READY only.",
            "--print-timeout",
            "\(Int(timeoutSeconds))s",
            "--sandbox"
        ]
        var extraVars: [String: String] = [
            "NO_COLOR": "1",
            "AGY_CLI_HIDE_ACCOUNT_INFO": "1",
        ]
        let parentTerm = ProcessInfo.processInfo.environment["TERM"]
        extraVars["TERM"] = parentTerm ?? "xterm-256color"
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            extraVars["HOME"] = trimmedHome
        }
        let environment = RuntimeProcessEnvironment.enriched(extraVariables: extraVars)

        let result = await probes.run(
            path: executable,
            args: args,
            timeout: timeoutSeconds,
            environment: environment
        )
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "antigravity-account",
                title: "Antigravity account",
                detail: antigravityLiveAccountFailureDetail(result, timeoutSeconds: timeoutSeconds),
                state: .blocked,
                remediation: "Run `agy` in Terminal, complete Google Sign-In, then click Check Again."
            )
        }
        guard antigravityReadinessOutputContainsReadyLine(result.stdout) else {
            return RuntimeReadinessCheck(
                id: "antigravity-account",
                title: "Antigravity account",
                detail: antigravityLiveAccountEmptySuccessDetail(result),
                state: .blocked,
                remediation: "Run `agy --print 'Reply with ASTRA_READY only.' --print-timeout 30s --sandbox` in Terminal and confirm it prints ASTRA_READY."
            )
        }

        return RuntimeReadinessCheck(
            id: "antigravity-account",
            title: "Antigravity account",
            detail: "Live non-interactive check completed with `agy --print --sandbox`.",
            state: .ready,
            remediation: nil
        )
    }

    private func antigravityReadinessOutputContainsReadyLine(_ stdout: String) -> Bool {
        stdout
            .components(separatedBy: .newlines)
            .contains { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines) == "ASTRA_READY"
            }
    }

    private func antigravityLiveAccountEmptySuccessDetail(_ result: RunResult) -> String {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty && stderr.isEmpty {
            return "Live Antigravity check exited successfully but produced no ASTRA_READY output."
        }
        let evidence = RuntimeReadinessRedactor.redacted(stdout.isEmpty ? stderr : stdout)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Live Antigravity check exited successfully but did not print ASTRA_READY: \(String(evidence.prefix(180)))"
    }

    private func antigravityAccountDeferredCheck() -> RuntimeReadinessCheck {
        RuntimeReadinessCheck(
            id: "antigravity-account",
            title: "Antigravity account",
            detail: "CLI is available. Run Check Again in Settings for a live non-interactive account check.",
            state: .ready,
            remediation: nil
        )
    }

    private func antigravityLiveAccountFailureDetail(
        _ result: RunResult,
        timeoutSeconds: TimeInterval
    ) -> String {
        switch result.outcome {
        case .launchFailed(let reason):
            return "Could not launch live Antigravity check: \(RuntimeReadinessRedactor.redacted(reason))"
        case .timedOut:
            return "Timed out after \(Int(timeoutSeconds))s during live Antigravity check."
        case .cancelled:
            return "Live Antigravity check was cancelled."
        case .exited(let code):
            let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
            let sanitized = RuntimeReadinessRedactor.redacted(evidence)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else {
                return "Live Antigravity check exited with status \(code)."
            }
            return "Live Antigravity check exited with status \(code): \(String(sanitized.prefix(180)))"
        }
    }
}

private extension String {
    func replacingPattern(
        _ pattern: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }
}
