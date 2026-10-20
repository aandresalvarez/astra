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
    func shelfAttachmentHistory(task: AgentTask?, onLoad: @escaping (UUID?, [String]) -> Void) -> some View {
        modifier(ShelfAttachmentHistoryModifier(task: task, onLoad: onLoad))
    }
}

/// A disposable projection of durable attachment events. Ordinary streaming
/// messages do not invalidate it, and an old read cannot replace a newer one.
private struct ShelfAttachmentHistoryModifier: ViewModifier {
    let task: AgentTask?
    let onLoad: (UUID?, [String]) -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var revision = 0

    private struct RefreshKey: Hashable {
        let taskID: UUID?
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
            .task(id: RefreshKey(taskID: task?.id, status: task?.status.rawValue, revision: revision)) {
                guard let taskID = task?.id else { onLoad(nil, []); return }
                do {
                    let paths = try await TaskAttachmentFilesReader.paths(taskID: taskID, container: modelContext.container)
                    guard !Task.isCancelled, task?.id == taskID else { return }
                    onLoad(taskID, paths)
                } catch {
                    AppLogger.error("Files attachment history could not be read: \(error.localizedDescription)", category: "UI")
                }
            }
    }
}
