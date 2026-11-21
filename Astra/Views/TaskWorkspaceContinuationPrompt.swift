import AppKit
import SwiftData
import ASTRAModels

/// The "Review workspace" dialog. It shows what `RuntimeWorkspaceReview`
/// found and offers to start only when nothing a holder is doing itself is
/// in the way. The words come from `RuntimeWorkspaceReviewWording`.
@MainActor
enum TaskWorkspaceContinuationPrompt {
    static func present(task: AgentTask, requestID: UUID, queue: TaskQueue, context: ModelContext) {
        var decided = false
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
            // The review sees the claims the queue admits by.
            let enforcement = queue.sandboxEnforcementProvider()
            guard let review = try RuntimeWorkspaceReview.preview(task: task, request: request, context: context,
                                                                  sandboxEnforcement: enforcement) else {
                // No other task holds its folders any more: it starts without
                // a decision, unless what it waits for is an earlier run of
                // this same task or something that is not a folder.
                queue.refreshResourceOwnership(in: context)
                let claims = queue.resourceLockClaims(for: request, task: task, runMode: "request")
                if !queue.canAcquireResourceLocks(claims, task: task, context: context) {
                    let other = TaskExecutionResourceBroker.firstConflict(requested: claims, active: queue.activeResourceLocks)
                        .map { $0.holder.taskID != task.id } ?? false
                    let alert = NSAlert()
                    alert.messageText = other ? RuntimeWorkspaceReviewWording.otherResourceTitle : RuntimeWorkspaceReviewWording.ownRunTitle
                    alert.informativeText = other
                        ? RuntimeWorkspaceReviewWording.otherResourceMessage(
                            queue.resourceBlockerSummary(claims, modelContext: context, request: request, task: task))
                        : RuntimeWorkspaceReviewWording.ownRunMessage
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
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
            decided = true
            // A release that was written before a later save failed is still a
            // release: ownership is read again and the request woken whether
            // or not `start` returns.
            defer {
                queue.refreshResourceOwnership(in: context)
                _ = queue.signalExecutionRequest(id: requestID, task: task, modelContext: context)
            }
            try RuntimeWorkspaceReview.start(review, task: task, request: request, context: context, sandboxEnforcement: enforcement)
        } catch {
            let changed = error as? RuntimeExecutionOwnerStore.Failure == .busy
            let alert = NSAlert()
            alert.messageText = decided && !changed ? RuntimeWorkspaceReviewWording.unsavedDecisionTitle : "Nothing was started"
            alert.informativeText = changed
                ? "The folder's state changed while this was open. Your request stays saved. Choose Review workspace again to see where it stands now."
                : decided ? RuntimeWorkspaceReviewWording.unsavedDecisionMessage
                : "ASTRA cannot read its record of who is using this folder. Your request stays saved."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
