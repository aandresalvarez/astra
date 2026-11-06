import Foundation
import WorkspaceToolSupport

/// Turns the selected task's remote job journal into rail facts. The status
/// is read from the record: a host launch fence reads as blocked, an
/// undelivered cancellation as pending, anything else as the job's status.
enum WorkspaceRailRemoteJobPresentation {
    static func facts(
        jobs: [RemoteWorkspaceJobRecord],
        checkError: String?,
        awaited: Bool = false
    ) -> WorkspaceRailSectionPresentation.RemoteJobFacts {
        .init(
            jobs: jobs.map { .init(id: $0.jobID, label: label($0), status: statusText($0),
                                   isSettled: isSettled($0, awaited: awaited)) },
            checkFailed: checkError != nil
        )
    }

    /// No automatic check is left for this job: only Check now contacts the host.
    static func isSettled(_ job: RemoteWorkspaceJobRecord, awaited: Bool) -> Bool {
        RemoteWorkspaceJobObservationPolicy.cadence(job, awaited: awaited) == .settled
    }

    static func label(_ job: RemoteWorkspaceJobRecord) -> String {
        let label = job.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? job.connectionTarget : label
    }

    static func statusText(_ job: RemoteWorkspaceJobRecord) -> String {
        switch job.cancellationState {
        case .launchBlocked: return "Launch blocked"
        case .pending: return "Cancellation pending"
        case .none: break
        }
        switch job.status {
        case .starting: return "Starting"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .cancelled: return "Cancelled"
        case .unverified: return "Unverified"
        case .lost: return "Lost"
        }
    }

    /// Cancel is offered only while it can still change something: the job is
    /// open and no cancellation is saved or already enforced by the host.
    static func canCancel(_ job: RemoteWorkspaceJobRecord) -> Bool {
        !job.status.isTerminal && job.cancellationState == .none
    }
}
