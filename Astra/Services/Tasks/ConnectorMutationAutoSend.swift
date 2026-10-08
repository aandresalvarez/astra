import Foundation
import SwiftData
import ASTRACore
import ASTRALogging
import ASTRAModels

/// Sends, at the run boundary, the connector writes an Auto run staged.
///
/// Auto asks nothing, so the review sheet that stands between a staged Jira
/// proposal and the write is skipped — not the checks behind it. Each proposal
/// goes through `ConnectorMutationCoordinator.prepare` and `send` exactly as an
/// approved one does: the staged bytes are re-read against their digest, the
/// route comes from ASTRA's table, the destination is re-resolved, the send is
/// reserved before dispatch, and an ambiguous outcome is quarantined rather
/// than retried. The receipt says Auto sent it, and the chat shows it.
///
/// Only proposals the run itself staged are sent. The broker names each file
/// after the run that wrote it, and a proposal an Ask run left for review stays
/// that run's question after the task switches to Auto.
@MainActor
enum ConnectorMutationAutoSend {
    /// Called from settlement, never at the run boundary: the provider result
    /// and the staged proposals are durable before anything leaves the
    /// machine, so an exit mid-send pauses for reconciliation instead of
    /// losing the run, and an exit before it lets recovery send what is still
    /// pending. Only proposals that are still pending are read, and a reserved
    /// or receipted one is never sent twice.
    @discardableResult
    static func sendPendingMutations(
        task: AgentTask,
        run: TaskRun,
        policyLevel: AgentPolicyLevel,
        modelContext: ModelContext,
        coordinator: ConnectorMutationCoordinator? = nil
    ) async -> [ConnectorMutationReceipt] {
        guard !ExternalActionPolicy.asksUser(for: .connectorMutation, level: policyLevel) else { return [] }
        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task).filter { $0.runID == run.id }
        guard !pending.isEmpty else { return [] }
        return await sendStagedMutations(
            pending,
            task: task,
            run: run,
            policyLevel: policyLevel,
            modelContext: modelContext,
            coordinator: coordinator ?? ConnectorMutationCoordinator(modelContext: modelContext)
        )
    }

    @discardableResult
    static func sendStagedMutations(
        _ staged: [TaskStagedConnectorMutation],
        task: AgentTask,
        run: TaskRun,
        policyLevel: AgentPolicyLevel,
        modelContext: ModelContext,
        coordinator: ConnectorMutationCoordinator
    ) async -> [ConnectorMutationReceipt] {
        guard !ExternalActionPolicy.asksUser(for: .connectorMutation, level: policyLevel) else { return [] }
        let ownMarker = "-\(run.id.uuidString)-"
        let own = inStagingOrder(staged.filter {
            $0.runID == run.id
                && URL(fileURLWithPath: $0.stagedPayloadPath).lastPathComponent.contains(ownMarker)
        })
        var receipts: [ConnectorMutationReceipt] = []
        for pending in own {
            do {
                let proposal = try coordinator.prepare(task: task, pending: pending)
                receipts.append(try await coordinator.send(task: task, proposal: proposal, authorization: .autoPolicy))
            } catch {
                // Proposals inside one run are commonly dependent — the story
                // names the epic before it — so the first one that does not go
                // out stops the rest. They stay in the dock, reviewable (a
                // terminal outcome quarantines the one that stopped), and the
                // chat says why Auto stopped.
                let remaining = own.count - receipts.count
                AppLogger.audit(.connectorTested, category: "Tasks", taskID: task.id, fields: [
                    "source": "connector_mutation_auto_send",
                    "service_type": pending.serviceType,
                    "connector_operation": pending.operation,
                    "sent_count": String(receipts.count),
                    "remaining_count": String(remaining),
                    "result": "stopped"
                ], level: .warning, fieldMaxLength: 240)
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.System.info,
                    payload: stoppedNotice(pending: pending, remaining: remaining, error: error),
                    run: run
                ))
                break
            }
        }
        return receipts
    }

    /// The order the agent proposed them in. Discovery orders by file name, and
    /// the broker numbers each service-and-operation pair separately, so an
    /// update staged before a transition would sort after it (`transition_issue`
    /// < `update_issue`) and be sent second. Each envelope is created
    /// exclusively at staging time, so its creation date is the call order; the
    /// discovery order breaks ties and covers a date that cannot be read.
    static func inStagingOrder(_ staged: [TaskStagedConnectorMutation]) -> [TaskStagedConnectorMutation] {
        let created = staged.map { pending in
            try? URL(fileURLWithPath: pending.stagedPayloadPath)
                .resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        return staged.indices.sorted { lhs, rhs in
            if let left = created[lhs], let right = created[rhs], left != right {
                return left < right
            }
            return lhs < rhs
        }.map { staged[$0] }
    }

    /// A terminal outcome (the write may already have happened) leaves the
    /// dock with the proposal quarantined, so only the ones after it are
    /// called reviewable; the reason already tells the user to check the
    /// destination.
    static func stoppedNotice(pending: TaskStagedConnectorMutation, remaining: Int, error: Error) -> String {
        let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = pending.summary.isEmpty ? pending.target : pending.summary
        guard (error as? ConnectorMutationCoordinatorError)?.isTerminal == true else {
            let waiting = remaining == 1
                ? "It is waiting for your review."
                : "It and \(remaining - 1) more are waiting for your review."
            return "Auto could not send \(name) to \(pending.target): \(reason) \(waiting)"
        }
        let later = remaining - 1
        let waiting = later == 0 ? "" : later == 1
            ? " The 1 proposal after it is waiting for your review."
            : " The \(later) proposals after it are waiting for your review."
        return "Auto did not finish sending \(name) to \(pending.target): \(reason)\(waiting)"
    }
}
