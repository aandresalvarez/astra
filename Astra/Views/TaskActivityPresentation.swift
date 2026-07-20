import Foundation
import ASTRAModels

/// One small, derived presentation model for durable turn admission.
///
/// `TaskTurnRequest` remains the persistent owner of a submission's lifecycle.
/// This value deliberately owns no mutable state: sidebar rows, the task dock,
/// and message chips all render the same projection of the durable requests.
struct TaskActivityPresentation: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case idle
        case running
        case waitingForWorker
        case waitingForResource
        case starting
    }

    let taskID: UUID
    let kind: Kind
    let request: TaskTurnRequestSnapshot?
    /// The earliest still-waiting follow-up, even when the row itself
    /// presents as running (send-while-running). The scoped
    /// "cancel queued message" affordance keys off this: while a run is
    /// active the only status-gated stop cancels the run and every request,
    /// so a queued follow-up must stay individually retractable here.
    let waitingRequest: TaskTurnRequestSnapshot?

    init(
        taskID: UUID,
        kind: Kind,
        request: TaskTurnRequestSnapshot?,
        waitingRequest: TaskTurnRequestSnapshot? = nil
    ) {
        self.taskID = taskID
        self.kind = kind
        self.request = request
        self.waitingRequest = waitingRequest
    }

    var isWaiting: Bool {
        switch kind {
        case .waitingForWorker, .waitingForResource, .starting:
            true
        case .idle, .running:
            false
        }
    }

    var isRunning: Bool { kind == .running }

    /// Waiting is an operational state, not quiet historical metadata. Keep
    /// it visible in the sidebar alongside an actively running task.
    var showsPersistentSidebarGlyph: Bool { isWaiting || isRunning }

    var sidebarSystemImage: String? {
        switch kind {
        case .idle: return nil
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingForWorker: return "clock"
        case .waitingForResource: return "lock.clock"
        case .starting: return "play.circle"
        }
    }

    var sidebarDescription: String? {
        switch kind {
        case .idle: return nil
        case .running: return "Running"
        case .waitingForWorker: return "Waiting for a worker"
        case .waitingForResource:
            return request?.blockerSummary?.isEmpty == false
                ? "Waiting for workspace: \(request?.blockerSummary ?? "")"
                : "Waiting for workspace"
        case .starting: return "Starting"
        }
    }

    /// The one-line row subtitle is reserved for an actionable wait reason;
    /// running rows remain scan-first and use their spinner alone.
    var sidebarSubtitle: String? {
        switch kind {
        case .waitingForWorker:
            return "Waiting for worker"
        case .waitingForResource:
            return request?.blockerSummary?.isEmpty == false
                ? request?.blockerSummary
                : "Waiting for workspace"
        case .starting:
            return "Starting"
        case .idle, .running:
            return nil
        }
    }

    var dockTitle: String? {
        switch kind {
        case .waitingForWorker: return "Waiting for a worker"
        case .waitingForResource: return "Waiting for workspace"
        case .starting: return "Starting task"
        case .running: return waitingRequest == nil ? nil : "Message queued"
        case .idle: return nil
        }
    }

    var dockSummary: String? {
        switch kind {
        case .waitingForWorker:
            return "Your message is saved and will run when a worker is available."
        case .waitingForResource:
            if let blocker = request?.blockerSummary, !blocker.isEmpty {
                return "Your message is saved. \(blocker) is using this workspace."
            }
            return "Your message is saved and will run when this workspace is available."
        case .starting:
            return "Your message is saved. ASTRA is preparing the next run."
        case .running:
            return waitingRequest == nil
                ? nil
                : "Your message is saved and will run when the current run finishes."
        case .idle:
            return nil
        }
    }

    /// The request the dock's scoped cancel action targets: the row-owning
    /// request while waiting or starting, else the queued follow-up behind a
    /// running run.
    var dockRequest: TaskTurnRequestSnapshot? {
        kind == .running ? waitingRequest : request
    }

    /// The request the sidebar's "Cancel Queued Message" retracts. Waiting
    /// rows own their request; running and starting rows surface the earliest
    /// queued follow-up so it stays retractable behind an active run.
    var cancellableQueuedRequest: TaskTurnRequestSnapshot? {
        isWaiting ? (request ?? waitingRequest) : waitingRequest
    }

    static func resolve(
        taskID: UUID,
        taskStatus: TaskStatus,
        requests: [TaskTurnRequestSnapshot]
    ) -> TaskActivityPresentation {
        let taskRequests = requests
            .filter { $0.taskID == taskID }
            .sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                return lhs.submittedAt < rhs.submittedAt
            }

        let earliestWaiting = taskRequests.first {
            $0.state == .waitingForWorker || $0.state == .waitingForResource
        }
        if let running = taskRequests.first(where: { $0.state == .running }) {
            return Self(taskID: taskID, kind: .running, request: running, waitingRequest: earliestWaiting)
        }
        if taskStatus == .running {
            return Self(taskID: taskID, kind: .running, request: nil, waitingRequest: earliestWaiting)
        }
        if let admitted = taskRequests.first(where: { $0.state == .admitted }) {
            return Self(taskID: taskID, kind: .starting, request: admitted, waitingRequest: earliestWaiting)
        }
        if let resourceWait = taskRequests.first(where: { $0.state == .waitingForResource }) {
            return Self(taskID: taskID, kind: .waitingForResource, request: resourceWait, waitingRequest: resourceWait)
        }
        if let workerWait = taskRequests.first(where: { $0.state == .waitingForWorker }) {
            return Self(taskID: taskID, kind: .waitingForWorker, request: workerWait, waitingRequest: workerWait)
        }
        return Self(taskID: taskID, kind: .idle, request: nil)
    }

    static func resolveByTaskID(
        tasks: [AgentTask],
        requests: [TaskTurnRequestSnapshot]
    ) -> [UUID: TaskActivityPresentation] {
        Dictionary(uniqueKeysWithValues: tasks.map { task in
            (task.id, resolve(taskID: task.id, taskStatus: task.status, requests: requests))
        })
    }
}

/// A message-level view of the same durable request. `messageEventID` is the
/// identity boundary: duplicate text, matching timestamps, and refresh order
/// cannot cause a chip to attach to the wrong bubble.
struct TaskTurnMessageLifecyclePresentation: Equatable, Sendable {
    let requestID: UUID
    let messageEventID: UUID
    let state: TaskTurnRequestState
    let title: String
    let detail: String?
    let systemImage: String

    var isVisible: Bool { state != .completed }

    var accessibilityLabel: String {
        if let detail, !detail.isEmpty { return "\(title). \(detail)" }
        return title
    }

    static func resolve(
        messageEventID: UUID,
        requests: [TaskTurnRequestSnapshot]
    ) -> TaskTurnMessageLifecyclePresentation? {
        guard let request = requests
            .filter({ $0.messageEventID == messageEventID })
            .max(by: { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                return lhs.submittedAt < rhs.submittedAt
            }) else {
            return nil
        }

        switch request.state {
        case .waitingForWorker:
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: "Queued",
                detail: "Waiting for a worker",
                systemImage: "clock"
            )
        case .waitingForResource:
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: "Waiting for workspace",
                detail: request.blockerSummary,
                systemImage: "lock.clock"
            )
        case .admitted:
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: "Starting",
                detail: nil,
                systemImage: "play.circle"
            )
        case .running:
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: "Running",
                detail: nil,
                systemImage: "arrow.triangle.2.circlepath"
            )
        case .completed:
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: "Completed",
                detail: nil,
                systemImage: "checkmark.circle"
            )
        case .failed:
            // "Couldn't start" is reserved for pre-runtime admission failures.
            // A request that reached .running (startedAt set) performed real
            // work — possibly with partial changes — before failing, and must
            // not be reported as never having begun.
            let ranBeforeFailing = request.startedAt != nil
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: ranBeforeFailing ? "Run failed" : "Couldn’t start",
                detail: request.terminalReason,
                systemImage: "exclamationmark.triangle"
            )
        case .cancelled:
            return Self(
                requestID: request.id,
                messageEventID: request.messageEventID,
                state: request.state,
                title: "Cancelled",
                detail: request.terminalReason,
                systemImage: "minus.circle"
            )
        }
    }
}
