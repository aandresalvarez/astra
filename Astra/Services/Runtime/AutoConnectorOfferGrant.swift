import Foundation
import SwiftData
import ASTRACore
import ASTRALogging
import ASTRAModels

/// Auto answers the connector credential offers still open on the task — left
/// by an Ask run, or by a run that did not finish cleanly — at its next launch,
/// as "Allow for this task" would. The grant, the closed offers and the chat
/// line are saved together, or all rolled back with the offers left open.
@MainActor
enum AutoConnectorOfferGrant {
    /// The number of offers granted and closed; zero when there were none or
    /// the grant could not be saved.
    @discardableResult
    static func grantOpenOffers(
        task: AgentTask,
        run: TaskRun,
        runtime: AgentRuntimeID,
        modelContext: ModelContext,
        persist: @MainActor (AgentTask, ModelContext) -> Bool
    ) -> Int {
        let offers = TaskRuntimePermissionOpenRequestStore.openConnectorCredentialOffers(for: task)
        let grants = offers.flatMap(\.grants)
        guard !grants.isEmpty else { return 0 }
        let grantsBefore = task.runtimePermissionGrantsJSON
        let openRequestsBefore = task.runtimePermissionOpenRequestsJSON
        let eventsBefore = Set(task.events.map(\.id))
        guard !TaskRuntimePermissionGrants.record(
            grants: grants, providerID: runtime, task: task, modelContext: modelContext, source: "auto_policy"
        ).isEmpty else {
            return 0
        }
        let closed = TaskRuntimePermissionOpenRequestStore.closeConnectorCredentialOffers(for: task)
        // The connectors' own names; an offer's display name is a sentence.
        let labels = grants.compactMap { grant -> String? in
            if case .credential(let label) = grant { return label } else { return nil }
        }
        let connectorNames = ConnectorRuntimeProjection.connectorIDs(inCredentialLabels: labels).compactMap { id in
            task.workspace?.connectors.first { $0.id == id }?.name
        }
        let names = connectorNames.isEmpty ? offers.map(\.displayName) : connectorNames
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: "Auto allowed \(ConnectorRuntimeProjection.joinedNames(names)) to use "
                + "\(names.count > 1 ? "their" : "its") saved credentials for this task.",
            run: run
        ))
        guard persist(task, modelContext) else {
            task.runtimePermissionGrantsJSON = grantsBefore
            task.runtimePermissionOpenRequestsJSON = openRequestsBefore
            let added = task.events.filter { !eventsBefore.contains($0.id) }
            task.events.removeAll { !eventsBefore.contains($0.id) }
            added.forEach(modelContext.delete)
            AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: [
                "source": "auto_connector_offer_grant",
                "result": "grant_unpersisted"
            ], level: .error)
            return 0
        }
        return closed
    }
}
