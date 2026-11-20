import AppKit
import SwiftData
import ASTRAModels

/// The "Review workspace" dialog. It shows what `RuntimeWorkspaceReview`
/// found and offers to start only when nothing a holder is doing itself is
/// in the way. The words come from `RuntimeWorkspaceReviewWording`.
@MainActor
enum TaskWorkspaceContinuationPrompt {
    static func present(task: AgentTask, requestID: UUID, queue: TaskQueue, context: ModelContext) {
        do {
            guard let request = try TaskTurnRequestRepository.request(id: requestID, in: context) else { return }
            guard RuntimeWorkspaceReview.qualifies(request, task: task, context: context) else {
                let alert = NSAlert()
                alert.messageText = "Only your own request can start past another task"
                alert.informativeText = "ASTRA asks this only about a message or a task you started yourself. A scheduled or chained request waits until the folder is free. This one stays saved."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            guard let review = try RuntimeWorkspaceReview.preview(task: task, request: request, context: context) else {
                // Nothing saved holds it any more: it starts without a decision.
                queue.refreshResourceOwnership(in: context)
                _ = queue.signalExecutionRequest(id: requestID, task: task, modelContext: context)
                return
            }
            var jobs: [String: RuntimeWorkspaceReviewWording.SSHJob] = [:]
            for holder in review.holders {
                guard let owner = try RuntimeReservationRelease.owner(of: holder.receipt, context: context) else { continue }
                for (id, name) in RuntimeWorkspaceRemoteJobs.names(task: owner, owner: holder.receipt, context: context) {
                    jobs[id] = .init(label: name.label, host: name.host)
                }
            }
            let dialog = RuntimeWorkspaceReviewWording.dialog(review, jobs: jobs)
            let alert = NSAlert()
            alert.messageText = dialog.title
            alert.informativeText = dialog.message
            let buttons = (dialog.canStart ? ["Start now"] : [])
                + [review.holders.count == 1 ? "Open task" : "Open a task", "Keep waiting"]
            buttons.forEach { alert.addButton(withTitle: $0) }
            let pressed = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = buttons.indices.contains(pressed) ? buttons[pressed] : "Keep waiting"
            if choice.hasPrefix("Open"), let holder = (review.holders.first(where: \.isActive) ?? review.holders.first)?.taskID {
                AstraExternalRouteStore.shared.submit(AstraExternalRoute(destination: .task(holder)))
            }
            guard choice == "Start now" else { return }
            try RuntimeWorkspaceReview.start(review, task: task, request: request, context: context)
            queue.refreshResourceOwnership(in: context)
            _ = queue.signalExecutionRequest(id: requestID, task: task, modelContext: context)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Nothing was started"
            alert.informativeText = error as? RuntimeExecutionOwnerStore.Failure == .busy
                ? "The folder's state changed while this was open. Your request stays saved. Choose Review workspace again to see where it stands now."
                : "ASTRA cannot read its record of who is using this folder. Your request stays saved."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
