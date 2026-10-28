import AppKit
import SwiftData
import ASTRAModels

@MainActor
enum TaskWorkspaceContinuationPrompt {
    static func present(task: AgentTask, requestID: UUID, queue: TaskQueue, context: ModelContext) {
        do {
            guard let request = try TaskTurnRequestRepository.request(id: requestID, in: context) else { return }
            let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: context)
            let names = proposal.sources.compactMap { source -> String? in
                let id = source.receipt.taskID
                return try? context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
                    .first(where: { $0.persistentModelID == source.taskOwnerID })?.title
            }
            let alert = NSAlert()
            alert.messageText = "Continue this workspace?"
            alert.informativeText = "The provider finished in \(names.joined(separator: ", ")), but earlier tool effects remain unverified and could still be active. Continue to resume this workspace despite that uncertainty. ASTRA will remember this decision for tasks you start here after each previous task finishes. Active work, failed cleanup, changed resources and scheduled tasks remain blocked. Your history and execution evidence stay preserved."
            alert.addButton(withTitle: "Continue workspace")
            alert.addButton(withTitle: "Keep waiting")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: context, rememberWorkspace: true)
            queue.refreshResourceOwnership(in: context)
            _ = queue.signalExecutionRequest(id: requestID, task: task, modelContext: context)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Workspace cannot continue yet"
            alert.informativeText = "A previous execution is still active, its completion cannot be verified, or the saved request changed. Your request and history remain saved. Review the holding task before trying again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
