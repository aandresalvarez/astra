import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct AgentRuntimeBudgetProfile: Sendable, Equatable {
    let runtime: AgentRuntimeID
    let launchOverheadTokens: Int

    func estimatedLaunchInputTokens(prompt: String) -> Int {
        AgentProcessMonitor.estimatedTokenCount(for: prompt) + launchOverheadTokens
    }

    static func profile(for runtime: AgentRuntimeID) -> AgentRuntimeBudgetProfile {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).budgetProfile
    }
}

protocol AgentRuntimeProcessRunning: AnyObject {
    func cancel()
    func isHostControlBrokerAvailable() -> Bool
    @MainActor func configureSupervision(_ context: RuntimeSupervisionContext?)
    @MainActor func configureExecutionOwner(_ owner: RuntimeExecutionOwner?)

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        phase: RunPhase,
        contextText: String,
        nativeContinuationSessionID: String?,
        runID: UUID?,
        launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?,
        runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult
}

extension AgentRuntimeProcessRunning {
    @MainActor func configureExecutionOwner(_ owner: RuntimeExecutionOwner?) {}
    @MainActor func configureSupervision(_ context: RuntimeSupervisionContext?) {}
}

final class AgentRuntimeProcessRunner {
    typealias SandboxSettingsProvider = @MainActor (PermissionPolicy) -> ExecutionSandboxSettings
    typealias GitCredentialContextProvider = @MainActor (AgentRuntimeProcessLaunchContext) -> GitCredentialSandboxContext
    typealias DockerRuntimeProvider = @Sendable () -> DockerRuntimeResolution?

    private var executionOwner: RuntimeExecutionOwner?
    @MainActor func configureExecutionOwner(_ owner: RuntimeExecutionOwner?) {
        let previous = executionOwner
        executionOwner = owner
        if owner == nil, let previous, let lease = sharedStateLease,
           sharedStateOwnerID == previous.record.ownerID {
            // Runs after the worker's synchronous finish/cleanup defers.
            Task { @MainActor in
                guard previous.persistedResourceRelease else { return }
                await AgentRuntimeSharedStateGate.shared.release(lease)
                if self.sharedStateLease == lease { self.sharedStateLease = nil }
            }
        }
    }
    private var currentProcess: AgentRuntimeProcessControl?
    /// Held until normal return or verified cancellation cleanup.
    private var sharedStateLease: AgentRuntimeSharedStateLease?
    private var sharedStateOwnerID: UUID?
    private var supervisionContext: RuntimeSupervisionContext?
    private var activeSupervision: RuntimeSupervisionSession?
    private var activeRecovery: RuntimeRecoverySession?
    private var supervisionPreparation: Task<RuntimeSupervisionFiles, Never>?
    @MainActor func configureSupervision(_ context: RuntimeSupervisionContext?) { supervisionContext = context }
    let homeAccessCancellation = RuntimeHomeAccessCancellationGate()
    private let sandboxSettingsProvider: SandboxSettingsProvider
    private let gitCredentialContextProvider: GitCredentialContextProvider
    private let dockerRuntimeProvider: DockerRuntimeProvider
    private let hostControlBrokerSessionManager: any HostControlBrokerSessionManaging

    init(
        sandboxSettingsProvider: @escaping SandboxSettingsProvider = { permissionPolicy in
            ExecutionSandboxSettings.current(permissionPolicy: permissionPolicy)
        },
        gitCredentialContextProvider: @escaping GitCredentialContextProvider = { context in
            GitCredentialContextResolver.runtimeSandboxContext(
                prompt: context.prompt,
                task: context.task,
                contextText: context.contextText,
                repositoryPath: context.workspacePath,
            )
        },
        dockerRuntimeProvider: @escaping DockerRuntimeProvider = {
            DockerRuntimeResolver.resolve()
        },
        hostControlBrokerSessionManager: any HostControlBrokerSessionManaging = HostControlBrokerSessionManager()
    ) {
        self.sandboxSettingsProvider = sandboxSettingsProvider
        self.gitCredentialContextProvider = gitCredentialContextProvider
        self.dockerRuntimeProvider = dockerRuntimeProvider
        self.hostControlBrokerSessionManager = hostControlBrokerSessionManager
    }

    func cancel() {
        activeRecovery?.finish()
        supervisionPreparation?.cancel()
        activeSupervision?.finish()
        homeAccessCancellation.invalidate()
        currentProcess?.terminate()
        currentProcess = nil
    }

    func isHostControlBrokerAvailable() -> Bool {
        hostControlBrokerSessionManager.isAvailable()
    }

    /// Either a launch plan ready to run, or a fail-closed result that blocks the
    /// run (strict sandbox enforcement when the sandbox cannot be applied).
    enum SandboxedPlanOutcome {
        case plan(AgentRuntimeProcessLaunchPlan)
        case blocked(AgentProcessResult)
    }

    /// Pure mapping from a sandbox decision to a launch outcome. Extracted from
    /// `sandboxedPlan` so the security-critical branch — `failClosed` MUST block
    /// the run and never fall through to running unconfined — is unit-testable
    /// without spawning a process or constructing a full adapter. A regression
    /// that turned `.failClosed` into `.plan` would otherwise run the provider
    /// unconfined under strict/autonomous with no test to catch it.
    static func sandboxOutcome(
        for decision: ExecutionSandboxDecision,
        originalPlan: AgentRuntimeProcessLaunchPlan,
        enforcement: ExecutionSandboxEnforcement = .strict,
        isUtility: Bool = false
    ) -> SandboxedPlanOutcome {
        switch decision {
        case .applied(let wrapped, _):
            return .plan(wrapped)
        case .skipped, .fallback:
            return .plan(originalPlan)
        case .failClosed(let reason):
            // The way out depends on why the sandbox failed and on what the user can
            // change. A narrower workspace helps only the path reasons; a missing
            // sandbox-exec needs it restored. Strict blocks every runtime, so Auto
            // would not unblock it; utility runs use a fixed restricted policy, so
            // Auto never helps there either. Below strict, turning the sandbox off
            // is always an option. See `ExecutionSandboxSettings.failClosedRuntimes`.
            var options = [reason == "sandbox_exec_missing"
                ? "Restore /usr/bin/sandbox-exec"
                : "Use a narrower workspace folder"]
            if enforcement == .strict {
                options.append("change the sandbox enforcement in Settings")
            } else {
                if !isUtility { options.append("switch to Auto to run without it") }
                options.append("turn the execution sandbox off in Settings")
            }
            let intro = enforcement == .strict
                ? "ASTRA could not apply the macOS execution sandbox (\(reason)) and strict enforcement is enabled, so the run was blocked."
                : "ASTRA could not apply the macOS execution sandbox (\(reason)), which this run depends on\(isUtility ? "" : " below Auto"), so it was blocked."
            let message = "\(intro) \(options.joined(separator: ", or "))."
            return .blocked(AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "sandbox_unavailable",
                runtimeStopMessage: message
            ))
        }
    }

    /// Builds the launch plan and applies the macOS execution sandbox to it.
    /// Returns the (possibly wrapped) plan, or — under strict enforcement when
    /// the sandbox cannot be applied — a fail-closed `AgentProcessResult` so the
    /// run never proceeds unconfined. All decisions are audited.
    /// Internal (not private) so the sandbox wiring — decision, auditing, and the
    /// fail-closed translation — is unit-testable with a fake adapter without
    /// spawning a process.
    @MainActor
    func sandboxedPlan(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        context: AgentRuntimeProcessLaunchContext
    ) -> SandboxedPlanOutcome {
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicyOverride ?? context.permissionPolicy
        // In the primary launch path (AgentRuntimeWorker), context.launchResourcePlan
        // is always already computed, so this fallback rarely runs in production —
        // but any direct caller of runRuntimeProcess/sandboxedPlan (tests, or a
        // future secondary launch path) that omits it lands here. The precomputed
        // requirements and capability profile are passed for the same reason
        // AgentRuntimeWorker passes them at its own call site: without them this
        // fallback re-derives GitHub host-control routing, and what transport the
        // runtime has, from second captures instead of the launch's single answers.
        // See Tests/HostControlRequirementDerivationConsistencyTests.swift.
        let launchResourcePlan = context.launchResourcePlan ?? TaskLaunchResourceResolver.resolve(
            task: context.task,
            runID: context.runID,
            runtime: adapter.id,
            phase: context.phase,
            prompt: context.prompt,
            contextText: context.contextText,
            workspacePath: context.workspacePath,
            capabilityResolutionSnapshot: context.capabilityResolutionSnapshot,
            runtimePermissionGrants: context.executionPolicy.permissionGrantsOverride ?? [],
            permissionPolicy: effectivePermissionPolicy,
            gitCredentialContextProvider: { [gitCredentialContextProvider] _, _, _, _ in
                gitCredentialContextProvider(context)
            },
            precomputedRuntimeRequirements: context.runtimeRequirements,
            runtimeCapabilityProfile: context.executionPolicy.runtimeCapabilityProfile
        )
        if let diagnostic = launchResourcePlan.diagnostics.first(where: { $0.severity == .error }) {
            let message = "ASTRA could not prepare a required launch dependency: \(diagnostic.message)"
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": adapter.id.rawValue,
                "reason": "launch_resource_unresolved",
                "diagnostic_code": diagnostic.code
            ], level: .error)
            return .blocked(AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "launch_resource_unresolved",
                runtimeStopMessage: message
            ))
        }
        let resolvedContext = context.replacingLaunchResourcePlan(launchResourcePlan)
        var plan = adapter.makeProcessLaunchPlan(context: resolvedContext)
        // Immediately, before anything else reads `plan.environment`. Each
        // adapter builds its environment from `ProcessInfo`, so the brokered
        // strip its overlay went through does not cover a credential ASTRA was
        // itself launched with.
        plan = plan.strippingBrokeredConnectorEnvironment(
            capabilityScope: resolvedContext.capabilityResolutionSnapshot.providerLaunch
        )
        let environment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let readOnlyInputBoundary = ReadOnlyInputEnforcementBoundary(
            contract: launchResourcePlan.readOnlyResourceContract,
            executionEnvironment: environment
        )
        if readOnlyInputBoundary.isRequired, !readOnlyInputBoundary.contract.isValid {
            let reason = readOnlyInputBoundary.contract.failures
                .map(\.description)
                .joined(separator: ",")
            let result = readOnlyInputBoundary.unavailableResult(
                reason: reason.isEmpty ? "read_only_resource_contract_invalid" : reason
            )
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": result.runtimeStopReason ?? "read_only_input_boundary_unavailable",
                "contract_failure_count": String(readOnlyInputBoundary.contract.failures.count)
            ], level: .error)
            return .blocked(result)
        }
        let gitCredentialContext = launchResourcePlan.gitCredentialSandboxContext
        plan = plan.addingSandboxReadablePaths(
            launchResourcePlan.hostReadablePaths,
            plannedFields: launchResourcePlan.commandPlannedFields.merging([
                "read_only_input_boundary_required": String(readOnlyInputBoundary.isRequired),
                "read_only_input_boundary_mode": readOnlyInputBoundary.mode.rawValue,
                "read_only_input_boundary_path_count": String(readOnlyInputBoundary.paths.count)
            ]) { current, _ in current }
        )
        plan = plan.addingSandboxProtectedWriteDenyPaths(launchResourcePlan.hostProtectedWriteDenyPaths)
        if !gitCredentialContext.isEmpty {
            plan = plan.addingGitCredentialContext(gitCredentialContext)
        }
        if let block = plan.unsupportedProviderNativeCredentialReadBlock(
            for: launchResourcePlan,
            permissionPolicy: effectivePermissionPolicy,
            workspaceCommandsRunInsideManagedExecutor: environment.workspaceCommandsRunInsideContainer
        ) {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": block.runtimeStopReason ?? "credential_native_access_unavailable",
                "git_credential_readable_path_count": String(gitCredentialContext.readablePaths.count),
                "git_credential_writable_path_count": String(gitCredentialContext.writablePaths.count),
                "git_credential_transports": gitCredentialContext.transports.map(\.rawValue).joined(separator: ","),
                "provider_native_credential_read_path_count": String(launchResourcePlan.providerNativeCredentialReadablePaths.count)
            ], level: .error)
            return .blocked(block)
        }
        if let block = plan.unsupportedProviderNativeReadOnlyFileBlock(
            permissionPolicy: effectivePermissionPolicy,
            workspaceCommandsRunInsideManagedExecutor: environment.workspaceCommandsRunInsideContainer
        ) {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": block.runtimeStopReason ?? "provider_native_file_read_unavailable",
                "unreachable_file_count": plan.commandPlannedFields["provider_native_unreachable_read_only_file_count"] ?? "0"
            ], level: .error)
            return .blocked(block)
        }
        if environment.workspaceCommandsRunInsideContainer,
           (!DockerWorkspaceMCPProjection.supportsHostProviderWorkspaceExecutor(
                runtime: plan.runtime,
                executablePath: plan.executablePath
            )
            || plan.commandPlannedFields["docker_workspace_executor_supported"] == "false") {
            let detail = plan.commandPlannedFields["docker_workspace_executor_unsupported_detail"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail?.isEmpty == false
                ? detail!
                : "\(plan.runtime.displayName) cannot yet route workspace shell commands through ASTRA's Docker executor. Switch this task to Claude Code or choose Host execution, then retry."
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": "docker_workspace_executor_unsupported_runtime",
                "execution_environment": environment.kind.rawValue,
                "provider_placement": environment.effectiveProviderPlacement.rawValue,
                "detail": detail ?? ""
            ], level: .error)
            return .blocked(AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "docker_workspace_executor_unsupported_runtime",
                runtimeStopMessage: message
            ))
        }
        let dockerRuntime = environment.isContainerized ? dockerRuntimeProvider() : .environmentLookup
        guard let dockerRuntime else {
            let message = "Docker CLI was not found. Install or reopen Docker Desktop, then retry."
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": "docker_cli_missing",
                "execution_environment": environment.kind.rawValue
            ], level: .error)
            return .blocked(AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "docker_cli_missing",
                runtimeStopMessage: message
            ))
        }
        if environment.workspaceCommandsRunInsideContainer,
           !environment.providerRunsInsideContainer {
            let dockerToolDirectory = URL(fileURLWithPath: dockerRuntime.executablePath)
                .deletingLastPathComponent()
                .path
            var dockerReadablePaths = [dockerToolDirectory]
            // Docker Desktop's system-wide CLI is often a symlink (e.g.
            // /usr/local/bin/docker) into the protected app bundle. Granting
            // only the symlink's own directory lets the sandbox read the link
            // itself but denies exec traversal into its real target, so the
            // resolved target's directory must be granted too.
            let resolvedExecutablePath = (dockerRuntime.executablePath as NSString).resolvingSymlinksInPath
            if resolvedExecutablePath != dockerRuntime.executablePath {
                let resolvedToolDirectory = URL(fileURLWithPath: resolvedExecutablePath)
                    .deletingLastPathComponent()
                    .path
                if resolvedToolDirectory != dockerToolDirectory {
                    dockerReadablePaths.append(resolvedToolDirectory)
                }
            }
            plan = plan.addingSandboxReadablePaths(
                dockerReadablePaths,
                plannedFields: ["docker_host_tool_readable_path": dockerToolDirectory]
            )
        }
        switch DockerExecutionPlanner.plan(
            base: plan,
            environment: environment,
            task: context.task,
            runID: context.runID,
            workspaceAccess: launchResourcePlan.workspaceAccess,
            additionalReadOnlyInputPaths: readOnlyInputBoundary.paths,
            dockerRuntime: dockerRuntime
        ) {
        case .success(let resolvedPlan):
            plan = resolvedPlan
        case .failure(let error):
            let message = error.localizedDescription
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": "execution_environment_unavailable",
                "execution_environment": environment.kind.rawValue,
                "detail": message
            ], level: .error)
            return .blocked(AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "execution_environment_unavailable",
                runtimeStopMessage: message
            ))
        }
        var appliedBoundarySurfaces: Set<ReadOnlyBoundarySurface> = []
        if readOnlyInputBoundary.requiresContainerReadOnlyMounts {
            let unprotectedPaths = readOnlyInputBoundary.unprotectedContainerPaths(
                in: plan.executionEnvironment.mounts
            )
            guard unprotectedPaths.isEmpty else {
                let result = readOnlyInputBoundary.unavailableResult(
                    reason: "container_read_only_mount_missing"
                )
                AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                    "runtime": plan.runtime.rawValue,
                    "reason": result.runtimeStopReason ?? "read_only_input_boundary_unavailable",
                    "execution_environment": plan.executionEnvironment.kind.rawValue,
                    "unprotected_path_count": String(unprotectedPaths.count)
                ], level: .error)
                return .blocked(result)
            }
            if readOnlyInputBoundary.requiredSurfaces.contains(.providerContainer) {
                appliedBoundarySurfaces.insert(.providerContainer)
            }
            if readOnlyInputBoundary.requiredSurfaces.contains(.workspaceContainer) {
                appliedBoundarySurfaces.insert(.workspaceContainer)
            }
        }
        if let block = HostControlPlaneRuntimeLaunchGuard.launchBlock(for: plan) {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": block.runtimeStopReason ?? HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason,
                "source": "runtime_launch_preflight"
            ], level: .error)
            return .blocked(block)
        }
        if let block = BrowserBridgeRuntimeLaunchGuard.launchBlock(for: plan) {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": block.runtimeStopReason ?? BrowserBridgeRuntimeLaunchGuard.missingBrowserControlToolReason,
                "source": "runtime_launch_preflight",
                "has_browser_bridge": "true"
            ], level: .error)
            return .blocked(block)
        }
        // Launch and preflight evidence resolve the same admission-time setting,
        // including autonomous runtimes that bypass their provider sandbox.
        let baseSettings = sandboxSettingsProvider(effectivePermissionPolicy)
            .applyingAdmissionSnapshot(
                context.executionPolicy.sandboxEnforcementSnapshot,
                permissionPolicy: effectivePermissionPolicy
            )
        let settings = readOnlyInputBoundary.enforcingHostBoundary(
            in: baseSettings,
            runtime: plan.runtime
        ).enforcingSharedWorkspaceBoundary(
            required: launchResourcePlan.requiresSharedWorkspaceBoundary,
            runtime: plan.runtime
        )
        if plan.executionEnvironment.providerRunsInsideContainer {
            AppLogger.audit(.sandboxSkipped, category: "Worker", taskID: context.taskSnapshot.id, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": "container_environment_uses_docker_policy",
                "execution_environment": plan.executionEnvironment.kind.rawValue,
                "provider_placement": plan.executionEnvironment.effectiveProviderPlacement.rawValue,
                "read_only_input_boundary_mode": readOnlyInputBoundary.mode.rawValue,
                "read_only_input_boundary_path_count": String(readOnlyInputBoundary.paths.count)
            ], level: .debug)
            if readOnlyInputBoundary.isRequired {
                guard let receipt = readOnlyInputBoundary.receipt(
                    appliedSurfaces: appliedBoundarySurfaces,
                    mounts: plan.executionEnvironment.mounts
                ) else {
                    return .blocked(readOnlyInputBoundary.unavailableResult(reason: "boundary_receipt_incomplete"))
                }
                plan.readOnlyBoundaryReceipt = receipt
            }
            return .plan(plan)
        }
        // Exclusive workspace roots are writable. Shared roots are omitted from
        // this allowlist while their task output folder remains explicit below.
        // Exact task-input and message-attachment roots are carved back out, so
        // the read-only contract still wins inside either access mode.
        let runtimeWritablePaths = Self.runtimeWritablePaths(
            for: context.task,
            workspaceAccess: launchResourcePlan.workspaceAccess
        )
        let decision = ExecutionSandbox.decide(
            plan: plan,
            providerHomeDirectory: context.providerHomeDirectory,
            additionalWritablePaths: runtimeWritablePaths + launchResourcePlan.hostWritablePaths,
            additionalReadablePaths: runtimeWritablePaths + launchResourcePlan.hostReadablePaths,
            workspaceWritable: launchResourcePlan.workspaceAccess == .exclusive,
            settings: settings
        )
        let taskID = context.taskSnapshot.id
        switch decision {
        case .applied(_, let writableRoots):
            AppLogger.audit(.sandboxApplied, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "read_scope": settings.readScope.rawValue,
                "read_scope_audit": String(settings.readScope == .audit),
                "writable_root_count": String(writableRoots.count),
                "shared_workspace_boundary_required": String(
                    launchResourcePlan.requiresSharedWorkspaceBoundary
                ),
                "attachment_readable_path_count": plan.commandPlannedFields["attachment_readable_path_count"] ?? "0",
                "launch_resource_host_readable_count": plan.commandPlannedFields["launch_resource_host_readable_count"] ?? "0",
                "launch_resource_host_writable_count": plan.commandPlannedFields["launch_resource_host_writable_count"] ?? "0",
                "launch_resource_credential_label_count": plan.commandPlannedFields["launch_resource_credential_label_count"] ?? "0",
                "git_credential_readable_path_count": String(gitCredentialContext.readablePaths.count),
                "git_credential_writable_path_count": String(gitCredentialContext.writablePaths.count),
                "allow_network": String(settings.allowNetwork)
            ], level: .debug)
        case .skipped(let reason):
            AppLogger.audit(.sandboxSkipped, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": reason
            ], level: .debug)
        case .fallback(let reason):
            AppLogger.audit(.sandboxFallback, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "reason": reason
            ], level: .warning)
        case .failClosed(let reason):
            AppLogger.audit(.sandboxFailed, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "reason": reason
            ], level: .error)
        }

        if readOnlyInputBoundary.requiresHostSeatbelt {
            let unavailableReason: String? = switch decision {
            case .applied:
                nil
            case .skipped where settings.enforcement == .off:
                nil  // User disabled sandbox; bypass Seatbelt requirement for read-only inputs
            case .skipped(let reason), .fallback(let reason), .failClosed(let reason):
                reason
            }
            if let unavailableReason {
                let result = readOnlyInputBoundary.unavailableResult(reason: unavailableReason)
                AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
                    "runtime": plan.runtime.rawValue,
                    "reason": result.runtimeStopReason ?? "read_only_input_boundary_unavailable",
                    "boundary_failure": unavailableReason,
                    "read_only_input_boundary_path_count": String(readOnlyInputBoundary.paths.count)
                ], level: .error)
                return .blocked(result)
            }
            if case .applied = decision {
                appliedBoundarySurfaces.insert(.hostSeatbelt)
            }
        }

        if case .applied(let wrappedPlan, _) = decision {
            var finalPlan = wrappedPlan.addingSandboxReadablePaths(
                [],
                plannedFields: ["astra_sandbox_applied": "true"]
            )
            if readOnlyInputBoundary.isRequired {
                guard let receipt = readOnlyInputBoundary.receipt(
                    appliedSurfaces: appliedBoundarySurfaces,
                    mounts: finalPlan.executionEnvironment.mounts
                ) else {
                    return .blocked(readOnlyInputBoundary.unavailableResult(reason: "boundary_receipt_incomplete"))
                }
                finalPlan.readOnlyBoundaryReceipt = receipt
            }
            return .plan(finalPlan)
        }
        return Self.sandboxOutcome(for: decision, originalPlan: plan, enforcement: settings.enforcement)
    }

    enum SandboxedUtilityPlanOutcome {
        case plan(AgentUtilityLaunchPlan)
        case blocked(AgentUtilityRunResult)
    }

    @MainActor
    func sandboxedUtilityPlan(_ utilityPlan: AgentUtilityLaunchPlan) -> SandboxedUtilityPlanOutcome {
        let plan = utilityPlan.process
        var settings = sandboxSettingsProvider(utilityPlan.permissionPolicy)
        if AgentUtilityExecutionLimits.requiresIsolation {
            // Strengthen the existing policy without relaxing offline or
            // fail-closed restrictions selected by the user.
            settings.enforcement = .strict
            settings.readScope = .enforce
            settings.wrappedRuntimes.insert(plan.runtime)
        }
        let decision = ExecutionSandbox.decide(
            plan: plan,
            providerHomeDirectory: utilityPlan.providerHomeDirectory,
            settings: settings
        )

        switch decision {
        case .applied(_, let writableRoots):
            AppLogger.audit(.sandboxApplied, category: "Utility", fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "read_scope": settings.readScope.rawValue,
                "read_scope_audit": String(settings.readScope == .audit),
                "writable_root_count": String(writableRoots.count),
                "allow_network": String(settings.allowNetwork)
            ], level: .debug)
        case .skipped(let reason):
            AppLogger.audit(.sandboxSkipped, category: "Utility", fields: [
                "runtime": plan.runtime.rawValue,
                "reason": reason
            ], level: .debug)
        case .fallback(let reason):
            AppLogger.audit(.sandboxFallback, category: "Utility", fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "reason": reason
            ], level: .warning)
        case .failClosed(let reason):
            AppLogger.audit(.sandboxFailed, category: "Utility", fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "reason": reason
            ], level: .error)
        }

        switch Self.sandboxOutcome(for: decision, originalPlan: plan, enforcement: settings.enforcement, isUtility: true) {
        case .plan(let resolvedPlan):
            return .plan(AgentUtilityLaunchPlan(
                process: resolvedPlan,
                providerHomeDirectory: utilityPlan.providerHomeDirectory,
                permissionPolicy: utilityPlan.permissionPolicy,
                timeoutSeconds: utilityPlan.timeoutSeconds
            ))
        case .blocked(let result):
            return .blocked(AgentUtilityRunResult(
                exitCode: result.exitCode,
                output: "",
                error: result.error ?? result.runtimeStopMessage ?? "ASTRA could not apply the execution sandbox."
            ))
        }
    }

    @MainActor
    func runUtilityProcess(
        _ utilityPlan: AgentUtilityLaunchPlan,
        outputTransform: @escaping @Sendable (String) -> String = { $0 },
        stdoutLineHandler: (@Sendable (String) -> AgentUtilityRunResult?)? = nil,
        stderrChunkHandler: (@Sendable (String) -> Void)? = nil,
        completion: (@Sendable (_ exitCode: Int, _ stdout: String, _ stderr: String) -> AgentUtilityRunResult)? = nil,
        launchError: (@Sendable (_ message: String) -> AgentUtilityRunResult)? = nil,
        timeoutResult: (@Sendable (_ timeoutSeconds: TimeInterval) -> AgentUtilityRunResult)? = nil
    ) async -> AgentUtilityRunResult {
        let resolvedPlan: AgentUtilityLaunchPlan
        switch await guardedSandboxedUtilityPlan(utilityPlan) {
        case .plan(let plan):
            resolvedPlan = plan
        case .blocked(let result):
            return result
        }

        let processPlan = resolvedPlan.process
        AppLogger.audit(
            .runtimeProviderDetected,
            category: "Utility",
            fields: processPlan.providerDetectedFields,
            level: .debug,
            fieldMaxLength: 220
        )
        AppLogger.audit(
            .runtimeCommandPlanned,
            category: "Utility",
            fields: processPlan.commandPlannedFields,
            level: .debug
        )

        for directory in processPlan.directoriesToCreate where !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let completionHandler = completion ?? { exitCode, stdout, stderr in
            AgentUtilityRunResult(exitCode: exitCode, output: outputTransform(stdout), error: stderr)
        }
        let launchErrorHandler = launchError ?? { message in
            AgentUtilityRunResult(exitCode: -1, output: "", error: message)
        }
        let timeoutHandler = timeoutResult ?? { timeoutSeconds in
            let timeoutText = "Process timed out after \(Int(timeoutSeconds.rounded())) seconds."
            return AgentUtilityRunResult(exitCode: -1, output: "", error: timeoutText)
        }

        return await Self.runScopedUtilityProcess(
            processPlan,
            timeoutSeconds: resolvedPlan.timeoutSeconds,
            stdoutLineHandler: stdoutLineHandler,
            stderrChunkHandler: stderrChunkHandler,
            completion: completionHandler,
            launchError: launchErrorHandler,
            timeoutResult: timeoutHandler
        )
    }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        permissionManifest: RunPermissionManifest? = nil,
        budgetEnforcementMode: BudgetEnforcementMode = .configuredDefault,
        timeoutSeconds: TimeInterval,
        phase: RunPhase = .run,
        contextText: String = "",
        nativeContinuationSessionID: String? = nil,
        runID: UUID? = nil,
        launchResourcePlan: TaskLaunchResourcePlan? = nil,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        runtimeRequirements: TaskRuntimeRequirementSet? = nil,
        liveApprovalsEnabled: Bool = false,
        noSemanticProgressTimeoutSeconds: TimeInterval? = nil,
        maxRunSeconds: TimeInterval? = nil,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)? = nil,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let launchPreparationStarted = ProcessInfo.processInfo.systemUptime
        let launchContext = AgentRuntimeProcessLaunchContext(
            prompt: prompt,
            task: task,
            workspacePath: workspacePath,
            executablePath: executablePath,
            providerHomeDirectory: homeDirectory,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            permissionManifest: permissionManifest,
            timeoutSeconds: timeoutSeconds,
            phase: phase,
            contextText: contextText,
            nativeContinuationSessionID: nativeContinuationSessionID,
            runID: runID,
            liveApprovalsEnabled: liveApprovalsEnabled && onInteractiveAsk != nil,
            launchResourcePlan: launchResourcePlan,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            runtimeRequirements: runtimeRequirements
        )
        let effectiveRequirements = runtimeRequirements ?? TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: launchContext.capabilityResolutionSnapshot,
            executionEnvironment: DockerExecutionPlanner.resolveEnvironment(for: task),
            browserBridgeRequired: launchContext.capabilityResolutionSnapshot.providerLaunch.requiresBrowserBridge
        )
        let requiresHostControlBroker = !effectiveRequirements.hostControlTools.isEmpty
        let supportsHostControlBroker = AgentRuntimeCapabilityProfileService.profile(
            for: adapter.id,
            executablePath: executablePath
        ).canDeliverHostControlPlane
        if requiresHostControlBroker, !supportsHostControlBroker {
            let message = "\(adapter.id.displayName) cannot attach ASTRA host tools required by this turn."
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "runtime": adapter.id.rawValue,
                "reason": "host_control_transport_unavailable",
                "required_tools": effectiveRequirements.hostControlTools.joined(separator: ",")
            ], level: .error)
            return AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "host_control_transport_unavailable",
                runtimeStopMessage: message
            )
        }
        let brokerPrepared = supportsHostControlBroker && effectiveRequirements.offersHostControlPlane
            && hostControlBrokerSessionManager.prepare(
            task: task,
            runID: runID,
            runtime: adapter.id,
            capabilityScope: launchContext.capabilityResolutionSnapshot.providerLaunch,
            requiredTools: effectiveRequirements.offeredHostControlTools,
            currentDirectory: workspacePath,
            sshRoute: executionPolicy.remoteSSHRoute
        )
        if requiresHostControlBroker, !brokerPrepared {
            let message = "ASTRA could not establish the run-scoped host-control broker."
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
                "runtime": adapter.id.rawValue,
                "reason": "host_control_broker_unavailable",
                "required_tools": effectiveRequirements.hostControlTools.joined(separator: ",")
            ], level: .error)
            return AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "host_control_broker_unavailable",
                runtimeStopMessage: message
            )
        }
        defer {
            if brokerPrepared {
                hostControlBrokerSessionManager.stop(taskID: task.id, runID: runID)
            }
        }
        let allowance = Self.attemptAllowance(task: task, policy: executionPolicy)
        guard allowance.tokens > 0, allowance.turns > 0, executionPolicy.recoveryAllowance?.secondsRemaining != 0 else {
            return AgentProcessResult(exitCode: -1, runtimeStopReason: "recovery_limits_exhausted",
                runtimeStopMessage: "Recovery did not reset the original execution limits.", budgetExceeded: true)
        }
        let remainingTokenBudget = allowance.tokens
        let remainingTurns = allowance.turns
        if let sharedStateKey = adapter.sharedLaunchStateKey(context: launchContext) {
            let sharedStateLease: AgentRuntimeSharedStateLease
            do {
                sharedStateLease = try await AgentRuntimeSharedStateGate.shared.acquire(sharedStateKey, owner: executionOwner)
            } catch is CancellationError {
                return AgentProcessResult(
                    exitCode: -1,
                    error: "Task cancelled before acquiring provider shared state.",
                    runtimeStopReason: "cancelled",
                    runtimeStopMessage: "Task cancelled before acquiring provider shared state."
                )
            } catch {
                return AgentProcessResult(exitCode: -1, error: error.localizedDescription)
            }
            self.sharedStateLease = sharedStateLease
            self.sharedStateOwnerID = executionOwner?.record.ownerID
            let plan: AgentRuntimeProcessLaunchPlan
            switch await guardedSandboxedPlan(adapter: adapter, context: launchContext) {
            case .plan(let resolvedPlan):
                plan = resolvedPlan
            case .blocked(let blockedResult):
                if executionOwner == nil || executionOwner?.releaseProviderSharedState() == true {
                    await AgentRuntimeSharedStateGate.shared.release(sharedStateLease)
                    if self.sharedStateLease == sharedStateLease { self.sharedStateLease = nil }
                }
                return blockedResult
            }
            let result = await runProcess(
                adapter: adapter,
                plan: plan,
                task: task,
                runID: runID,
                permissionManifest: permissionManifest,
                budgetEnforcementMode: budgetEnforcementMode,
                timeoutSeconds: timeoutSeconds,
                noSemanticProgressTimeoutSeconds: noSemanticProgressTimeoutSeconds,
                maxRunSeconds: maxRunSeconds,
                preparationStartedAt: launchPreparationStarted,
                maxTurns: remainingTurns,
                tokenBudget: remainingTokenBudget,
                nativeSessionID: nativeContinuationSessionID,
                reportedUsageBaseline: executionPolicy.providerSessionUsageBaseline,
                estimatedInputTokens: Self.estimatedLaunchInputTokens(prompt: prompt, runtime: adapter.id),
                onInteractiveAsk: onInteractiveAsk,
                onLine: onLine
            )
            if executionOwner == nil || executionOwner?.releaseProviderSharedState() == true {
                await AgentRuntimeSharedStateGate.shared.release(sharedStateLease)
                if self.sharedStateLease == sharedStateLease { self.sharedStateLease = nil }
            }
            return result
        }

        let plan: AgentRuntimeProcessLaunchPlan
        switch await guardedSandboxedPlan(adapter: adapter, context: launchContext) {
        case .plan(let resolvedPlan):
            plan = resolvedPlan
        case .blocked(let blockedResult):
            return blockedResult
        }
        return await runProcess(
            adapter: adapter,
            plan: plan,
            task: task,
            runID: runID,
            permissionManifest: permissionManifest,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            noSemanticProgressTimeoutSeconds: noSemanticProgressTimeoutSeconds,
            maxRunSeconds: maxRunSeconds,
                preparationStartedAt: launchPreparationStarted,
            maxTurns: remainingTurns,
            tokenBudget: remainingTokenBudget,
            nativeSessionID: nativeContinuationSessionID,
            reportedUsageBaseline: executionPolicy.providerSessionUsageBaseline,
                estimatedInputTokens: Self.estimatedLaunchInputTokens(prompt: prompt, runtime: adapter.id),
            onInteractiveAsk: onInteractiveAsk,
            onLine: onLine
        )
    }

    @MainActor
    private func runProcess(
        adapter: any AgentRuntimeProcessEventParsing,
        plan: AgentRuntimeProcessLaunchPlan,
        task: AgentTask,
        runID: UUID?,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        preparationStartedAt: TimeInterval,
        maxTurns: Int,
        tokenBudget: Int,
        nativeSessionID: String?,
        reportedUsageBaseline: ProviderSessionUsageBaseline,
        estimatedInputTokens: Int,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)? = nil,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let taskID = task.id
        let preparationGeneration = homeAccessCancellation.snapshot()
        let context = supervisionContext
        var baseline: RuntimeSupervisionFiles?
        if let context {
            let preparation = Task { await context.captureFiles() }
            supervisionPreparation = preparation
            baseline = await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
            supervisionPreparation = nil
        }
        guard !Task.isCancelled, task.status != .cancelled, homeAccessCancellation.isCurrent(preparationGeneration) else {
            return AgentProcessResult(exitCode: -1, error: "Cancelled before provider launch.")
        }
        defer {
            activeSupervision?.finish(); activeSupervision = nil
            activeRecovery?.finish(); activeRecovery = nil
        }

        // The one place that owns a live agent process, so the one place that
        // can say a redaction scope must not be evicted yet. A run that spends
        // ten minutes on a tool call writes nothing, and without this the LRU
        // treats it as finished: sixteen shorter runs starting meanwhile drop
        // its secrets, and its next line of output is persisted in the clear.
        RunSecretRedactionScope.beginRun(taskID: taskID)
        defer { RunSecretRedactionScope.endRun(taskID: taskID) }

        let owner = executionOwner
        let preparationSeconds = max(0, ProcessInfo.processInfo.systemUptime - preparationStartedAt)
        owner?.chargePreparation(seconds: preparationSeconds)
        let maxRunSeconds = maxRunSeconds.map { max(0, $0 - preparationSeconds) }
        if owner != nil, (maxRunSeconds ?? 0) <= 0 || owner?.record.limits.secondsRemaining == 0 {
            return AgentProcessResult(exitCode: -1, runtimeStopReason: "recovery_limits_exhausted",
                runtimeStopMessage: "The remaining execution time expired before launch.", budgetExceeded: true)
        }
        do { try owner?.prepareLaunch(sessionID: nativeSessionID) }
        catch { return AgentProcessResult(exitCode: -1, runtimeStopReason: "runtime_recovery_blocked", runtimeStopMessage: "Recovery ownership could not authorize this launch.") }
        let executionID = owner?.record.executionID ?? UUID()
        let remoteWorkExcluded = owner?.remoteWorkExcluded ?? false
        let ownershipEvents = OrderedMainActorTaskQueue()
        let inspectedAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)? = onInteractiveAsk.map { ask in
            { request in
                await MainActor.run { owner?.waitingForInput(true) }
                let result = await ask(request)
                await MainActor.run { owner?.waitingForInput(false) }
                return result
            }
        }
        let processEvidence = RuntimeExecutionProcessEvidence()
        let processStartedAt = ProcessInfo.processInfo.systemUptime
        let deliveryChannel = AgentLivePermissionDeliveryChannel()
        let result: AgentProcessResult = await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var hasResumed = false
            let resumeOnce: (AgentProcessResult) -> Void = { result in
                resumeLock.lock()
                guard !hasResumed else { resumeLock.unlock(); return }
                hasResumed = true
                resumeLock.unlock()
                Task { @MainActor in
                    owner?.stopped(proof: result.executionStopProof, turns: result.executionTurnsSpent ?? 1,
                        tokens: result.executionTokensSpent ?? 0, seconds: result.executionSecondsSpent ?? 0)
                    continuation.resume(returning: result)
                }
            }

            AppLogger.audit(
                .runtimeProviderDetected,
                category: "Worker",
                taskID: task.id,
                fields: plan.providerDetectedFields,
                level: .debug,
                fieldMaxLength: 220
            )
            AppLogger.audit(
                .runtimeCommandPlanned,
                category: "Worker",
                taskID: task.id,
                fields: plan.commandPlannedFields,
                level: .debug
            )

            for directory in plan.directoriesToCreate where !directory.isEmpty {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }

            let process = AgentExecutionScopedProcess(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                currentDirectory: plan.currentDirectory,
                environment: plan.environment,
                providesStdinChannel: plan.interactiveAsk != nil
            )

            let stdoutReader = AgentProcessPipeReader(process.stdoutFileHandle)
            let stderrReader = AgentProcessPipeReader(process.stderrFileHandle)
            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: plan.runtime)
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: tokenBudget,
                reportedUsageBaseline: reportedUsageBaseline,
                budgetEnforcementMode: budgetEnforcementMode,
                maxTurns: maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                noSemanticProgressTimeoutSeconds: noSemanticProgressTimeoutSeconds,
                maxRunSeconds: maxRunSeconds,
                taskID: task.id,
                policyGuard: permissionManifest.map {
                    AgentRuntimePolicyGuard(manifest: $0, boundary: RunBoundary(manifest: $0, plan: plan))
                },
                liveApprovalsActive: plan.interactiveAsk != nil,
                sandboxDiagnosticContext: RuntimeSandboxDiagnosticContext(
                    boundaryApplied: plan.commandPlannedFields["astra_sandbox_applied"] == "true",
                    workingDirectory: plan.currentDirectory,
                    boundaryReceipt: plan.executionSandboxBoundaryReceipt
                ),
                readOnlyBoundaryReceipt: plan.readOnlyBoundaryReceipt
            )
            let supervision = context.map { context in
                RuntimeSupervisionSession(goal: context.goal, runtime: context.runtime,
                    remoteCoverage: context.remoteCoverage, baseline: baseline ?? .init(unavailable: "No baseline"),
                    configuration: .init(tokenReservation: context.tokenReservation),
                    collectFiles: { await context.captureFiles() },
                    investigate: context.investigator,
                    reserveTokens: { [weak monitor] in monitor?.reserveSupervisionTokens($0) ?? false }, report: context.report)
            }
            activeSupervision = supervision
            monitor.supervision = supervision
            let recovery = RuntimeRecoverySession.make(context: context?.recovery, process: process, monitor: monitor)
            activeRecovery = recovery
            monitor.recovery = recovery
            monitor.supervisionProcessSuspension = { process.suspendedProcessIdentifier == nil ? nil : true }

            let handleLine: (String) -> Void = { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    // Plain-text providers use blank lines as paragraph
                    // boundaries; forward them to the recording path so
                    // transcripts keep their structure. JSON-lines providers
                    // treat blank lines as framing noise, and the monitor
                    // never needs them.
                    if !plan.parsesJSONLines {
                        onLine(line, plan.parsesJSONLines)
                    }
                    return
                }
                if plan.interactiveAsk != nil,
                   let control = ClaudeControlProtocol.controlRequest(from: trimmed) {
                    processEvidence.observe(.unknown(type: "interactive_tool_request"))
                    Self.answerControlRequest(
                        control,
                        process: process,
                        monitor: monitor,
                        taskID: taskID,
                        deliveryChannel: deliveryChannel,
                        onInteractiveAsk: inspectedAsk
                    )
                    return
                }
                onLine(line, plan.parsesJSONLines)
                let parsedEvents = adapter.parseProcessEvents(line: line, parsesJSONLines: plan.parsesJSONLines)
                processEvidence.observeFrame(line, parsesJSONLines: plan.parsesJSONLines, events: parsedEvents)
                for parsed in parsedEvents {
                    if case .systemInit(_, let sessionID) = parsed {
                        ownershipEvents.add { owner?.session(sessionID) }
                    }
                    for filtered in eventPipeline.process(parsed) {
                        _ = monitor.processEvent(filtered, process: process)
                    }
                    // Stream-json input providers wait for the next stdin
                    // message after a turn ends; EOF on the terminal result is
                    // what lets the process exit.
                    if plan.interactiveAsk != nil, case .result = parsed {
                        deliveryChannel.observeProviderCompletion()
                        process.closeStdinChannel()
                    }
                }
                if let message = adapter.blockingProcessPermissionMessage(
                    line: line,
                    parsesJSONLines: plan.parsesJSONLines
                ) {
                    errorOutput.append(message)
                    process.terminate()
                }
            }

            // A pipe read chunk boundary is an arbitrary byte count, not a
            // UTF-8 character boundary — a multi-byte scalar can span two
            // reads. A strict decode of one chunk in isolation would then
            // fail and drop that whole chunk's output. Decode lossily
            // instead: a split character becomes a single U+FFFD in the rare
            // case it straddles a chunk boundary, but every other byte
            // survives instead of the entire chunk being discarded.
            //
            // One reader owns each pipe through final delivery. Neither a
            // stale readability callback nor the final drain may block on a
            // descendant that outlives the reaped provider.
            let consumeStdout: (Data) -> Void = { data in
                monitor.recordStreamVolume(bytes: data.count)
                monitor.supervisionTranscript.append(String(decoding: data, as: UTF8.self), stderr: false, taskID: taskID)
                lineBuffer.appendAndProcessLines(String(decoding: data, as: UTF8.self), handleLine)
            }
            let consumeStderr: (Data) -> Void = { data in
                monitor.supervisionTranscript.append(String(decoding: data, as: UTF8.self), stderr: true, taskID: taskID)
                errorOutput.append(String(decoding: data, as: UTF8.self))
            }
            process.stdoutFileHandle.readabilityHandler = { _ in
                stdoutReader.readAvailable(consume: consumeStdout)
            }
            process.stderrFileHandle.readabilityHandler = { _ in
                stderrReader.readAvailable(consume: consumeStderr)
            }

            process.terminationHandler = { proc in
                supervision?.finish()
                InFlightPermissionCenter.shared.failAll(taskID: taskID)
                proc.stdoutFileHandle.readabilityHandler = nil
                proc.stderrFileHandle.readabilityHandler = nil
                stdoutReader.finish(consume: consumeStdout)
                // EOF flush only: an empty remainder must not synthesize a
                // paragraph break for plain-text providers.
                let remainder = lineBuffer.drainRemaining()
                if !remainder.isEmpty { handleLine(remainder) }
                stderrReader.finish(consume: consumeStderr)
                for filtered in eventPipeline.flushParsedEvents() {
                    _ = monitor.processEvent(filtered, process: process)
                }
                recovery?.finish(progressRevision: monitor.currentSupervisionProgressRevision)
                let error = errorOutput.value
                let dockerFailure = DockerRuntimeFailureDiagnostics.diagnose(
                    exitCode: Int(proc.terminationStatus),
                    error: error,
                    plan: plan
                )
                if let dockerFailure {
                    AppLogger.audit(
                        .runtimeFailureDiagnostic,
                        category: "Worker",
                        taskID: taskID,
                        fields: dockerFailure.auditFields,
                        level: .error,
                        fieldMaxLength: 900
                    )
                }
                // Always on, unlike the opt-in stream debug capture. Frames the
                // parser could not classify are the upstream cause of runs being
                // killed while they are still working, so the count has to be
                // visible by default rather than only when someone already
                // suspected a parser gap.
                if monitor.unrecognizedEventCount > 0 {
                    AppLogger.audit(.runtimeUnknownEvent, category: "Worker", taskID: taskID, fields: [
                        "runtime": plan.runtime.rawValue,
                        "unknown_events": String(monitor.unrecognizedEventCount),
                        "stream_bytes": String(monitor.streamBytesObserved),
                        "exit_code": String(Int(proc.terminationStatus))
                    ], level: .warning)
                }
                // A provider can cut its own turn short and still exit 0 (agy's
                // print timeout even sends a SUCCESS result frame), so a turn
                // ASTRA did not stop is checked against what stderr says.
                let selfStop = monitor.runtimeStopReason == nil && dockerFailure == nil
                    ? adapter.providerSelfStop(stderr: error) : nil
                if let selfStop {
                    AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: [
                        "runtime": plan.runtime.rawValue,
                        "reason": selfStop.reason,
                        "source": "provider_self_stop",
                        "exit_code": String(Int(proc.terminationStatus))
                    ], level: .error)
                }
                Self.cleanupBrowserToolShim(at: plan.browserShimDirectory, taskID: taskID)
                var processResult = AgentProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    error: error.isEmpty ? nil : error,
                    providerFailureOutput: monitor.providerFailureOutput,
                    providerVersion: plan.providerVersion,
                    policyViolation: monitor.policyViolation,
                    policyViolationMessage: monitor.policyViolationMessage,
                    policyApprovalRequired: monitor.policyApprovalRequired,
                    policyApprovalMessage: monitor.policyApprovalMessage,
                    runtimeStopReason: dockerFailure?.stopReason ?? monitor.runtimeStopReason ?? selfStop?.reason,
                    runtimeStopMessage: dockerFailure?.message ?? monitor.runtimeStopMessage ?? selfStop?.message,
                    runtimeRepairContext: dockerFailure == nil ? monitor.runtimeRepairContext : nil,
                    budgetExceeded: monitor.budgetExceeded,
                    budgetWarning: monitor.budgetWarning,
                    finalReportedBudgetExceededAfterCompletion: monitor.finalReportedBudgetExceededAfterCompletion,
                    terminatedAfterTerminalProgress: monitor.terminatedAfterTerminalProgress,
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded,
                    readOnlyBoundaryEvidence: plan.readOnlyBoundaryReceipt?.evidence
                )
                processResult.executionStopProof = proc.stopProof(executionID: executionID,
                    toolsStopped: processEvidence.toolsStopped, remoteWorkExcluded: remoteWorkExcluded)
                processResult.executionTurnsSpent = max(1, monitor.turnCount)
                processResult.executionTokensSpent = monitor.recoveryTokensConsumed(estimatedInputTokens: estimatedInputTokens)
                processResult.executionSecondsSpent = ProcessInfo.processInfo.systemUptime - processStartedAt
                resumeOnce(processResult)
            }

            do {
                try process.run()
                do { try owner?.launched(process) }
                catch { process.terminate() } // never return while the original child can still execute
                hostControlBrokerSessionManager.registerProviderProcess(
                    taskID: taskID,
                    runID: runID,
                    processID: process.processIdentifier
                )
            } catch {
                owner?.didNotLaunch()
                Self.cleanupBrowserToolShim(at: plan.browserShimDirectory, taskID: taskID)
                resumeOnce(AgentProcessResult(
                    exitCode: -1,
                    error: error.localizedDescription,
                    providerVersion: plan.providerVersion,
                    readOnlyBoundaryEvidence: plan.readOnlyBoundaryReceipt?.evidence
                ))
                return
            }

            if let interactiveAsk = plan.interactiveAsk {
                process.writeStdinLine(interactiveAsk.initialStdinMessage)
            }
            currentProcess = process
            monitor.startWatchdog(process: process)
        }
        await ownershipEvents.drainAll()
        var acknowledgedResult = result
        acknowledgedResult.supervisionReservedTokens = activeSupervision?.tokenReservation
        acknowledgedResult.acknowledgedPermissionRequestIDs = deliveryChannel.acknowledgedPermissionRequestIDs
        acknowledgedResult.writtenPermissionRequestIDs = deliveryChannel.writtenPermissionRequestIDs
        return acknowledgedResult
    }

    static func runScopedUtilityProcess(
        _ plan: AgentRuntimeProcessLaunchPlan,
        timeoutSeconds: TimeInterval,
        stdoutLineHandler: (@Sendable (String) -> AgentUtilityRunResult?)?,
        stderrChunkHandler: (@Sendable (String) -> Void)?,
        completion: @escaping @Sendable (_ exitCode: Int, _ stdout: String, _ stderr: String) -> AgentUtilityRunResult,
        launchError: @escaping @Sendable (_ message: String) -> AgentUtilityRunResult,
        timeoutResult: @escaping @Sendable (_ timeoutSeconds: TimeInterval) -> AgentUtilityRunResult
    ) async -> AgentUtilityRunResult {
        let process = AgentExecutionScopedProcess(
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: plan.currentDirectory,
            environment: plan.environment,
            stdinMode: .closed
        )
        let stdoutReader = AgentProcessPipeReader(process.stdoutFileHandle)
        let stderrReader = AgentProcessPipeReader(process.stderrFileHandle)
        let stdoutBuffer = AgentLockedBuffer()
        let stderrBuffer = AgentLockedBuffer()
        let stdoutLineBuffer = AgentLockedBuffer()
        let runState = AgentUtilityScopedProcessRunState()
        let outputAllowance = AgentUtilityOutputAllowance(AgentUtilityExecutionLimits.maximumOutputBytes)
        let outputLimitResult = AgentUtilityRunResult(exitCode: -1, output: "", error: "Utility output exceeded its configured limit.")

        // The pipe reader serializes read and delivery; the line buffer also
        // protects the final partial-line flush after the reader is sealed.
        let handleStdoutLocked: @Sendable (String) -> AgentUtilityRunResult? = { chunk in
            guard outputAllowance.accept(chunk.utf8.count) else { return outputLimitResult }
            stdoutBuffer.append(chunk)
            guard let stdoutLineHandler else { return nil }
            for line in stdoutLineBuffer.appendAndDrainLinesLocked(chunk) {
                if let result = stdoutLineHandler(line) {
                    return result
                }
            }
            return nil
        }

        let handleRemainingStdoutLineLocked: @Sendable () -> AgentUtilityRunResult? = {
            guard let stdoutLineHandler else { return nil }
            let remaining = stdoutLineBuffer.drainRemainingLocked()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remaining.isEmpty else { return nil }
            return stdoutLineHandler(remaining)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let requestTermination: @Sendable (AgentUtilityRunResult) -> Void = { result in
                    guard runState.requestTermination(with: result) else { return }
                    // Do not disable readability handlers or resume here. The
                    // process's termination handler drains both pipes after
                    // waitpid/process-group cleanup and is the only completion
                    // path for a launched child.
                    process.terminate()
                }
                let finishWithoutProcess: @Sendable (AgentUtilityRunResult) -> Void = { result in
                    guard let result = runState.completeWithoutProcess(result) else { return }
                    continuation.resume(returning: result)
                }
                let finishAfterProcessExit: @Sendable (AgentUtilityRunResult) -> Void = { result in
                    guard let result = runState.completeAfterProcessExit(naturalResult: result) else {
                        return
                    }
                    continuation.resume(returning: result)
                }

                process.stdoutFileHandle.readabilityHandler = { _ in
                    var result: AgentUtilityRunResult?
                    stdoutReader.readAvailable { data in
                        let parsed = stdoutLineBuffer.synchronized {
                            handleStdoutLocked(String(decoding: data, as: UTF8.self))
                        }
                        result = result ?? parsed
                    }
                    if let result { requestTermination(result) }
                }
                let consumeStderr: (Data) -> Void = { data in
                    guard outputAllowance.accept(data.count) else { requestTermination(outputLimitResult); return }
                    let chunk = String(decoding: data, as: UTF8.self)
                    stderrBuffer.append(chunk)
                    stderrChunkHandler?(chunk)
                }
                process.stderrFileHandle.readabilityHandler = { _ in
                    stderrReader.readAvailable(consume: consumeStderr)
                }

                process.terminationHandler = { proc in
                    proc.stdoutFileHandle.readabilityHandler = nil
                    proc.stderrFileHandle.readabilityHandler = nil
                    var stdoutResult: AgentUtilityRunResult?
                    stdoutReader.finish { data in
                        let parsed = stdoutLineBuffer.synchronized {
                            handleStdoutLocked(String(decoding: data, as: UTF8.self))
                        }
                        stdoutResult = stdoutResult ?? parsed
                    }
                    let remainingResult = stdoutLineBuffer.synchronized {
                        handleRemainingStdoutLineLocked()
                    }
                    stdoutResult = stdoutResult ?? remainingResult
                    stderrReader.finish(consume: consumeStderr)
                    if let stdoutResult {
                        finishAfterProcessExit(stdoutResult)
                        return
                    }
                    let result = completion(
                        Int(proc.terminationStatus),
                        stdoutBuffer.value.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderrBuffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    finishAfterProcessExit(result)
                }

                do {
                    try process.run()
                    // Cancellation can race the interval between entering the
                    // cancellation handler and publishing the spawned pid. If
                    // the first terminate was a no-op, close that window now.
                    if Task.isCancelled {
                        process.terminate()
                    }
                    scheduleUtilityTimeoutIfNeeded(
                        timeoutSeconds: timeoutSeconds,
                        process: process,
                        requestTermination: requestTermination,
                        timeoutResult: timeoutResult
                    )
                } catch {
                    finishWithoutProcess(launchError(error.localizedDescription))
                }
            }
        } onCancel: {
            runState.markCancelled()
            process.terminate()
        }
    }

    private static func scheduleUtilityTimeoutIfNeeded(
        timeoutSeconds: TimeInterval,
        process: AgentExecutionScopedProcess,
        requestTermination: @escaping @Sendable (AgentUtilityRunResult) -> Void,
        timeoutResult: @escaping @Sendable (TimeInterval) -> AgentUtilityRunResult
    ) {
        guard timeoutSeconds > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            guard process.isRunning else { return }
            requestTermination(timeoutResult(timeoutSeconds))
        }
    }

    /// Directories for Copilot's `--add-dir`, plus any attached input file no
    /// granted root covers. Copilot rejects a non-directory `--add-dir` value,
    /// and `runtimeReadOnlyInputPaths` carries files — every paste is one.
    static func copilotNativeDirectoryProjection(for task: AgentTask) -> ProviderNativeDirectoryProjection.Result {
        let writable = runtimeWritablePaths(for: task)
        let access = TaskWorkspaceAccess(task: task)
        // Copilot's path gate also governs reads, so folders the run may only
        // read need their own `--add-dir`; the outer sandbox keeps them read-only.
        let readable = access.runtimeReadOnlyWorkspacePaths
        // Copilot launches in the code root, so inputs beneath it are reachable.
        let inputs = ProviderNativeDirectoryProjection.project(
            resourcePaths: access.runtimeReadOnlyInputPaths,
            alreadyReachableDirectories: [access.codeWorkingDirectory] + writable + readable
        )
        return .init(
            additionalDirectories: writable + readable + inputs.additionalDirectories,
            unreachableFiles: inputs.unreachableFiles
        )
    }

    /// Writable roots beyond the launch directory. Every entry is either
    /// claimed at admission (`TaskExecutionResourceClaimResolver.workspaceKeys`
    /// reads the same `TaskWorkspaceAccess.runtimeWritablePaths`) or the task's
    /// own folder. The workspace root is deliberately absent: it is the launch
    /// directory when it is the code root, and otherwise sibling tasks would
    /// share an unclaimed writable folder.
    static func runtimeWritablePaths(
        for task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess = .exclusive
    ) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        var paths = workspaceAccess == .exclusive ? access.runtimeWritablePaths : []
        if !access.taskFolder.isEmpty {
            paths.append(access.taskFolder)
        }
        return Array(Set(paths.filter { !$0.isEmpty })).sorted()
    }

    @MainActor
    static func copilotLocalToolCommands(for task: AgentTask, contextText: String = "") -> [String] {
        runtimeLocalToolCommands(for: task, contextText: contextText)
    }

    @MainActor
    static func runtimeLocalToolCommands(for task: AgentTask, contextText: String = "") -> [String] {
        let capabilityScope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        return runtimeLocalToolCommands(in: capabilityScope)
    }

    @MainActor
    static func runtimeLocalToolCommands(in capabilityScope: TaskCapabilityPromptScope) -> [String] {
        return Array(Set(capabilityScope.reachableLocalTools.compactMap { tool in
            guard tool.toolType != "mcp" else { return nil }
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        })).sorted()
    }

    static func model(_ model: String, for runtime: AgentRuntimeID) -> String {
        RuntimeModelAvailability.normalizedModel(model, for: runtime)
    }

    static func fileModificationTimestamp(_ path: String) -> String {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            return "unknown"
        }
        return String(Int(modified.timeIntervalSince1970))
    }

    @MainActor
    static func environment(
        phase: RunPhase,
        task: AgentTask,
        taskEnv: [String: String],
        includeClaudeTeamFlag: Bool
    ) -> [String: String] {
        let prefixPaths = pathPrefix(for: task, taskEnv: taskEnv)
        var extraVars: [String: String] = [:]
        if includeClaudeTeamFlag {
            extraVars["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }
        for (key, value) in claudeProviderEnvironment() {
            extraVars[key] = value
        }
        for (key, value) in taskEnv {
            extraVars[key] = value
        }
        let env = RuntimeProcessEnvironment.enriched(
            additionalPaths: prefixPaths,
            extraVariables: extraVars
        )
        // Registered from the environment the subprocess actually gets, not
        // from the capability overlay that produced part of it.
        //
        // `enriched` starts from `ProcessInfo.processInfo.environment`, so
        // anything ASTRA was itself launched with is inherited by the agent —
        // and for a developer build started from a shell that exports
        // `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, that is a live provider
        // credential. Registering only `taskEnv` meant those were handed to the
        // agent and left out of the redaction set, so echoing one wrote it
        // straight into the transcript. The overlay is still registered where
        // it is built, because that is where the brokered strip has happened;
        // this adds what only the launch can see.
        RunSecretRedactionScope.register(taskID: task.id, environment: env)
        if !taskEnv.isEmpty {
            AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                "phase": phase.rawValue,
                "env_count": String(taskEnv.count)
            ])
        }
        return env
    }

    @MainActor
    static func pathPrefix(for task: AgentTask, taskEnv: [String: String]) -> [String] {
        var paths: [String] = []
        if let browserShimDirectory = prepareBrowserToolShimIfNeeded(task: task, taskEnv: taskEnv) {
            paths.append(browserShimDirectory)
        }
        if let sshShimDirectory = prepareSSHShimIfNeeded(task: task) {
            paths.append(sshShimDirectory)
        }
        return Array(Set(paths)).sorted()
    }

    @MainActor
    static func browserToolShimDirectory(for task: AgentTask, taskEnv: [String: String]) -> String? {
        guard taskEnv["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return nil }
        return (taskFolder as NSString).appendingPathComponent(".runtime-bin")
    }

    @MainActor
    static func prepareBrowserToolShimIfNeeded(
        task: AgentTask,
        taskEnv: [String: String],
        fileManager: FileManager = .default,
        realToolPath: String = (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent("astra-browser")
    ) -> String? {
        guard let endpoint = taskEnv["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty,
              endpoint.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        let browserToken = taskEnv["ASTRA_BROWSER_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if browserToken?.rangeOfCharacter(from: .newlines) != nil {
            return nil
        }
        let requiredEngine = taskEnv[BrowserAutomationEngineRequirement.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiredEngine?.rangeOfCharacter(from: .newlines) != nil {
            return nil
        }

        guard fileManager.isExecutableFile(atPath: realToolPath),
              realToolPath.rangeOfCharacter(from: .newlines) == nil,
              !TaskWorkspaceAccess(task: task).taskFolder.isEmpty else {
            return nil
        }

        let shimDirectory = (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent(".runtime-bin")
        let shimPath = (shimDirectory as NSString).appendingPathComponent("astra-browser")
        let requiredEngineExport = requiredEngine?.isEmpty == false
            ? "\nexport \(BrowserAutomationEngineRequirement.environmentKey)=\(shellSingleQuoted(requiredEngine!))"
            : ""
        let script = """
        #!/bin/sh
        export ASTRA_BROWSER_URL=\(shellSingleQuoted(endpoint))\(requiredEngineExport)
        exec \(shellSingleQuoted(realToolPath)) "$@"
        """

        do {
            try fileManager.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimDirectory)
            let existing = try? HostFileAccessBroker(fileManager: fileManager).readString(
                at: URL(fileURLWithPath: shimPath),
                encoding: .utf8,
                intent: .astraManagedStorage(root: URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder, isDirectory: true))
            )
            if existing != script {
                try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimPath)
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: task.id, fields: [
                "action": "browser_tool_shim",
                "result": "ready",
                "has_endpoint": "true",
                "has_token": String(browserToken?.isEmpty == false),
                "has_required_engine": String(requiredEngine?.isEmpty == false)
            ], level: .debug)
            return shimDirectory
        } catch {
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: task.id, fields: [
                "action": "browser_tool_shim",
                "result": "failed",
                "error": error.localizedDescription
            ], level: .warning)
            return nil
        }
    }

    @MainActor
    static func prepareSSHShimIfNeeded(
        task: AgentTask,
        fileManager: FileManager = .default,
        realSSHPath: String = "/usr/bin/ssh",
        hostKnownHostsPath: String = "\(NSHomeDirectory())/.ssh/known_hosts"
    ) -> String? {
        guard canInjectSSHShim(for: task, fileManager: fileManager, realSSHPath: realSSHPath) else {
            return nil
        }
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder

        let shimDirectory = (taskFolder as NSString).appendingPathComponent(".runtime-bin")
        let stateDirectory = (taskFolder as NSString).appendingPathComponent(".runtime-ssh")
        let shimPath = (shimDirectory as NSString).appendingPathComponent("ssh")
        let knownHostsPath = (stateDirectory as NSString).appendingPathComponent("known_hosts")
        let script = """
        #!/bin/sh
        exec \(shellSingleQuoted(realSSHPath)) -o UserKnownHostsFile=\(shellSingleQuoted(knownHostsPath)) -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o CheckHostIP=no "$@"
        """

        do {
            try fileManager.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimDirectory)
            try fileManager.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory)
            if !fileManager.fileExists(atPath: knownHostsPath) {
                if fileManager.fileExists(atPath: hostKnownHostsPath) {
                    try fileManager.copyItem(atPath: hostKnownHostsPath, toPath: knownHostsPath)
                } else {
                    try "".write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsPath)
            }

            let existing = try? HostFileAccessBroker(fileManager: fileManager).readString(
                at: URL(fileURLWithPath: shimPath),
                encoding: .utf8,
                intent: .astraManagedStorage(root: URL(fileURLWithPath: taskFolder, isDirectory: true))
            )
            if existing != script {
                try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimPath)
            AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                "source": "remote_workspace_ssh",
                "result": "ssh_shim_ready",
                "known_hosts": "task_scoped"
            ], level: .debug)
            return shimDirectory
        } catch {
            AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                "source": "remote_workspace_ssh",
                "result": "ssh_shim_failed",
                "error": error.localizedDescription
            ], level: .warning)
            return nil
        }
    }

    /// The shim's preconditions without writing it, so the launch can resolve
    /// the run's SSH route before the process (and the shim) exist.
    @MainActor
    static func canInjectSSHShim(
        for task: AgentTask,
        fileManager: FileManager = .default,
        realSSHPath: String = "/usr/bin/ssh"
    ) -> Bool {
        hasWorkspaceSSHConnections(for: task)
            && fileManager.isExecutableFile(atPath: realSSHPath)
            && realSSHPath.rangeOfCharacter(from: .newlines) == nil
            && !TaskWorkspaceAccess(task: task).taskFolder.isEmpty
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func cleanupBrowserToolShim(at directory: String?, taskID: UUID) {
        guard let directory, !directory.isEmpty else { return }
        do {
            try FileManager.default.removeItem(atPath: directory)
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: taskID, fields: [
                "action": "browser_tool_shim",
                "result": "cleaned"
            ], level: .debug)
        } catch {
            guard FileManager.default.fileExists(atPath: directory) else { return }
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: taskID, fields: [
                "action": "browser_tool_shim",
                "result": "cleanup_failed",
                "error": error.localizedDescription
            ], level: .warning)
        }
    }

    /// Resolves the Claude provider env vars from `@AppStorage` so the spawned
    /// `claude` CLI inherits the user's chosen routing (Anthropic vs Vertex).
    /// GUI apps don't pick up shell env from `.zshrc`, so this is the only
    /// place Vertex routing reaches the runtime.
    ///
    /// For Vertex, model aliases matter just as much as the routing flag —
    /// the Anthropic-format model IDs ASTRA passes via `--model` (e.g.
    /// `claude-haiku-4-5-20251001`) don't exist as-is on Vertex. The
    /// `ANTHROPIC_DEFAULT_*_MODEL` env vars remap them to Vertex aliases
    /// (e.g. `claude-haiku-4-5@20251001`). `ANTHROPIC_MODEL` and
    /// `ANTHROPIC_SMALL_FAST_MODEL` are auto-derived from the opus/haiku
    /// fields to match common Vertex setups.
    static func claudeProviderEnvironment() -> [String: String] {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: AppStorageKeys.claudeProvider) ?? ClaudeProvider.anthropic.rawValue
        guard let provider = ClaudeProvider(rawValue: raw) else { return [:] }
        switch provider {
        case .anthropic:
            return [:]
        case .vertex:
            let project = trimmedDefault(AppStorageKeys.claudeVertexProjectID)
            let region = trimmedDefault(AppStorageKeys.claudeVertexRegion)
            guard !project.isEmpty, !region.isEmpty else { return [:] }

            var env: [String: String] = [
                "CLAUDE_CODE_USE_VERTEX": "1",
                "ANTHROPIC_VERTEX_PROJECT_ID": project,
                "CLOUD_ML_REGION": region
            ]

            let opus = trimmedDefault(AppStorageKeys.claudeVertexOpusModel)
            let sonnet = trimmedDefault(AppStorageKeys.claudeVertexSonnetModel)
            let haiku = trimmedDefault(AppStorageKeys.claudeVertexHaikuModel)

            if !opus.isEmpty {
                env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus
                // ANTHROPIC_MODEL is the CLI's selected model when no --model
                // flag is passed. Mirror Anthropic's recommended setup where
                // it equals the opus alias.
                env["ANTHROPIC_MODEL"] = opus
            }
            if !sonnet.isEmpty {
                env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet
            }
            if !haiku.isEmpty {
                env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
                // The "small fast model" used internally by claude-code for
                // helper calls (title gen, summarisation). Pair with haiku.
                env["ANTHROPIC_SMALL_FAST_MODEL"] = haiku
            }

            return env
        }
    }

    private static func trimmedDefault(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When Vertex routing is on, translate an Anthropic-format model ID
    /// (e.g. `claude-haiku-4-5-20251001`) into the Vertex alias the user
    /// configured in Settings (e.g. `claude-haiku-4-5@20251001`).
    /// Tier is detected by family prefix (`haiku` / `sonnet` / `opus`).
    /// If Vertex is off, or no alias is set for that tier, the original
    /// model ID is returned unchanged so non-Vertex flows are untouched.
    ///
    /// `ANTHROPIC_DEFAULT_*_MODEL` env vars only kick in when the CLI is
    /// invoked with the bare tier name (`haiku`); ASTRA passes specific
    /// dated IDs via `--model`, so we have to do the substitution here.
    static func translatedModelForProvider(_ model: String) -> String {
        let raw = UserDefaults.standard.string(forKey: AppStorageKeys.claudeProvider)
            ?? ClaudeProvider.anthropic.rawValue
        guard ClaudeProvider(rawValue: raw) == .vertex else { return model }

        let lower = model.lowercased()
        let key: String
        if lower.hasPrefix("claude-haiku") {
            key = AppStorageKeys.claudeVertexHaikuModel
        } else if lower.hasPrefix("claude-sonnet") {
            key = AppStorageKeys.claudeVertexSonnetModel
        } else if lower.hasPrefix("claude-opus") {
            key = AppStorageKeys.claudeVertexOpusModel
        } else {
            return model
        }

        let alias = trimmedDefault(key)
        return alias.isEmpty ? model : alias
    }

    @MainActor
    static func scopedEnvironmentVariables(
        for task: AgentTask,
        contextText: String = "",
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        runtimeRequirements: TaskRuntimeRequirementSet? = nil
    ) -> [String: String] {
        let capabilityScope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? [],
            turnIntentSnapshot: executionPolicy.turnIntentSnapshot,
            runtime: executionPolicy.launchSnapshot?.runtimeID
                .flatMap(AgentRuntimeID.init(rawValue:))
        ).providerLaunch
        return scopedEnvironmentVariables(
            for: task,
            capabilityScope: capabilityScope,
            contextText: contextText,
            executionPolicy: executionPolicy,
            runtimeRequirements: runtimeRequirements
        )
    }

    @MainActor
    static func scopedEnvironmentVariables(
        for task: AgentTask,
        capabilityScope: TaskCapabilityPromptScope,
        contextText: String = "",
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        // Intentionally unread: a brokered connector's credentials are stripped
        // from the scope the broker owns them for, not from the scope the
        // runtime managed to deliver the tool to.
        runtimeRequirements _: TaskRuntimeRequirementSet? = nil
    ) -> [String: String] {
        var taskEnv = capabilityScope.resolver.resolvedEnvironmentVariables
        BrokeredConnectorEnvironment.strip(from: &taskEnv, capabilityScope: capabilityScope)
        if capabilityScope.exposesBrowserBridge ||
            TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) {
            for (key, value) in ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id) {
                guard isBrowserBridgeEnvKeyAllowed(key) else {
                    AppLogger.audit(.capabilityChatContext, category: "Capabilities", taskID: task.id, fields: [
                        "source": "browser_bridge_env",
                        "result": "non_namespaced_key_dropped",
                        "key": key
                    ], level: .warning)
                    continue
                }
                taskEnv[key] = value
            }
            if let requiredEngine = BrowserAutomationEngineRequirement.requiredEngine(for: task, contextText: contextText) {
                taskEnv[BrowserAutomationEngineRequirement.environmentKey] = requiredEngine.rawValue
            }
        }
        // Post-strip, so what the persistence funnel later redacts is exactly
        // what this launch can leak - no brokered secret the agent never saw.
        RunSecretRedactionScope.register(taskID: task.id, environment: taskEnv)
        return taskEnv
    }

    @MainActor
    static func hostControlCLIRelayEnvironment(
        context: AgentRuntimeProcessLaunchContext,
        runtime: AgentRuntimeID
    ) -> [String: String] {
        // Offered, not required: the broker session is started for every tool
        // the run offers, so requiring here would leave `astra-host-control
        // jira` with no socket on exactly the turns that never narrate it.
        guard AgentRuntimeCapabilityProfileService.defaultProfile(for: runtime).usesHostControlCLIRelay,
              context.runtimeRequirements?.offersHostControlPlane == true else { return [:] }
        let environment = HostControlPlaneMCPProjection.environmentVariables(
            task: context.task,
            environment: DockerExecutionPlanner.resolveEnvironment(for: context.task),
            currentDirectory: context.workspacePath,
            runID: context.runID,
            contextText: context.contextText,
            capabilityScope: context.capabilityResolutionSnapshot.providerLaunch,
            precomputedRuntimeRequirements: context.runtimeRequirements
        )
        guard environment[HostControlBrokerIPC.endpointEnvironmentKey]?.isEmpty == false else {
            return [:]
        }
        return environment
    }

    @MainActor
    static func hasWorkspaceSSHConnections(for task: AgentTask) -> Bool {
        guard let workspace = task.workspace else { return false }
        return SSHConnectionManager.hasStoredConnections(workspacePath: workspace.primaryPath)
    }

    /// Namespace invariant for the Shelf browser bridge: it may only
    /// contribute its own `ASTRA_BROWSER_*` variables, never overwrite
    /// PATH/HOME or connector credentials. The trailing underscore keeps the
    /// namespace explicit so an unrelated future `ASTRA_BROWSERX` key can't
    /// slip through.
    static func isBrowserBridgeEnvKeyAllowed(_ key: String) -> Bool {
        key.hasPrefix("ASTRA_BROWSER_")
    }

    @MainActor
    static func hasActiveCLITools(
        _ task: AgentTask,
        contextText: String = "",
        capabilityScope: TaskCapabilityPromptScope? = nil
    ) -> Bool {
        let scope = capabilityScope ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        return scope.reachableLocalTools.contains { tool in
            tool.toolType != "mcp" && !tool.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }


}

extension AgentRuntimeProcessRunner: AgentRuntimeProcessRunning {}
