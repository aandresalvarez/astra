import SwiftUI
import ASTRACore
import ASTRAModels

/// Ephemeral result of the repair the person clicked. Cancellation and the
/// task/run identity prevent a late check appearing on a different run.
@MainActor
final class TaskRepairActionPresentation: ObservableObject {
    struct Notice: Equatable {
        let taskID: UUID
        let runID: UUID?
        let guidance: TaskRepairAction.Guidance
    }
    @Published private(set) var notice: Notice?
    private var running: Task<Void, Never>?
    private let resolve: @MainActor ([TaskEventSnapshot], UUID?, AgentTask) async -> RepairAction?
    private let perform: @MainActor (RepairAction?) async -> TaskRepairAction.Guidance?

    init(
        resolve: @escaping @MainActor ([TaskEventSnapshot], UUID?, AgentTask) async -> RepairAction? = {
            await TaskRunStopEvidence.signInRepair(events: $0, runID: $1, task: $2)
        },
        perform: @escaping @MainActor (RepairAction?) async -> TaskRepairAction.Guidance? = { await TaskRepairAction.perform($0) }
    ) {
        self.resolve = resolve
        self.perform = perform
    }

    @discardableResult
    func start(events: [TaskEventSnapshot], runID: UUID?, task: AgentTask) -> Task<Void, Never> {
        cancel()
        let taskID = task.id
        let resolve = self.resolve
        let perform = self.perform
        let action = Task<Void, Never> { [weak self] in
            let repair = await resolve(events, runID, task)
            guard !Task.isCancelled else { return }
            let guidance = await perform(repair)
            guard !Task.isCancelled, let guidance else { return }
            self?.notice = Notice(taskID: taskID, runID: runID, guidance: guidance)
        }
        running = action
        return action
    }

    func dismiss() { notice = nil }
    func cancel() { running?.cancel(); running = nil; notice = nil }
    deinit { running?.cancel() }
}

extension View {
    func taskRepairNotice(_ presentation: TaskRepairActionPresentation, taskID: UUID, runID: UUID?) -> some View {
        modifier(TaskRepairNoticeModifier(presentation: presentation, taskID: taskID, runID: runID))
    }
}

private struct TaskRepairNoticeModifier: ViewModifier {
    @ObservedObject var presentation: TaskRepairActionPresentation
    let taskID: UUID
    let runID: UUID?

    private var notice: TaskRepairActionPresentation.Notice? {
        guard let notice = presentation.notice, notice.taskID == taskID, notice.runID == runID else { return nil }
        return notice
    }

    func body(content: Content) -> some View {
        content.alert(notice?.guidance.title ?? "Setup", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { presentation.dismiss() } }
        )) {
            Button("OK", role: .cancel) { presentation.dismiss() }
        } message: {
            Text(notice?.guidance.detail ?? "")
        }
        .onChange(of: taskID) { _, _ in presentation.cancel() }
        .onChange(of: runID) { _, _ in presentation.cancel() }
        .onDisappear { presentation.cancel() }
    }
}
