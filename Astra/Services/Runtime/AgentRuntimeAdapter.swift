import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

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
    /// Presentation copy for missing-executable diagnostics and the default
    /// start-event payload. See `ProviderRuntimeMessages` for the full set of
    /// diagnostic-copy accessors this backs by default.
    var providerRuntimeMessages: ProviderRuntimeMessages { get }

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
        phase: RunPhase
    ) -> String
    func shouldCheckWorkspaceDirectory(phase: RunPhase) -> Bool
    func shouldPrepareIsolation(phase: RunPhase) -> Bool
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
    /// Presentation copy for completion/failure/timeout/max-turns diagnostics
    /// and the resume session-turn message. See `ProviderRuntimeMessages`.
    var providerRuntimeMessages: ProviderRuntimeMessages { get }

    func shouldValidateSuccessfulRun(phase: RunPhase) -> Bool
    func requiresVisibleResultForSuccessfulRun(phase: RunPhase) -> Bool
    func manualCompletionPayload(phase: RunPhase) -> String
    func failurePayloadPrefix(phase: RunPhase, exitCode: Int) -> String
    func timeoutPayload(phase: RunPhase, timeoutSeconds: TimeInterval) -> String
    func maxTurnsPayload(phase: RunPhase, task: AgentTask) -> String
    func shouldClearStaleSessionOnFailure(phase: RunPhase, result: AgentProcessResult) -> Bool
    func performsPostRunFollowUps(phase: RunPhase) -> Bool
    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage: String?,
        phase: RunPhase
    ) -> String
    @MainActor
    func recordPostProcessEvents(context: AgentRuntimePostProcessContext)
    @MainActor
    func logStreamTelemetry(
        snapshot: AgentRuntimeStreamTelemetrySnapshot,
        task: AgentTask,
        run: TaskRun,
        phase: RunPhase,
        exitCode: Int
    )
}

protocol AgentRuntimeAdapter: AgentRuntimeDescriptorReadiness,
    AgentRuntimePolicyRendering,
    AgentRuntimeProcessLaunchPlanning,
    AgentRuntimeProcessEventParsing,
    AgentRuntimeWorkerEventRecording,
    AgentUtilityRuntimeAdapter,
    AgentRuntimePostRunDiagnostics,
    AgentRuntimeSandboxContract {}

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
        providerRuntimeMessages.missingExecutableAuditReason
    }

    func missingExecutableStopReason() -> String? {
        providerRuntimeMessages.missingExecutableStopReason
    }

    func missingExecutableMessage(executablePath: String) -> String {
        providerRuntimeMessages.missingExecutableMessage(executablePath: executablePath, displayName: id.displayName)
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        providerRuntimeMessages.defaultStartEventPayload(goal: task.goal)
    }

    func connectorPreflightContextText(
        task: AgentTask,
        promptOverride _: String?,
        startPayload _: String,
        sessionMessage: String?,
        phase _: RunPhase
    ) -> String {
        sessionMessage ?? task.goal
    }

    func shouldCheckWorkspaceDirectory(phase _: RunPhase) -> Bool {
        true
    }

    func shouldPrepareIsolation(phase: RunPhase) -> Bool {
        phase == .run
    }
}

extension AgentRuntimePolicyRendering {
    func policyCapabilities(executablePath _: String) -> AgentRuntimePolicyCapabilities {
        .conservative
    }
}

extension AgentRuntimePostRunDiagnostics {
    func shouldValidateSuccessfulRun(phase: RunPhase) -> Bool {
        phase == .run
    }

    func requiresVisibleResultForSuccessfulRun(phase _: RunPhase) -> Bool {
        false
    }

    func manualCompletionPayload(phase: RunPhase) -> String {
        providerRuntimeMessages.manualCompletionPayload(phase: phase)
    }

    func failurePayloadPrefix(phase: RunPhase, exitCode: Int) -> String {
        providerRuntimeMessages.failurePayloadPrefix(phase: phase, exitCode: exitCode)
    }

    func timeoutPayload(phase: RunPhase, timeoutSeconds: TimeInterval) -> String {
        providerRuntimeMessages.timeoutPayload(phase: phase, timeoutSeconds: timeoutSeconds)
    }

    func maxTurnsPayload(phase: RunPhase, task: AgentTask) -> String {
        providerRuntimeMessages.maxTurnsPayload(phase: phase, maxTurns: task.maxTurns)
    }

    func shouldClearStaleSessionOnFailure(phase: RunPhase, result: AgentProcessResult) -> Bool {
        false
    }

    func performsPostRunFollowUps(phase _: RunPhase) -> Bool {
        false
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride _: String?,
        startPayload _: String?,
        sessionMessage: String?,
        phase _: RunPhase
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
        phase _: RunPhase,
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

enum AgentRuntimeAdapterRegistry: Sendable {
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

/// Launch-invariant fields read directly off `AgentRuntimeProcessLaunchContext.task`
/// (as opposed to the many launch helpers that take the live `AgentTask` itself —
/// see the field-by-field audit in the commit introducing this type). Captured
/// once at context construction so adapters that only need these scalars don't
/// hold a live SwiftData model reference.
struct AgentTaskLaunchSnapshot: Sendable, Equatable {
    let id: UUID
    let model: String
    let maxTurns: Int

    init(task: AgentTask) {
        self.id = task.id
        self.model = task.model
        self.maxTurns = task.maxTurns
    }

    init(id: UUID, model: String, maxTurns: Int) {
        self.id = id
        self.model = model
        self.maxTurns = maxTurns
    }
}

struct AgentRuntimeProcessLaunchContext {
    let prompt: String
    /// Live SwiftData model, retained for launch helpers that resolve
    /// workspace/environment/capability state (`TaskWorkspaceAccess`,
    /// `DockerExecutionPlanner`, `MCPRuntimeProjection`, capability resolution,
    /// etc.) which is itself unsnapshotted. Direct scalar reads at the adapter
    /// call sites go through `taskSnapshot` instead — see the audit table in
    /// the commit that introduced `AgentTaskLaunchSnapshot`.
    let task: AgentTask
    let taskSnapshot: AgentTaskLaunchSnapshot
    let workspacePath: String
    let executablePath: String
    let providerHomeDirectory: String
    let permissionPolicy: PermissionPolicy
    let executionPolicy: AgentRuntimeExecutionPolicy
    let permissionManifest: RunPermissionManifest?
    let timeoutSeconds: TimeInterval
    let phase: RunPhase
    let contextText: String
    let nativeContinuationSessionID: String?
    let runID: UUID?
    let liveApprovalsEnabled: Bool
    let launchResourcePlan: TaskLaunchResourcePlan?
    let capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    // The AgentRuntimeLaunchRuntimeResolver.resolve() requirement set for this
    // same launch attempt, threaded in by AgentRuntimeWorker so runtime
    // adapters can attach the exact host-control MCP tools (and related
    // Docker workspace / browser-control requirements) the resolver already
    // decided this task needs, instead of re-deriving the answer from a
    // second, independently-captured TaskCapabilityResolutionSnapshot. Nil for
    // any caller that hasn't run the resolver (falls back to today's
    // independent-derivation behavior). See
    // Tests/HostControlRequirementDerivationConsistencyTests.swift.
    let runtimeRequirements: TaskRuntimeRequirementSet?

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
        phase: RunPhase = .run,
        contextText: String = "",
        nativeContinuationSessionID: String? = nil,
        runID: UUID? = nil,
        liveApprovalsEnabled: Bool = false,
        launchResourcePlan: TaskLaunchResourcePlan? = nil,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        runtimeRequirements: TaskRuntimeRequirementSet? = nil
    ) {
        self.prompt = prompt
        self.task = task
        self.taskSnapshot = AgentTaskLaunchSnapshot(task: task)
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
        self.launchResourcePlan = launchResourcePlan
        self.capabilityResolutionSnapshot = capabilityResolutionSnapshot ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? []
        )
        self.runtimeRequirements = runtimeRequirements
    }

    func replacingLaunchResourcePlan(
        _ launchResourcePlan: TaskLaunchResourcePlan
    ) -> AgentRuntimeProcessLaunchContext {
        AgentRuntimeProcessLaunchContext(
            prompt: prompt,
            task: task,
            workspacePath: workspacePath,
            executablePath: executablePath,
            providerHomeDirectory: providerHomeDirectory,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            permissionManifest: permissionManifest,
            timeoutSeconds: timeoutSeconds,
            phase: phase,
            contextText: contextText,
            nativeContinuationSessionID: nativeContinuationSessionID,
            runID: runID,
            liveApprovalsEnabled: liveApprovalsEnabled,
            launchResourcePlan: launchResourcePlan,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            runtimeRequirements: runtimeRequirements
        )
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
    let sandboxHomeStateAccess: AgentRuntimeHomeStateAccess
    /// Files carved back out of a writable root as read-only (write-deny over
    /// write-allow). See `CopilotCLIRuntime.configWriteDenyPaths`.
    let sandboxProtectedWriteDenyPaths: [String]
    let providerDetectedFields: [String: String]
    let commandPlannedFields: [String: String]
    var interactiveAsk: AgentRuntimeInteractiveAskPlan?
    var pathMapper: ExecutionEnvironmentPathMapper?
    var executionEnvironment: WorkspaceExecutionEnvironment
    /// Set only by `AgentRuntimeProcessRunner` after every required read-only
    /// enforcement surface has been applied and verified.
    var readOnlyBoundaryReceipt: ReadOnlyResourceBoundaryReceipt?

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
        sandboxHomeStateAccess: AgentRuntimeHomeStateAccess? = nil,
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
        self.sandboxHomeStateAccess = sandboxHomeStateAccess ?? AgentRuntimeAdapterRegistry.homeStateAccess(for: runtime)
        self.sandboxProtectedWriteDenyPaths = sandboxProtectedWriteDenyPaths
        self.providerDetectedFields = providerDetectedFields
        self.commandPlannedFields = commandPlannedFields
        self.interactiveAsk = interactiveAsk
        self.pathMapper = pathMapper
        self.executionEnvironment = executionEnvironment
        self.readOnlyBoundaryReceipt = nil
    }

}

enum AgentRuntimeRecordingMode {
    case initial
    case followUp
}

/// Wraps the single event model every runtime now records through.
///
/// This used to be a two-case enum (`.parsed(ParsedEvent)` for Claude,
/// `.agent(AgentEvent)` for the other five runtimes) because Claude recorded
/// through Claude-only dispatch functions that switched on `ParsedEvent`
/// directly. Claude now maps its stream to `AgentEvent` too (see
/// `AgentEventRecorder.agentEvents(from:)`) and shares the same
/// `recordProviderAgentEvent` dispatcher as every other provider, so this
/// wrapper only has one case left. It stays a thin wrapper (rather than using
/// `AgentEvent` bare) so `AgentRuntimeStreamEventBatch` and the
/// `AgentRuntimeWorkerEventRecording` protocol keep a stable shape if a future
/// runtime ever needs a second representation.
enum AgentRuntimeRecordedEvent {
    case agent(AgentEvent)

    var agentEvent: AgentEvent? {
        if case .agent(let event) = self {
            return event
        }
        return nil
    }
}

struct AgentRuntimeStreamEventBatch {
    let events: [AgentRuntimeRecordedEvent]

    init(events: [AgentRuntimeRecordedEvent]) {
        self.events = events
    }

    init(agentEvents: [AgentEvent]) {
        events = agentEvents.map(AgentRuntimeRecordedEvent.agent)
    }

    var agentEvents: [AgentEvent] {
        events.compactMap(\.agentEvent)
    }

    func recordParsed(to capture: AgentRuntimeStreamDebugCapture?, rawLine: String) {
        capture?.recordParsed(agentEvents, rawLine: rawLine)
    }

    func recordEmitted(to capture: AgentRuntimeStreamDebugCapture?) {
        capture?.recordEmitted(agentEvents)
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
        installHint: String,
        timeout overrideTimeout: TimeInterval? = nil,
        timedOutState: RuntimeReadinessState = .blocked,
        timedOutRemediation: String? = nil
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

        let effectiveTimeout = overrideTimeout ?? timeout
        let result = await runner.run(path: executable, args: args, timeout: effectiveTimeout, environment: processEnvironment)
        if case .timedOut = result.outcome {
            return RuntimeExecutableCheckResult(
                executable: executable,
                check: RuntimeReadinessCheck(
                    id: id,
                    title: title,
                    detail: processFailureDetail(result, timeout: effectiveTimeout),
                    state: timedOutState,
                    remediation: timedOutRemediation ?? "Verify the configured path: \(executable)"
                )
            )
        }
        guard result.isSuccess else {
            return RuntimeExecutableCheckResult(
                executable: executable,
                check: RuntimeReadinessCheck(
                    id: id,
                    title: title,
                    detail: processFailureDetail(result, timeout: effectiveTimeout),
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

    private func processFailureDetail(_ result: RunResult, timeout: TimeInterval) -> String {
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
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode

    func shouldCheckWorkspaceDirectory(phase: RunPhase) -> Bool {
        phase == .run
    }

    func shouldClearStaleSessionOnFailure(phase: RunPhase, result: AgentProcessResult) -> Bool {
        guard phase == .resume else { return false }
        return result.error?.contains("session") == true || result.error?.contains("not found") == true
    }

    func performsPostRunFollowUps(phase: RunPhase) -> Bool {
        phase == .run
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
                installHint: CommonCLIPrerequisites.gcloud.installHint,
                timeout: 20,
                timedOutState: .warning,
                timedOutRemediation: "gcloud responded slowly. ASTRA will continue and validate Application Default Credentials separately."
            )
            checks.append(gcloud.check)
            if gcloud.check.state != .blocked, let executable = gcloud.executable {
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
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            contextText: context.contextText,
            executionPolicy: context.executionPolicy
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let capabilityScope = context.capabilityResolutionSnapshot.providerLaunch
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
        let hostControlEnvironment = HostControlPlaneMCPProjection.environmentVariables(
            task: context.task,
            environment: executionEnvironment,
            currentDirectory: context.workspacePath,
            runID: context.runID,
            taskEnvironment: taskEnv,
            contextText: context.contextText,
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            precomputedRuntimeRequirements: context.runtimeRequirements
        )
        if let hostControlServer = HostControlPlaneMCPProjection.resolvedServer(
            task: context.task,
            environment: executionEnvironment,
            currentDirectory: context.workspacePath,
            runID: context.runID,
            taskEnvironment: taskEnv.merging(hostControlEnvironment) { current, _ in current },
            contextText: context.contextText,
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            precomputedRuntimeRequirements: context.runtimeRequirements
        ) {
            mcpServers.append(hostControlServer)
        }
        if let browserServer = BrowserBridgeMCPProjection.resolvedServer(
            for: context.task,
            contextText: context.contextText
        ) {
            mcpServers.append(browserServer)
        }
        let workspaceExecutorEnvironment = DockerWorkspaceMCPProjection.environmentVariables(
            task: context.task,
            environment: executionEnvironment,
            currentDirectory: context.workspacePath,
            runID: context.runID
        )
        let explicitMCPEnvironment = taskEnv
            .merging(workspaceExecutorEnvironment) { current, _ in current }
            .merging(hostControlEnvironment) { current, _ in current }
        // allowEmpty: strict mode must apply even with zero governed servers,
        // or a repository's own .mcp.json loads ungoverned on those runs.
        let mcpConfigURL = MCPRuntimeProjection.writeClaudeConfig(
            servers: mcpServers,
            taskID: context.taskSnapshot.id,
            availableEnvironment: explicitMCPEnvironment,
            allowEmpty: true
        )
        let mcpConfigReadablePaths = mcpConfigURL.map { [$0.deletingLastPathComponent().path] } ?? []
        let baseSandboxReadablePaths = mcpConfigReadablePaths + ClaudeCodeRuntime.authReadablePaths()
        let mcpAllowedTools = mcpConfigURL == nil ? [] : MCPRuntimeProjection.allowedToolPermissions(
            servers: mcpServers,
            availableEnvironment: explicitMCPEnvironment
        )
        let mcpDeniedTools = mcpConfigURL == nil ? [] : MCPRuntimeProjection.deniedToolPermissions(
            servers: mcpServers,
            availableEnvironment: explicitMCPEnvironment
        )
        let deniesNativeShellForHostControl = HostControlPlaneMCPProjection.requiresNativeShellDenial(
            task: context.task,
            environment: executionEnvironment,
            permissionPolicy: effectivePermissionPolicy,
            contextText: context.contextText,
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            precomputedRuntimeRequirements: context.runtimeRequirements
        )
        let nativeDeniedTools = Array(Set(mcpDeniedTools + (deniesNativeShellForHostControl ? ["Bash"] : []))).sorted()
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
        var processEnvironment = AgentRuntimeProcessRunner.environment(
            phase: context.phase,
            task: context.task,
            taskEnv: taskEnv,
            includeClaudeTeamFlag: true
        )
        for (key, value) in workspaceExecutorEnvironment {
            processEnvironment[key] = value
        }
        for (key, value) in hostControlEnvironment {
            processEnvironment[key] = value
        }
        let vertexADCReadablePaths = ClaudeCodeRuntime.vertexADCReadablePaths(
            isVertexEnabled: processEnvironment["CLAUDE_CODE_USE_VERTEX"] == "1"
        )
        let sandboxReadablePaths = baseSandboxReadablePaths + vertexADCReadablePaths
        let model = AgentRuntimeProcessRunner.model(context.taskSnapshot.model, for: id)
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
        args += context.requiredProviderPolicyRender(for: id).claudeLaunchPermissionArguments()
        AgentRuntimeProcessRunner.ensureSubAgentPermissions(
            at: context.workspacePath,
            policy: effectivePermissionPolicy,
            allowedTools: nativeAllowedTools
        )
        if context.taskSnapshot.maxTurns > 0 {
            args += ["--max-turns", String(context.taskSnapshot.maxTurns)]
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
                "phase": context.phase.rawValue,
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
                "host_control_plane_tool_count": String(HostControlPlaneMCPProjection.toolNames.count),
                "host_control_plane_supported": String(!usesDockerWorkspaceExecutor || mcpAllowedTools.contains(HostControlPlaneMCPProjection.providerToolPermission(for: "gcloud"))),
                "host_control_plane_mcp_env_key_count": String(hostControlEnvironment.count),
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
                "max_turns": String(context.taskSnapshot.maxTurns),
                "supports_native_continuation": String(descriptor.supportsNativeContinuation),
                "uses_native_continuation": String(context.nativeContinuationSessionID != nil),
                "native_session_prefix": context.nativeContinuationSessionID.map { String($0.prefix(8)) } ?? "none",
                "uses_live_approvals": String(interactiveAsk != nil),
                "mcp_server_count": String(mcpConfigURL == nil ? 0 : mcpServers.count),
                "mcp_config_rendered": String(mcpConfigURL != nil),
                "native_denied_tool_count": String(nativeDeniedTools.count),
                "native_denied_tool_names": nativeDeniedTools.joined(separator: ","),
                "claude_vertex_adc_readable": String(!vertexADCReadablePaths.isEmpty)
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
        let agentEvents = StreamEventParser.parseAll(line: line).flatMap(AgentEventRecorder.agentEvents(from:))
        return AgentRuntimeStreamEventBatch(agentEvents: agentEvents)
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
        mode: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        guard case .agent(let agentEvent) = event else { return }
        AgentEventRecorder.recordClaudeEvent(
            agentEvent,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingMode: mode,
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
            ? RuntimePathResolver.detectClaudePath()
            : configuredPath
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
        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: executable,
            arguments: args,
            currentDirectory: workspacePath,
            environment: claudeUtilityEnvironment(),
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: false
        )
        return await AgentRuntimeProcessRunner().runUtilityProcess(
            AgentUtilityLaunchPlan(
                process: plan,
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                timeoutSeconds: configuration.timeoutSeconds
            )
        )
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
        supportsAstraRunProtocol: true,
        supportsMCPServers: true
    )
    let readinessCheckID = "copilot-cli"
    let availableModelsStorageKey = AppStorageKeys.copilotAvailableModels
    let modelsCheckedAtStorageKey = AppStorageKeys.copilotModelsCheckedAt
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .copilotCLI, launchOverheadTokens: 0)
    let recordsStreamTelemetry = true
    let recordsInferredFileChanges = true
    let providerRuntimeMessages = ProviderRuntimeMessages.copilot

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? CopilotCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func connectorPreflightContextText(
        task _: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage: String?,
        phase _: RunPhase
    ) -> String {
        sessionMessage ?? promptOverride ?? startPayload
    }

    func shouldPrepareIsolation(phase _: RunPhase) -> Bool {
        true
    }

    func policyCapabilities(executablePath: String) -> AgentRuntimePolicyCapabilities {
        AgentRuntimePolicyCapabilities(copilotCLI: CopilotCLIRuntime.capabilities(executablePath: executablePath))
    }

    func shouldValidateSuccessfulRun(phase _: RunPhase) -> Bool {
        true
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: RunPhase
    ) -> String {
        providerRuntimeMessages.sessionTurnMessage(task: task, promptOverride: promptOverride, startPayload: startPayload)
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
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            contextText: context.contextText,
            executionPolicy: context.executionPolicy
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let capabilityScope = context.capabilityResolutionSnapshot.providerLaunch
        let allowed = context.executionPolicy.allowedTools(
            default: capabilityScope.resolver.resolvedProviderAllowedTools
        )
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let usesDockerWorkspaceExecutor = DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)
        let providerLaunchPermissionPolicy = AgentRuntimeProviderLaunchPolicy.permissionPolicy(
            runtime: id,
            effectivePermissionPolicy: effectivePermissionPolicy,
            executionEnvironment: executionEnvironment
        )
        let baseProviderAllowed = AgentRuntimeProcessRunner.providerAllowedTools(
            for: id,
            baseAllowedTools: allowed,
            permissionManifest: context.permissionManifest
        )
        let runtimeSupportTools = AgentRuntimeProcessRunner.providerRuntimeSupportToolPermissions(
            for: id,
            permissionManifest: context.permissionManifest
        )
        let baseAskFirstTools = context.permissionManifest?.providerRender.askFirstTools ?? []
        let pathPrefix = AgentRuntimeProcessRunner.pathPrefix(for: context.task, taskEnv: taskEnv)
        let executable = context.executablePath.isEmpty ? CopilotCLIRuntime.detectPath() : context.executablePath
        let providerVersion = CopilotCLIRuntime.versionSummary(executablePath: executable)
        let capabilities = CopilotCLIRuntime.capabilities(executablePath: executable)
        let model = AgentRuntimeProcessRunner.model(context.taskSnapshot.model, for: id)
        let additionalPaths = AgentRuntimeProcessRunner.copilotAdditionalPaths(for: context.task)
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let copilotStateHome = CopilotCLIRuntime.defaultHome(userHome: userHome)
        let mcpProjection = CopilotMCPLaunchProjection.resolve(
            task: context.task,
            workspacePath: context.workspacePath,
            runID: context.runID,
            executionEnvironment: executionEnvironment,
            contextText: context.contextText,
            taskEnvironment: taskEnv,
            capabilities: capabilities,
            runtimeRequirements: context.runtimeRequirements
        )
        let hostControlTools = HostControlPlaneRuntimeLaunchGuard.requiredTools(from: mcpProjection.hostControlEnvironment)
        let deniesNativeShellForHostControl = HostControlPlaneMCPProjection.requiresNativeShellDenial(
            environment: executionEnvironment,
            permissionPolicy: providerLaunchPermissionPolicy,
            requiredTools: hostControlTools
        )
        let providerAllowed = deniesNativeShellForHostControl
            ? DockerWorkspaceMCPProjection.removingNativeShellTools(baseProviderAllowed)
            : baseProviderAllowed
        let askFirstTools = deniesNativeShellForHostControl
            ? DockerWorkspaceMCPProjection.removingNativeShellTools(baseAskFirstTools)
            : baseAskFirstTools
        let artifactBootstrapTools = ProviderArtifactBootstrapPolicy.persistedLaunchTools(
            task: context.task,
            permissionPolicy: providerLaunchPermissionPolicy,
            providerAllowedTools: providerAllowed,
            askFirstTools: askFirstTools
        )
        let browserBridgeMetadata = BrowserBridgeRuntimeLaunchGuard.planMetadata(
            runtime: id,
            environment: taskEnv,
            mcpToolSupported: mcpProjection.browserBridgeMCPToolSupported
        )
        var localToolCommands = AgentRuntimeProcessRunner.copilotLocalToolCommands(for: context.task, contextText: context.contextText)
        if deniesNativeShellForHostControl {
            localToolCommands = HostControlPlaneRuntimeLaunchGuard.removingNativeLocalToolCommands(
                localToolCommands,
                requiredTools: hostControlTools
            )
        }
        if browserBridgeMetadata.isAttached && !mcpProjection.browserBridgeMCPToolSupported {
            localToolCommands.append("astra-browser")
        }
        let surfacedAskFirstTools = askFirstTools
        let providerLaunchAllowed = Array(Set(providerAllowed + artifactBootstrapTools + mcpProjection.allowedTools)).sorted()
        var launchTaskEnv = taskEnv
        for (key, value) in mcpProjection.workspaceExecutorEnvironment {
            launchTaskEnv[key] = value
        }
        for (key, value) in mcpProjection.hostControlEnvironment {
            launchTaskEnv[key] = value
        }
        let permissionArguments = context.requiredProviderPolicyRender(for: id).copilotLaunchPermissionArguments()
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: context.prompt,
            model: model,
            workspacePath: context.workspacePath,
            additionalPaths: additionalPaths,
            permissionPolicy: providerLaunchPermissionPolicy,
            allowedTools: providerLaunchAllowed,
            timeoutSeconds: context.timeoutSeconds,
            capabilities: capabilities,
            taskEnvironment: launchTaskEnv,
            copilotHome: context.providerHomeDirectory,
            copilotStateHome: copilotStateHome,
            userHome: userHome,
            pathPrefix: pathPrefix,
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(context.task, contextText: context.contextText)
                || browserBridgeMetadata.isAttached,
            localToolCommands: localToolCommands,
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: surfacedAskFirstTools,
            additionalMCPConfigPaths: mcpProjection.configURL.map { [$0.path] } ?? [],
            reasoningEffort: artifactBootstrapTools.isEmpty ? nil : "none",
            permissionArguments: permissionArguments
        )
        let directoriesToCreate = CopilotCLIRuntime.directoriesToCreate(
            copilotHome: context.providerHomeDirectory,
            copilotStateHome: copilotStateHome,
            userHome: userHome
        )
        let sandboxReadablePaths = CopilotCLIRuntime.authReadablePaths(userHome: userHome) + mcpProjection.readablePaths
        let providerDetectedFields = CopilotLaunchDiagnostics.providerDetectedFields(
            id: id,
            providerVersion: providerVersion,
            executable: executable,
            executableConfigured: !context.executablePath.isEmpty
        )
        let dockerContainerEnvCount = DockerExecutionPlanner
            .credentialProjectionEnvironment(environment: executionEnvironment)
            .count
        let artifactBootstrapToolNames = Set(artifactBootstrapTools.map {
            ProviderArtifactBootstrapPolicy.normalizedToolName($0)
        })
        let taskProviderAllowed = providerAllowed.filter { tool in
            !artifactBootstrapToolNames.contains(ProviderArtifactBootstrapPolicy.normalizedToolName(tool))
        }
        let commandPlannedFields = CopilotLaunchDiagnostics.commandPlannedFields(
            id: id,
            phase: context.phase,
            model: model,
            plan: plan,
            capabilities: capabilities,
            effectivePermissionPolicy: providerLaunchPermissionPolicy,
            providerAllowed: taskProviderAllowed,
            baseProviderAllowed: baseProviderAllowed,
            providerLaunchAllowed: providerLaunchAllowed,
            runtimeSupportTools: runtimeSupportTools,
            baseAskFirstTools: baseAskFirstTools,
            surfacedAskFirstTools: surfacedAskFirstTools,
            artifactBootstrapTools: artifactBootstrapTools,
            allowedToolsOverride: context.executionPolicy.allowedToolsOverride != nil,
            localToolCommands: localToolCommands,
            additionalPaths: additionalPaths,
            taskEnv: launchTaskEnv,
            usesDockerWorkspaceExecutor: usesDockerWorkspaceExecutor,
            mcpProjection: mcpProjection,
            dockerContainerEnvCount: dockerContainerEnvCount,
            dockerCredentialProjectionCount: executionEnvironment.effectiveCredentialProjections.count,
            browserBridgeMetadata: browserBridgeMetadata
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
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: sandboxReadablePaths,
            sandboxProtectedWriteDenyPaths: CopilotCLIRuntime.configWriteDenyPaths(userHome: userHome),
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: commandPlannedFields
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
        let executable = configuredPath.isEmpty ? CopilotCLIRuntime.detectPath() : configuredPath
        let configuredHome = configuration.homeDirectory(for: id)
        let copilotHome = configuredHome.isEmpty ? CopilotCLIRuntime.channelHome() : configuredHome
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
            disableCustomInstructions: true,
            permissionArguments: ProviderPolicyRender.copilotUtilityLaunchPermissionArguments(
                allowedTools: allowedTools,
                capabilities: capabilities
            )
        )

        let processPlan = AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: workspacePath,
            environment: plan.environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: CopilotCLIRuntime.directoriesToCreate(
                copilotHome: copilotHome,
                copilotStateHome: copilotStateHome,
                userHome: userHome
            ),
            sandboxReadablePaths: CopilotCLIRuntime.authReadablePaths(userHome: userHome),
            sandboxProtectedWriteDenyPaths: CopilotCLIRuntime.configWriteDenyPaths(userHome: userHome)
        )
        let utilityPlan = AgentUtilityLaunchPlan(
            process: processPlan,
            providerHomeDirectory: copilotHome,
            permissionPolicy: .restricted,
            timeoutSeconds: configuration.timeoutSeconds
        )
        if plan.parsesJSONLines {
            return await runStreamingCopilotUtilityPrompt(utilityPlan)
        }

        return await AgentRuntimeProcessRunner().runUtilityProcess(utilityPlan)
    }

    private func runStreamingCopilotUtilityPrompt(
        _ utilityPlan: AgentUtilityLaunchPlan
    ) async -> AgentUtilityRunResult {
        let state = CopilotUtilityStreamRunState()
        return await AgentRuntimeProcessRunner().runUtilityProcess(
            utilityPlan,
            stdoutLineHandler: { line in
                state.appendStdoutLineAndCompleteIfReady(line)
            },
            stderrChunkHandler: { chunk in
                state.appendStderr(chunk)
            },
            completion: { exitCode, _, _ in
                state.completeWithProcessExit(exitCode: exitCode)
                    ?? AgentUtilityRunResult(exitCode: exitCode, output: "", error: "")
            },
            launchError: { message in
                state.completeWithLaunchError(message)
                    ?? AgentUtilityRunResult(exitCode: -1, output: "", error: message)
            },
            timeoutResult: { timeoutSeconds in
                state.completeWithTimeout(timeoutSeconds: timeoutSeconds)
                    ?? AgentUtilityRunResult(exitCode: -1, output: "", error: "Process timed out.")
            }
        )
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
        phase: RunPhase,
        exitCode: Int
    ) {
        AgentRuntimeStreamDiagnostics.logCopilotStreamTelemetry(
            snapshot: snapshot,
            task: task,
            run: run,
            phase: phase.rawValue,
            exitCode: exitCode
        )
    }

}

private final class CopilotUtilityStreamRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var rawOutput = ""
    private var outputPieces: [String] = []
    private var completionSummary: String?
    private var terminalSummary: String?
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
                if let summary = CopilotUtilityOutputRendering.nonEmptyText(summary),
                   CopilotUtilityOutputRendering.isFinalAssistantMessageLine(line) {
                    completionSummary = summary
                } else if let summary = CopilotUtilityOutputRendering.nonEmptyText(summary) {
                    terminalSummary = summary
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
        if let completionSummary {
            return completionSummary
        }
        let parsed = outputPieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !parsed.isEmpty {
            return parsed
        }
        if let terminalSummary {
            return terminalSummary
        }
        return rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTerminalLine(_ line: String) -> Bool {
        CopilotUtilityOutputRendering.isTerminalLine(line)
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
    let providerRuntimeMessages = ProviderRuntimeMessages.antigravity

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

    func connectorPreflightContextText(
        task _: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage: String?,
        phase _: RunPhase
    ) -> String {
        sessionMessage ?? promptOverride ?? startPayload
    }

    func shouldPrepareIsolation(phase _: RunPhase) -> Bool {
        true
    }

    func shouldValidateSuccessfulRun(phase _: RunPhase) -> Bool {
        true
    }

    func requiresVisibleResultForSuccessfulRun(phase _: RunPhase) -> Bool {
        true
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: RunPhase
    ) -> String {
        providerRuntimeMessages.sessionTurnMessage(task: task, promptOverride: promptOverride, startPayload: startPayload)
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
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            contextText: context.contextText,
            executionPolicy: context.executionPolicy
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
        // Antigravity is the only adapter with a non-nil `sharedLaunchStateKey`, so this is the
        // only `makeProcessLaunchPlan` that can run after an unbounded await on
        // `AgentRuntimeSharedStateGate` (queued behind another task sharing the same provider
        // home directory). Reading the live `context.task.model` here (rather than
        // `context.taskSnapshot.model`, captured before that wait) ensures a model edit made
        // while this launch was queued is still honored when writing the shared settings file.
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let providerModel = AntigravityCLIRuntime.resolvedModelName(model, settingsURL: modelSettingsURL)
        let modelApplied = FileManager.default.isExecutableFile(atPath: executable)
            ? AntigravityCLIRuntime.applySelectedModel(providerModel, settingsURL: modelSettingsURL)
            : false
        let diagnosticLogPath = context.runID.flatMap {
            AntigravityCLIRuntime.diagnosticLogPath(task: context.task, runID: $0)
        }
        let additionalPaths = AgentRuntimeProcessRunner.runtimeWritablePaths(for: context.task)
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let hostControlTools = HostControlPlaneMCPProjection.enabledToolNames(
            task: context.task,
            environment: executionEnvironment,
            contextText: context.contextText,
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            precomputedRuntimeRequirements: context.runtimeRequirements
        )
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
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(
                context.task,
                contextText: context.contextText,
                capabilityScope: context.capabilityResolutionSnapshot.providerLaunch
            )
                || taskEnv["ASTRA_BROWSER_URL"] != nil,
            diagnosticLogPath: diagnosticLogPath,
            permissionArguments: context.requiredProviderPolicyRender(for: id).antigravityLaunchPermissionArguments()
        )
        var commandPlannedFields = [
            "runtime": id.rawValue,
            "phase": context.phase.rawValue,
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
        commandPlannedFields.merge(
            HostControlPlaneRuntimeLaunchGuard.planMetadata(runtime: id, requiredTools: hostControlTools),
            uniquingKeysWith: { current, _ in current }
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
            sandboxReadablePaths: AntigravityCLIRuntime.authReadablePaths(),
            providerDetectedFields: [
                "runtime": id.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
                "executable_path": executable,
                "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(executable),
                "provider_home_configured": String(!context.providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ],
            commandPlannedFields: commandPlannedFields
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
        let providerHomeDirectory = configuration.homeDirectory(for: id)
        let modelSettingsURL = AntigravityCLIRuntime.settingsURL(
            providerHomeDirectory: providerHomeDirectory
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
            providerHomeDirectory: providerHomeDirectory,
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted)
        )

        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let processPlan = AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: workspacePath,
            environment: plan.environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: trimmedHome.isEmpty ? [] : [trimmedHome],
            sandboxReadablePaths: AntigravityCLIRuntime.authReadablePaths()
        )
        let result = await AgentRuntimeProcessRunner().runUtilityProcess(
            AgentUtilityLaunchPlan(
                process: processPlan,
                providerHomeDirectory: providerHomeDirectory,
                permissionPolicy: .restricted,
                timeoutSeconds: configuration.timeoutSeconds
            )
        )
        await AgentRuntimeSharedStateGate.shared.release(sharedStateKey)
        return result
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
