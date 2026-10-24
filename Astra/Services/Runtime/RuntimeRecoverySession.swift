import Foundation

struct RuntimeRecoveryContext {
    let authorize: @Sendable (RuntimeRecoveryReport) async -> Bool
    let report: @Sendable (RuntimeRecoveryReport) -> Void
}

/// A bounded, one-shot action on the existing child, never a replacement run.
/// The model only triggers eligibility checking; an OS suspension receipt and
/// a saved intent are both required before SIGCONT. Repeated ticks are harmless.
final class RuntimeRecoverySession: @unchecked Sendable {
    static func make(context: RuntimeRecoveryContext?, process: AgentExecutionScopedProcess,
                     monitor: AgentProcessMonitor) -> RuntimeRecoverySession? {
        context.map { context in
            RuntimeRecoverySession(context: context,
                suspendedPID: { process.suspendedProcessIdentifier },
                resume: { [weak monitor] pid, revision in
                    monitor?.resumeSuspendedProcess(process, pid: pid, revision: revision) ?? false
                })
        }
    }

    private enum State { case unused, authorizing, awaitingProgress, finished }
    private let lock = NSLock()
    private let context: RuntimeRecoveryContext
    private let suspendedPID: @Sendable () -> Int32?
    private let resume: @Sendable (Int32, Int) -> Bool
    private let now: @Sendable () -> TimeInterval
    private let graceSeconds: TimeInterval
    private let authorizationSeconds: TimeInterval
    private var state = State.unused
    private var pending: Task<Void, Never>?
    private var request: RuntimeRecoveryReport?
    private var revision = 0
    private var deadline: TimeInterval = 0
    private var failure: String?

    init(context: RuntimeRecoveryContext, graceSeconds: TimeInterval = 30,
         authorizationSeconds: TimeInterval = 10,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         suspendedPID: @escaping @Sendable () -> Int32?,
         resume: @escaping @Sendable (Int32, Int) -> Bool) {
        self.context = context; self.graceSeconds = graceSeconds
        self.authorizationSeconds = authorizationSeconds; self.now = now
        self.suspendedPID = suspendedPID; self.resume = resume
    }

    var stopMessage: String? { lock.withLock { failure } }

    /// True holds the old stall verdict only for the bounded recovery window.
    func tick(_ observation: RuntimeSupervisionObservation, decision: RuntimeSupervisionSession.Decision,
              attemptID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == .authorizing || state == .awaitingProgress {
            if observation.progressRevision != revision {
                finishLocked(phase: state == .awaitingProgress ? .progress : .interrupted,
                    message: state == .awaitingProgress
                        ? "The same provider process is responding again. ASTRA kept the original task, tools and remaining limits."
                        : "Provider progress returned before recovery; ASTRA cancelled the pending recovery action.")
                return false
            }
            if now() >= deadline {
                failure = state == .authorizing
                    ? "Recovery admission did not finish in time. No recovery action was authorized."
                    : "The provider did not respond within \(Int(graceSeconds)) seconds after resuming. ASTRA will stop this attempt; automatic relaunch is blocked because other work may still be active."
                finishLocked(phase: .expired, message: failure!)
                return false
            }
            return true
        }
        guard state == .unused, case .stop(let reason, _) = decision,
              reason == "provider_supervisor_stalled" else { return false }
        revision = observation.progressRevision
        let pid = suspendedPID()
        request = .init(operationID: UUID(), attemptID: attemptID, processID: pid, phase: .intent,
            message: "macOS confirms the provider process is suspended. ASTRA is recording one recovery attempt before resuming that same process.")
        guard pid != nil else {
            failure = "Automatic recovery is blocked: macOS did not confirm a suspended, owned provider process. ASTRA will not launch a replacement while earlier tools or remote work may still be active."
            finishLocked(phase: .blocked, message: failure!)
            return false
        }
        state = .authorizing; deadline = now() + authorizationSeconds
        let intent = request!
        pending = Task { [weak self] in
            guard let self else { return }
            let allowed = await context.authorize(intent)
            completeAuthorization(allowed)
        }
        return true
    }

    func finish(progressRevision: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard state != .finished else { return }
        if state == .awaitingProgress, let progressRevision, progressRevision != revision {
            finishLocked(phase: .progress, message: "The same provider process responded after recovery. The task outcome is reported below.")
        } else if state == .authorizing || state == .awaitingProgress {
            finishLocked(phase: .interrupted, message: "Recovery ended with the original process. No replacement task was started.")
        } else { state = .finished }
    }

    private func completeAuthorization(_ allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard state == .authorizing, !Task.isCancelled, let pid = request?.processID else { return }
        guard allowed, now() < deadline, resume(pid, revision) else {
            failure = "Recovery was not applied: its durable admission, process ownership, suspension or current progress check no longer permits it. No replacement was launched."
            finishLocked(phase: .blocked, message: failure!)
            return
        }
        state = .awaitingProgress; deadline = now() + graceSeconds; pending = nil
        emit(.resumed, "ASTRA resumed the existing suspended provider process. Waiting up to \(Int(graceSeconds)) seconds for a response; no new task or process was started.")
    }

    private func finishLocked(phase: RuntimeRecoveryReport.Phase, message: String) {
        state = .finished; pending?.cancel(); pending = nil
        emit(phase, message)
    }

    private func emit(_ phase: RuntimeRecoveryReport.Phase, _ message: String) {
        guard let request else { return }
        context.report(.init(operationID: request.operationID, attemptID: request.attemptID,
            processID: request.processID, phase: phase, message: message))
    }
}
