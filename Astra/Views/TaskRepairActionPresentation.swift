import SwiftUI
import SwiftData
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
        /// Non-empty while the person decides whether to continue past exactly these.
        var releasable: [ProviderReservationReview.Candidate] = []
        /// The task in this store whose own run must settle a reservation.
        var holderTaskID: UUID? = nil
    }
    @Published private(set) var notice: Notice?
    private var running: Task<Void, Never>?
    private weak var reviewedTask: AgentTask?
    private var continuation: (@MainActor () -> Void)?
    private let open: @MainActor (UUID) -> Void
    private let inspect: @Sendable () throws -> ProviderReservationReview.Findings
    private let release: @Sendable ([ProviderReservationReview.Candidate], UUID) throws -> ProviderReservationReview.Receipt
    private let resolve: @MainActor ([TaskEventSnapshot], UUID?, AgentTask) async -> RepairAction?
    private let perform: @MainActor (RepairAction?) async -> TaskRepairAction.Guidance?

    init(
        resolve: @escaping @MainActor ([TaskEventSnapshot], UUID?, AgentTask) async -> RepairAction? = {
            await TaskRunStopEvidence.signInRepair(events: $0, runID: $1, task: $2)
        },
        perform: @escaping @MainActor (RepairAction?) async -> TaskRepairAction.Guidance? = { await TaskRepairAction.perform($0) },
        inspect: @escaping @Sendable () throws -> ProviderReservationReview.Findings = { try ProviderReservationReview.inspect() },
        release: @escaping @Sendable ([ProviderReservationReview.Candidate], UUID) throws -> ProviderReservationReview.Receipt = {
            try ProviderReservationReview.release($0, requestedBy: $1)
        },
        open: @escaping @MainActor (UUID) -> Void = { AstraExternalRouteStore.shared.submit(AstraExternalRoute(destination: .task($0))) }
    ) {
        self.resolve = resolve
        self.perform = perform
        self.inspect = inspect
        self.release = release
        self.open = open
    }

    /// `then` continues the task once nothing reviewable stands in its way.
    @discardableResult
    func start(_ kind: TaskDecisionDockActionKind = .runRepair, events: [TaskEventSnapshot], runID: UUID?, task: AgentTask,
               then: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        cancel()
        guard kind != .reviewProviderReservations else { return review(runID: runID, task: task, then: then) }
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

    /// Read-only: the scan runs off the main actor and changes nothing. With
    /// nothing reviewable in the way, the task simply continues.
    private func review(runID: UUID?, task: AgentTask, then: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let taskID = task.id
        let inspect = self.inspect
        reviewedTask = task
        continuation = then
        let action = Task<Void, Never> { [weak self] in
            let findings = await Task.detached { try? inspect() }.value
            guard !Task.isCancelled, let self else { return }
            guard let findings else {
                self.notice = Notice(taskID: taskID, runID: runID, guidance: ProviderReservationReview.unreadableGuidance)
                return
            }
            guard !findings.isClear else { return then() }
            let holder = Self.openableHolder(findings.holders, besides: task)
            let provider = task.runtimeID.flatMap(AgentRuntimeID.init(rawValue:))?.displayName ?? "the provider"
            self.notice = Notice(taskID: taskID, runID: runID,
                guidance: ProviderReservationReview.guidance(for: findings, provider: provider, holderTitle: holder?.title),
                releasable: findings.releasable, holderTaskID: findings.releasable.isEmpty ? holder?.id : nil)
        }
        running = action
        return action
    }

    private static func openableHolder(_ holders: [ProviderReservationReview.Holder], besides task: AgentTask) -> AgentTask? {
        guard let context = task.modelContext else { return nil }
        return holders.lazy.filter { $0.taskID != task.id }.compactMap { holder -> AgentTask? in
            let id = holder.taskID
            var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }.first
    }

    /// Sets aside exactly what the warning listed, then continues the task. The
    /// move and its record on the task complete even if this view has moved on.
    @discardableResult
    func confirmContinue() -> Task<Void, Never>? {
        guard let reviewed = notice, !reviewed.releasable.isEmpty, let task = reviewedTask else { return nil }
        notice = nil
        let release = self.release
        let then = continuation
        let action = Task<Void, Never> { [weak self] in
            let receipt = await Task.detached { try? release(reviewed.releasable, reviewed.taskID) }.value
            if let receipt { ProviderReservationReview.record(receipt, task: task) }
            guard !Task.isCancelled else { return }
            guard (receipt?.released ?? 0) == 0 else { then?(); return }
            self?.notice = Notice(taskID: reviewed.taskID, runID: reviewed.runID,
                guidance: receipt.map { ProviderReservationReview.guidance(for: $0) } ?? ProviderReservationReview.unreadableGuidance)
        }
        running = action
        return action
    }

    func openHolder() {
        guard let id = notice?.holderTaskID else { return }
        notice = nil
        open(id)
    }

    func dismiss() { notice = nil }
    func cancel() { running?.cancel(); running = nil; notice = nil; continuation = nil }
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
            if notice?.releasable.isEmpty == false {
                Button("Continue") { presentation.confirmContinue() }
                // Return must not continue: the safe answer is the default.
                Button("Cancel", role: .cancel) { presentation.dismiss() }.keyboardShortcut(.defaultAction)
            } else if notice?.holderTaskID != nil {
                Button("Open Task") { presentation.openHolder() }
                Button("OK", role: .cancel) { presentation.dismiss() }
            } else {
                Button("OK", role: .cancel) { presentation.dismiss() }
            }
        } message: {
            Text(notice?.guidance.detail ?? "")
        }
        .onChange(of: taskID) { _, _ in presentation.cancel() }
        .onChange(of: runID) { _, _ in presentation.cancel() }
        .onDisappear { presentation.cancel() }
    }
}
