import SwiftUI
import SwiftData
import ASTRAModels
import ASTRACore

enum ShelfAttachmentHistoryRefreshPolicy {
    static func affectsAttachments(_ insertion: DurableTaskEventInsertion, taskID: UUID?) -> Bool {
        guard insertion.taskID == taskID else { return false }
        if insertion.type == TaskEventTypes.Conversation.attachments.rawValue { return true }
        return TaskAttachmentLedger.userAuthoredMessageTypes.contains(insertion.type)
            && !TaskAttachmentBlock.paths(in: insertion.payload).isEmpty
    }
}

extension View {
    func shelfAttachmentHistory(task: AgentTask?, onLoad: @escaping (TaskAttachmentHistoryScope?, [String]) -> Void) -> some View {
        modifier(ShelfAttachmentHistoryModifier(task: task, onLoad: onLoad))
    }
}

/// A disposable projection of durable attachment events. Ordinary streaming
/// messages do not invalidate it, and an old read cannot replace a newer one.
private struct ShelfAttachmentHistoryModifier: ViewModifier {
    let task: AgentTask?
    let onLoad: (TaskAttachmentHistoryScope?, [String]) -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var revision = 0

    private struct RefreshKey: Hashable {
        let scope: TaskAttachmentHistoryScope?
        let status: String?
        let revision: Int
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .durableTaskEventInserted)) { notification in
                guard let insertion = notification.object as? DurableTaskEventInsertion,
                      ShelfAttachmentHistoryRefreshPolicy.affectsAttachments(insertion, taskID: task?.id) else { return }
                revision &+= 1
            }
            .task(id: RefreshKey(scope: task.map(TaskAttachmentHistoryScope.init), status: task?.status.rawValue, revision: revision)) {
                guard let scope = task.map(TaskAttachmentHistoryScope.init) else { onLoad(nil, []); return }
                do {
                    let paths = try await TaskAttachmentFilesReader.paths(scope: scope, container: modelContext.container)
                    guard !Task.isCancelled, task.map(TaskAttachmentHistoryScope.init) == scope else { return }
                    onLoad(scope, paths)
                } catch is CancellationError {
                    return
                } catch {
                    AppLogger.error("Files attachment history could not be read: \(error.localizedDescription)", category: "UI")
                }
            }
    }
}
