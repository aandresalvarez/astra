import Foundation
import SwiftData
import ASTRACore

enum AgentRuntimeLaunchRuntimeResolver {
    struct AppliedRuntimeResolution {
        let runtime: AgentRuntimeID
        let reroutedFrom: AgentRuntimeID?
        let requiredTools: [String]
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
    ) -> AgentRuntimeCapabilityCompatibilityPolicy.LaunchRuntimeResolution {
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
        return AgentRuntimeCapabilityCompatibilityPolicy.resolveLaunchRuntime(
            requestedRuntime: requestedRuntime,
            defaultRuntime: runtimeConfiguration.defaultRuntimeID,
            task: task,
            capabilityResolutionSnapshot: snapshot,
            isRuntimeUsable: { runtime in
                runtimeIsExecutable(runtime, configuration: runtimeConfiguration)
            }
        )
    }

    @MainActor
    static func apply(
        _ resolution: AgentRuntimeCapabilityCompatibilityPolicy.LaunchRuntimeResolution,
        task: AgentTask,
        phase: RunPhase,
        alignModel: (AgentRuntimeID) -> Void,
        clearMismatchedSession: (AgentRuntimeID) -> Void
    ) -> AppliedRuntimeResolution {
        guard resolution.rerouted else {
            return AppliedRuntimeResolution(runtime: resolution.runtime, reroutedFrom: nil, requiredTools: [])
        }

        task.runtimeID = resolution.runtime.rawValue
        alignModel(resolution.runtime)
        clearMismatchedSession(resolution.runtime)
        task.updatedAt = Date()
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "event": "runtime_compatibility_reroute",
            "from_runtime": resolution.requestedRuntime.rawValue,
            "to_runtime": resolution.runtime.rawValue,
            "required_host_control_tools": resolution.requiredTools.joined(separator: ","),
            "phase": phase.rawValue
        ], level: .info)
        return AppliedRuntimeResolution(
            runtime: resolution.runtime,
            reroutedFrom: resolution.requestedRuntime,
            requiredTools: resolution.requiredTools
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
                requiredTools: applied.requiredTools
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
        requiredTools: [String]
    ) -> String {
        let tools = requiredTools.isEmpty
            ? "the selected task capabilities"
            : requiredTools.joined(separator: ", ")
        return "Runtime changed from \(requestedRuntime.displayName) to \(runtime.displayName) because the task requires ASTRA capabilities unavailable to the selected runtime: \(tools)."
    }
}
