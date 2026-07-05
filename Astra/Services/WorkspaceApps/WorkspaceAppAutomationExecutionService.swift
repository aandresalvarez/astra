import Foundation
import SwiftData

struct WorkspaceAppAutomationExecutionResult: Equatable {
    var automationID: String
    var actionID: String
    var runID: UUID?
    var status: WorkspaceAppRunStatus
    var errorMessage: String?
}

struct WorkspaceAppAutomationExecutionService {
    var scheduler = WorkspaceAppAutomationScheduler()
    var actionExecutor = WorkspaceAppActionExecutor()

    @MainActor
    func runDueAutomations(
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws -> [WorkspaceAppAutomationExecutionResult] {
        let states = try automationStates(for: app, modelContext: modelContext)
        let specsByID = Dictionary(uniqueKeysWithValues: manifest.automations.map { ($0.id, $0) })
        let statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.automationID, $0) })
        let due = scheduler.dueAutomations(manifest: manifest, states: states, now: now)
        guard !due.isEmpty else { return [] }
        let dependencyBindings = try dependencyBindings(for: app, modelContext: modelContext)

        var results: [WorkspaceAppAutomationExecutionResult] = []
        for automation in due {
            guard let state = statesByID[automation.automationID],
                  let spec = specsByID[automation.automationID] else {
                continue
            }
            do {
                let result = try actionExecutor.execute(
                    actionID: automation.actionID,
                    app: app,
                    workspace: workspace,
                    manifest: manifest,
                    dependencyBindings: dependencyBindings,
                    trigger: .automation,
                    modelContext: modelContext
                )
                scheduler.markRunCompleted(automation: state, spec: spec, completedAt: now)
                results.append(WorkspaceAppAutomationExecutionResult(
                    automationID: automation.automationID,
                    actionID: automation.actionID,
                    runID: result.run.id,
                    status: result.run.status,
                    errorMessage: nil
                ))
                auditAutomationExecution(
                    app: app,
                    workspace: workspace,
                    automationID: automation.automationID,
                    actionID: automation.actionID,
                    result: "completed"
                )
            } catch {
                state.status = .blocked
                state.updatedAt = now
                results.append(WorkspaceAppAutomationExecutionResult(
                    automationID: automation.automationID,
                    actionID: automation.actionID,
                    runID: latestRunID(app: app, actionID: automation.actionID, modelContext: modelContext),
                    status: .blocked,
                    errorMessage: error.localizedDescription
                ))
                auditAutomationExecution(
                    app: app,
                    workspace: workspace,
                    automationID: automation.automationID,
                    actionID: automation.actionID,
                    result: "blocked"
                )
            }
        }

        app.updatedAt = now
        workspace.updatedAt = now
        // Immediate durable save: the scheduler state written here (markRunCompleted /
        // blocked) gates whether the next sweep re-runs these automations.
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: workspace, modelContext: modelContext)
        return results
    }

    private func auditAutomationExecution(
        app: WorkspaceApp,
        workspace: Workspace,
        automationID: String,
        actionID: String,
        result: String
    ) {
        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_automation",
            "result": result,
            "app_id": app.logicalID,
            "automation_id": automationID,
            "action_id": actionID,
            "workspace_id": workspace.id.uuidString
        ])
    }

    @MainActor
    private func automationStates(
        for app: WorkspaceApp,
        modelContext: ModelContext
    ) throws -> [WorkspaceAppAutomationState] {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppAutomationState>(
            predicate: #Predicate<WorkspaceAppAutomationState> { automation in
                automation.appID == appID
            },
            sortBy: [SortDescriptor(\.automationID)]
        )
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    private func dependencyBindings(
        for app: WorkspaceApp,
        modelContext: ModelContext
    ) throws -> [WorkspaceAppDependencyBinding] {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppDependencyBinding>(
            predicate: #Predicate<WorkspaceAppDependencyBinding> { binding in
                binding.appID == appID
            },
            sortBy: [SortDescriptor(\.requirementID)]
        )
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    private func latestRunID(
        app: WorkspaceApp,
        actionID: String,
        modelContext: ModelContext
    ) -> UUID? {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppRun>(
            predicate: #Predicate<WorkspaceAppRun> { run in
                run.appID == appID && run.actionID == actionID
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first?.id
    }
}
