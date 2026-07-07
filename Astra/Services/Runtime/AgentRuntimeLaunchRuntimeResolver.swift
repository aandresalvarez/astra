import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

enum AgentRuntimeLaunchRuntimeResolver {
    struct LaunchRuntimeResolution {
        let requestedRuntime: AgentRuntimeID
        let runtime: AgentRuntimeID
        let requirements: TaskRuntimeRequirementSet
        let incompatibilities: [AgentRuntimeID: [TaskRuntimeIncompatibility]]
        let launchBlock: TaskRuntimeCompatibilityLaunchBlock?
        let selectedRuntimeEvidence: [String]

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
        executionPolicy: AgentRuntimeExecutionPolicy
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
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? []
        )
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)
        let taskEnvironment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: task,
            capabilityScope: snapshot.providerLaunch,
            contextText: contextText,
            executionPolicy: executionPolicy
        )
        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: executionEnvironment,
            browserBridgeAttached: BrowserBridgeRuntimeLaunchGuard.isBrowserBridgeAttached(environment: taskEnvironment)
        )
        let profiles = RuntimeProfileCache(configuration: runtimeConfiguration)
        let resolution = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: requestedRuntime,
            defaultRuntime: runtimeConfiguration.defaultRuntimeID,
            requirements: requirements,
            profile: { runtime in
                profiles.profile(for: runtime)
            },
            isRuntimeUsable: { runtime in
                runtimeIsExecutable(runtime, configuration: runtimeConfiguration)
            }
        )
        return LaunchRuntimeResolution(
            requestedRuntime: resolution.requestedRuntime,
            runtime: resolution.selectedRuntime,
            requirements: resolution.requirements,
            incompatibilities: resolution.incompatibilities,
            launchBlock: resolution.launchBlock,
            selectedRuntimeEvidence: profiles.profile(for: resolution.selectedRuntime).observedEvidence
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
                launchBlock: resolution.launchBlock
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
            launchBlock: resolution.launchBlock
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
