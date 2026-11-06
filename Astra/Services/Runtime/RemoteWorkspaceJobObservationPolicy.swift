import Foundation
import WorkspaceToolSupport

/// When ASTRA contacts an SSH job's host without being asked. A job is checked
/// while its state can still change, or while another task's request waits on
/// a fresh check of it; a settled job is checked only by Check now. Derived
/// from the job record and the clock alone, so a restart keeps the schedule.
/// See docs/specs/2026-10-21-ssh-remote-managed-jobs.md, "Observations".
enum RemoteWorkspaceJobObservationPolicy {
    enum Cadence: Equatable, Sendable {
        /// Every `liveInterval`: starting or running, or awaited by a request.
        case live
        /// Open, but no longer changing by itself (unverified or lost). Checks
        /// thin out with the time since the job, or its cancellation, began.
        case backoff
        /// Finished, or its launch is fenced on the host: nothing is left to
        /// observe or deliver.
        case settled
    }

    static let liveInterval: TimeInterval = 15
    /// `.backoff` intervals by age: below `age`, check every `interval`.
    static let backoffSteps: [(age: TimeInterval, interval: TimeInterval)] = [(120, 15), (600, 60), (3600, 300)]
    static let maximumInterval: TimeInterval = 1800
    /// The monitor wakes every `liveInterval`; a check dated just under an
    /// interval ago still counts as due.
    static let schedulingTolerance: TimeInterval = 1

    /// `awaited`: a request of another task is waiting for this job's
    /// workspace. Workspace continuation needs a recent complete check of
    /// every open job (and of a result last seen unreachable), so those keep
    /// the live cadence until the request starts or ends.
    static func cadence(_ job: RemoteWorkspaceJobRecord, awaited: Bool) -> Cadence {
        let confirmedResult = job.status.isTerminal && job.lastObservation?.outcome == .reachable
        if awaited && !confirmedResult { return .live }
        if job.status.isTerminal || job.cancellationState == .launchBlocked { return .settled }
        switch job.status {
        case .starting, .running: return .live
        default: return .backoff
        }
    }

    /// Seconds between automatic checks; nil when only Check now contacts the host.
    static func interval(_ job: RemoteWorkspaceJobRecord, awaited: Bool, now: Date) -> TimeInterval? {
        switch cadence(job, awaited: awaited) {
        case .live: return liveInterval
        case .settled: return nil
        case .backoff:
            let since = max(job.createdAt, job.cancellationRequestedAt ?? job.createdAt)
            let age = now.timeIntervalSince(since)
            return backoffSteps.first { age < $0.age }?.interval ?? maximumInterval
        }
    }

    /// Whether an automatic pass contacts the host for this job now. A
    /// cancellation saved after the last check is always due: the host has
    /// not received it yet.
    static func isDue(_ job: RemoteWorkspaceJobRecord, awaited: Bool, now: Date) -> Bool {
        if awaitsDelivery(job), let requested = job.cancellationRequestedAt,
           job.lastObservation.map({ $0.at < requested }) ?? true {
            return true
        }
        guard let interval = interval(job, awaited: awaited, now: now) else { return false }
        guard let last = job.lastObservation?.at else { return true }
        return now.timeIntervalSince(last) >= interval - schedulingTolerance
    }

    /// A saved cancellation the host has neither fenced nor ended.
    static func awaitsDelivery(_ job: RemoteWorkspaceJobRecord) -> Bool {
        job.cancellationState == .pending
    }
}
