import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum AgentRuntimeLaunchRuntimeResolver {
    struct LaunchRuntimeResolution {
        let requestedRuntime: AgentRuntimeID
        let runtime: AgentRuntimeID
        let requirements: TaskRuntimeRequirementSet
        let incompatibilities: [AgentRuntimeID: [TaskRuntimeIncompatibility]]
        let launchBlock: TaskRuntimeCompatibilityLaunchBlock?
        let selectedRuntimeEvidence: [String]
        let capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
        let contractDigest: String

        var rerouted: Bool {
            runtime != requestedRuntime
        }
    }

    struct AppliedRuntimeResolution {
        let runtime: AgentRuntimeID
        let reroutedFrom: AgentRuntimeID?
        let requirements: TaskRuntimeRequirementSet
        let missingCapabilities: [String]
        let selectedRuntimeEvidence: [String]
        let launchBlock: TaskRuntimeCompatibilityLaunchBlock?
        let capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
        let contractDigest: String
    }

    /// Persisted tasks can outlive the runtime provider that created them.
    /// Normalize that stale value at launch admission so every downstream
    /// consumer observes the same registered runtime selected by configuration.
    @MainActor
    @discardableResult
    static func reconcilePersistedRuntime(
        task: AgentTask,
        selectedRuntime: AgentRuntimeID,
        phase: RunPhase
    ) -> Bool {
        guard task.runtimeID != selectedRuntime.rawValue else { return false }

        let previousRuntime = task.runtimeID ?? "none"
        let clearedExplicitRuntimeSelection = task.runtimeExplicitlySelected
        task.runtimeID = selectedRuntime.rawValue
        task.runtimeExplicitlySelected = false
        task.updatedAt = Date()
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "event": "runtime_registration_fallback",
            "from_runtime": previousRuntime,
            "to_runtime": selectedRuntime.rawValue,
            "cleared_explicit_runtime_selection": String(clearedExplicitRuntimeSelection),
            "phase": phase.rawValue,
            "reason": "persisted_runtime_unregistered_or_noncanonical"
        ], level: .warning)
        return true
    }

    @MainActor
    static func resolve(
        task: AgentTask,
        requestedRuntime: AgentRuntimeID,
        runtimeConfiguration: AgentRuntimeConfiguration,
        promptOverride: String?,
        startEventPayload: String?,
        sessionMessage: String?,
        phase: RunPhase,
        executionPolicy: AgentRuntimeExecutionPolicy,
        fallbackPermissionPolicy: PermissionPolicy = .restricted,
        defaultPolicyLevelRaw: String = AgentPolicyLevel.review.rawValue
    ) -> LaunchRuntimeResolution {
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: requestedRuntime)
        let startPayload = startEventPayload ?? adapter.defaultStartEventPayload(task: task)
        let contextText = adapter.connectorPreflightContextText(
            task: task,
            promptOverride: promptOverride,
            startPayload: startPayload,
            sessionMessage: sessionMessage,
            phase: phase
        )
        let intent = executionPolicy.turnIntentSnapshot ?? TaskTurnIntentResolver.capture(
            for: task,
            sourceEventID: nil,
            acceptedTurn: sessionMessage ?? contextText,
            includeTaskInputs: phase == .run
        )
        let admission = TaskLaunchAdmissionService.evaluate(
            task: task,
            intent: intent,
            requestedRuntime: requestedRuntime,
            runtimeConfiguration: runtimeConfiguration,
            executionPolicy: executionPolicy.withTurnIntentSnapshot(intent),
            fallbackPermissionPolicy: fallbackPermissionPolicy,
            defaultPolicyLevelRaw: defaultPolicyLevelRaw,
            phase: phase,
            secretStore: KeychainSecretStore(),
            profile: { runtime, settings in
                AgentRuntimeCapabilityProfileService.profile(
                    for: runtime,
                    executablePath: settings.executablePath
                )
            },
            isRuntimeUsable: { runtime, _ in
                runtimeIsExecutable(runtime, configuration: runtimeConfiguration)
            }
        )
        let selectedCandidate = admission.selectedCandidate
        return LaunchRuntimeResolution(
            requestedRuntime: admission.requestedRuntime,
            runtime: admission.selectedRuntime,
            requirements: selectedCandidate.requirements,
            incompatibilities: admission.candidates.mapValues { $0.incompatibilities },
            launchBlock: admission.launchBlock,
            selectedRuntimeEvidence: selectedCandidate.runtimeEvidence,
            capabilityResolutionSnapshot: selectedCandidate.capabilityResolutionSnapshot,
            contractDigest: selectedCandidate.contractDigest
        )
    }

    @MainActor
    static func apply(
        _ resolution: LaunchRuntimeResolution,
        task: AgentTask,
        phase: RunPhase,
        alignModel: (AgentRuntimeID) -> Void,
        clearMismatchedSession: (AgentRuntimeID) -> Void
    ) -> AppliedRuntimeResolution {
        let missingCapabilities = missingCapabilityNames(for: resolution)
        guard resolution.rerouted else {
            return AppliedRuntimeResolution(
                runtime: resolution.runtime,
                reroutedFrom: nil,
                requirements: resolution.requirements,
                missingCapabilities: missingCapabilities,
                selectedRuntimeEvidence: resolution.selectedRuntimeEvidence,
                launchBlock: resolution.launchBlock,
                capabilityResolutionSnapshot: resolution.capabilityResolutionSnapshot,
                contractDigest: resolution.contractDigest
            )
        }

        task.runtimeID = resolution.runtime.rawValue
        alignModel(resolution.runtime)
        clearMismatchedSession(resolution.runtime)
        task.updatedAt = Date()
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "event": "runtime_compatibility_reroute",
            "from_runtime": resolution.requestedRuntime.rawValue,
            "to_runtime": resolution.runtime.rawValue,
            "required_capabilities": resolution.requirements.missingCapabilityNames.joined(separator: ","),
            "missing_capabilities": missingCapabilities.joined(separator: ","),
            "selected_runtime_evidence": resolution.selectedRuntimeEvidence.joined(separator: ","),
            "phase": phase.rawValue
        ], level: .info)
        return AppliedRuntimeResolution(
            runtime: resolution.runtime,
            reroutedFrom: resolution.requestedRuntime,
            requirements: resolution.requirements,
            missingCapabilities: missingCapabilities,
            selectedRuntimeEvidence: resolution.selectedRuntimeEvidence,
            launchBlock: resolution.launchBlock,
            capabilityResolutionSnapshot: resolution.capabilityResolutionSnapshot,
            contractDigest: resolution.contractDigest
        )
    }

    static func insertRerouteEventIfNeeded(
        _ applied: AppliedRuntimeResolution,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard let reroutedFrom = applied.reroutedFrom else { return }
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: rerouteEventPayload(
                from: reroutedFrom,
                to: applied.runtime,
                missingCapabilities: applied.missingCapabilities,
                selectedRuntimeEvidence: applied.selectedRuntimeEvidence
            ),
            run: run
        ))
    }

    @MainActor
    static func runtimeIsExecutable(
        _ runtime: AgentRuntimeID,
        configuration: AgentRuntimeConfiguration
    ) -> Bool {
        let settings = AgentRuntimeAdapterRegistry
            .adapter(for: runtime)
            .launchSettings(configuration: configuration)
        return FileManager.default.isExecutableFile(atPath: settings.executablePath)
    }

    static func rerouteEventPayload(
        from requestedRuntime: AgentRuntimeID,
        to runtime: AgentRuntimeID,
        missingCapabilities: [String],
        selectedRuntimeEvidence: [String] = []
    ) -> String {
        let capabilities = missingCapabilities.isEmpty
            ? "the selected task capabilities"
            : missingCapabilities.joined(separator: ", ")
        let evidence = selectedRuntimeEvidence.isEmpty
            ? ""
            : " \(runtime.displayName) compatibility evidence: \(selectedRuntimeEvidence.joined(separator: ", "))."
        return "Runtime changed from \(requestedRuntime.displayName) to \(runtime.displayName) because the task requires ASTRA capabilities unavailable to the selected runtime: \(capabilities).\(evidence)"
    }

    private static func missingCapabilityNames(for resolution: LaunchRuntimeResolution) -> [String] {
        let missing = resolution.incompatibilities[resolution.requestedRuntime]?.map(\.userFacingName) ?? []
        return missing.isEmpty ? resolution.requirements.missingCapabilityNames : missing
    }
}

private final class RuntimeProfileCache {
    private let configuration: AgentRuntimeConfiguration
    private var profiles: [AgentRuntimeID: AgentRuntimeCapabilityProfile] = [:]

    init(configuration: AgentRuntimeConfiguration) {
        self.configuration = configuration
    }

    func profile(for runtime: AgentRuntimeID) -> AgentRuntimeCapabilityProfile {
        if let profile = profiles[runtime] {
            return profile
        }
        let settings = AgentRuntimeAdapterRegistry.adapter(for: runtime)
            .launchSettings(configuration: configuration)
        let profile = AgentRuntimeCapabilityProfileService.profile(
            for: runtime,
            executablePath: settings.executablePath
        )
        profiles[runtime] = profile
        return profile
    }
}
