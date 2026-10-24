import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Immutable launch inputs and a durable event sink; no second task-status store.
struct RuntimeSupervisionContext {
    let goal: String
    let runtime: String
    let taskFolder: String
    let remoteCoverage: String
    let investigator: RuntimeSupervisionSession.Investigator
    let report: @Sendable (RuntimeSupervisionReport) -> Void
    var collector: (@Sendable () async -> RuntimeSupervisionFiles)? = nil
    var workspacePath: String? = nil
    var tokenReservation = 16_384
    var recovery: RuntimeRecoveryContext?

    func captureFiles() async -> RuntimeSupervisionFiles {
        if let collector { return await collector() }
        var files = await RuntimeSupervisionFileCollector.capture(root: taskFolder)
        guard let workspacePath, workspacePath != taskFolder, !Task.isCancelled else { return files }
        let workspace = await RuntimeSupervisionFileCollector.captureWorkspace(root: workspacePath)
        let notes = [files.unavailable, workspace.unavailable].compactMap { $0 }
        files.metadata = Dictionary(uniqueKeysWithValues: files.metadata.map { ("task/" + $0.key, $0.value) })
        for (path, value) in workspace.metadata { files.metadata["workspace/" + path] = value }
        files.coverageNotes = notes
        if files.unavailable == nil || workspace.unavailable == nil { files.unavailable = nil }
        return files
    }

    @MainActor
    static func make(task: AgentTask, run: TaskRun, modelContext: ModelContext,
                     runtime: AgentRuntimeID, configuration: AgentUtilityRuntimeConfiguration,
                     pendingEvents: OrderedMainActorTaskQueue, remoteRoute: RemoteWorkspaceSSHRoute?,
                     turnIntent: TaskTurnIntentSnapshot? = nil,
                     workspacePath: String? = nil,
                     investigatorOverride: RuntimeSupervisionSession.Investigator? = nil,
                     executionOwner: RuntimeExecutionOwner? = nil) -> Self {
        let blocked = RuntimeSensitiveDataLaunchGate.block(task: task, requestedRuntime: runtime,
            launchRuntime: configuration.runtime) != nil
        let sharedStateConflict = runtime == .antigravityCLI && configuration.runtime == .antigravityCLI
        let unsupportedInvestigator = ClaudeCodeUtilityLaunchPolicy.investigationUnavailableReason(for: configuration.runtime)
        let authorizeRecovery: @MainActor @Sendable (RuntimeRecoveryReport) -> Bool = { report in
            guard executionOwner?.permitsSuspendedRecovery(runID: run.id) ?? true else { return false }
            return RuntimeRecoveryService.authorize(report, task: task, run: run, modelContext: modelContext)
        }
        let recordRecovery: @MainActor @Sendable (RuntimeRecoveryReport) -> Void = { report in
            RuntimeRecoveryService.record(report, task: task, run: run, modelContext: modelContext)
        }
        return Self(goal: RunSecretRedactionScope.redact(turnIntent?.activationText ?? task.goal, taskID: task.id), runtime: runtime.rawValue,
             taskFolder: TaskWorkspaceAccess(task: task).taskFolder,
             remoteCoverage: remoteRoute == nil
                ? "No authorized remote inspection target is configured. Remote activity is unknown."
                : "Remote files are not inspected by this collector. Only reported managed-job evidence is available; remote activity is otherwise unknown.",
             investigator: { evidence in
                 if let investigatorOverride { return await investigatorOverride(evidence) }
                 guard !blocked else { return .inconclusive("The configured investigator is not approved for this task's sensitive data.") }
                 guard !sharedStateConflict else { return .inconclusive("This verifier shares the running provider's model-settings lock. Choose a different provider for the Verifier role to enable independent investigation.") }
                 if let unsupportedInvestigator { return .inconclusive(unsupportedInvestigator) }
                 return await RuntimeSupervisionInvestigator.assess(evidence, configuration: configuration)
             },
             report: { report in
                 pendingEvents.add {
                     guard run.task?.id == task.id else { return }
                     var report = report
                     report.investigatorRuntime = configuration.runtime.rawValue
                     report.investigatorModel = configuration.model
                     let encoder = JSONEncoder()
                     encoder.outputFormatting = [.sortedKeys]
                     guard let data = try? encoder.encode(report), let payload = String(data: data, encoding: .utf8) else { return }
                     modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeSupervision,
                         payload: RunSecretRedactionScope.redact(payload, taskID: task.id), run: run))
                     modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
                         payload: RunSecretRedactionScope.redact(report.message, taskID: task.id), run: run))
                     WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext,
                         taskID: task.id, auditFields: ["operation": "runtime_supervision", "attempt_id": report.attemptID.uuidString])
                 }
             }, workspacePath: workspacePath,
             tokenReservation: investigatorOverride == nil && (blocked || sharedStateConflict || unsupportedInvestigator != nil) ? 0 : 16_384,
             recovery: .init(authorize: { report in
                 await pendingEvents.drainAll()
                 return await authorizeRecovery(report)
             }, report: { report in
                 pendingEvents.add { recordRecovery(report) }
             }))
    }
}
