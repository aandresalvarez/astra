import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension AgentRuntimeWorker {
    var connectorPreflightTestingOverride: (() async -> Bool)? {
#if DEBUG
        connectorPreflightOverrideForTesting
#else
        nil
#endif
    }
}

enum AgentRuntimeConnectorPreflight {
    static func passed(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        contextText: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot,
        precomputedRuntimeRequirements: TaskRuntimeRequirementSet,
        runtimeConfiguration: AgentRuntimeConfiguration,
        preflightCache: PreflightCache,
        capabilityWorkingDirectory: String,
        mcpDetectExecutable: (String) -> String,
        mcpIsExecutableFile: (String) -> Bool,
        testingOverride: (() async -> Bool)?
    ) async -> Bool {
#if DEBUG
        if let testingOverride { return await testingOverride() }
#endif
        return await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            contextText: contextText,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            precomputedRuntimeRequirements: precomputedRuntimeRequirements,
            runtimeConfiguration: runtimeConfiguration,
            preflightCache: preflightCache,
            capabilityWorkingDirectory: capabilityWorkingDirectory,
            mcpDetectExecutable: mcpDetectExecutable,
            mcpIsExecutableFile: mcpIsExecutableFile
        )
    }
}
