import AppKit
import SwiftData
import ASTRAModels
import WorkspaceToolSupport

@MainActor
enum TaskWorkspaceContinuationPrompt {
    static func present(task: AgentTask, requestID: UUID, queue: TaskQueue, context: ModelContext) {
        do {
            guard let request = try TaskTurnRequestRepository.request(id: requestID, in: context) else { return }
            let previous = try RuntimeTaskOwnerJournal.read(task: task, context: context)
            // Say which rule refused, instead of three unrelated guesses.
            guard RuntimeWorkspaceContinuation.isNewManualInstruction(request, task: task, previous: previous, context: context) else {
                let alert = NSAlert()
                alert.messageText = "This request cannot continue the workspace"
                alert.informativeText = "ASTRA offers this decision only for your own new message or first instruction, and only when nothing this task ran earlier is still unverified. This request does not qualify. It stays saved; you can cancel it and send the message again, or wait for the holding task to be settled."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: context,
                previous: previous, reviewSSHJobs: true)
            let names = proposal.sources.compactMap { source -> String? in
                let id = source.receipt.taskID
                return try? context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id }))
                    .first(where: { $0.persistentModelID == source.taskOwnerID })?.title
            }
            let alert = NSAlert()
            alert.messageText = "Continue this workspace?"
            alert.informativeText = "The provider finished in \(names.joined(separator: ", ")), but earlier tool effects remain unverified and could still be active. Continue to resume this workspace despite that uncertainty. ASTRA will remember this decision for tasks you start here after each previous task finishes. Active work, failed cleanup, changed resources and scheduled tasks remain blocked. Your history and execution evidence stay preserved."
            let jobs = proposal.sources.flatMap { $0.reviewedSSHJobs ?? [] }
            var action = "Continue workspace"
            if !jobs.isEmpty {
                let allSealed = jobs.allSatisfy(\.sealed)
                alert.messageText = allSealed ? "Continue after an unconfirmed SSH launch?" : "Continue when the SSH jobs finish?"
                let lines = jobs.prefix(8).map { "\($0.jobID.prefix(8)) — \($0.sealed ? "cancellation observed; effects unverified" : $0.status.rawValue)" }
                let legacy = jobs.contains(where: \.legacy)
                    ? " For older attempts the host can block a delayed launch and check for its supervisor, but their earlier effects remain unknown."
                    : ""
                alert.informativeText = "\(names.joined(separator: ", ")) finished locally. ASTRA will recheck these jobs before starting this saved request.\(legacy) Continuing accepts earlier unverified tool effects for this request only.\n\n" + lines.joined(separator: "\n")
                if jobs.count > lines.count { alert.informativeText += "\n…and \(jobs.count - lines.count) more." }
                action = allSealed ? "Continue this request" : "Continue when verified"
            }
            alert.addButton(withTitle: action)
            alert.addButton(withTitle: "Keep waiting")
            // The other choice the warning offers: look at the task that holds it.
            let holder = proposal.sources.first?.receipt.taskID
            if holder != nil { alert.addButton(withTitle: proposal.sources.count == 1 ? "Open Holding Task" : "Open a Holding Task") }
            let choice = alert.runModal()
            if choice == .alertThirdButtonReturn, let holder {
                AstraExternalRouteStore.shared.submit(AstraExternalRoute(destination: .task(holder)))
            }
            guard choice == .alertFirstButtonReturn else { return }
            try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: context, rememberWorkspace: jobs.isEmpty)
            queue.refreshResourceOwnership(in: context)
            _ = queue.signalExecutionRequest(id: requestID, task: task, modelContext: context)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Workspace cannot continue yet"
            alert.informativeText = (error as? WorkspaceSSHWait)?.errorDescription ?? (error as? RemoteWorkspaceJobError)?.errorDescription ??
                "A previous execution is still active, its completion cannot be verified, or the saved request changed. Your request and history remain saved. Review the holding task before trying again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
