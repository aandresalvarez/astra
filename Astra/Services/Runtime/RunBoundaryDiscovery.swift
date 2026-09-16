import Foundation
import SwiftData
import ASTRALogging
import ASTRAModels
import ASTRAPersistence

/// Everything a finished run left for the user to decide, collected in one pass.
///
/// A run can leave two kinds of unfinished business behind, and neither one
/// announces itself over the stream. The agent can stage a connector write that
/// only the app may send. And the agent can reach for a brokered connector whose
/// saved credentials this turn's wording did not unseal, which is the run asking
/// for something the launch had no way to know it would want.
///
/// Both are found by looking, once, at the boundary. Once because a scan on
/// every dock rebuild would put filesystem work inside a SwiftUI view body, and
/// at the boundary because that is the first moment the run is done producing
/// them. They are collected together so the worker has one place to call and one
/// place to persist, rather than each new kind of unfinished business costing
/// another branch in the outcome path.
@MainActor
enum RunBoundaryDiscovery {
    static func recordWhatTheRunLeftForTheUser(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        let discovered = ConnectorMutationDiscovery.recordStagedMutations(
            task: task,
            run: run,
            modelContext: modelContext
        )
        // Saved here rather than left to `finalizeAndPersist`. A successful run
        // goes on to tests, an AI check, baseline verification, and a handoff
        // scan, all of them `await`s that can run for minutes — and until the
        // save these events exist only in the `ModelContext`. If ASTRA exits
        // during one of them the agent has already been told the proposal was
        // staged, but the durable pending event is gone, and nothing rescans the
        // directory at startup: the proposal stays invisible until some later
        // run happens to finish. The write is on disk; this is what makes the
        // record of it match.
        if !discovered.isEmpty {
            let persisted = WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: [
                    "operation": "connector_mutation_discovery",
                    "count": String(discovered.count)
                ]
            )
            if !persisted {
                AppLogger.audit(.dataStoreRecovered, category: "Worker", taskID: task.id, fields: [
                    "operation": "connector_mutation_discovery_unpersisted",
                    "count": String(discovered.count)
                ], level: .error)
            }
        }
        // Persists itself, for the same reason: an approval offer the user never
        // sees is a connector that stays sealed with no way to unseal it.
        BrokeredCredentialApprovalDiscovery.recordWithheldCredentialRequests(
            task: task,
            run: run,
            modelContext: modelContext
        )
    }
}
