import Foundation
import Testing
import WorkspaceToolSupport
@testable import ASTRA

/// When the monitor contacts a job's host by itself: only while the job can
/// still change, or while another request waits on a fresh check of it.
@Suite("Remote Job Observation Policy")
struct RemoteWorkspaceJobObservationPolicyTests {
    private typealias Policy = RemoteWorkspaceJobObservationPolicy
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func job(_ status: RemoteWorkspaceJobStatus, checkedAt: TimeInterval? = 0,
                     outcome: RemoteWorkspaceJobObservation.Outcome = .reachable,
                     cancelledAt: TimeInterval? = nil, fence: RemoteWorkspaceJobLaunchFence? = nil) -> RemoteWorkspaceJobRecord {
        var job = RemoteWorkspaceJobRecord(jobID: "a", connection: .init(id: "c", name: "c", target: "h", arguments: ["h"]),
                                           command: "true", createdAt: Self.t0)
        job.status = status
        job.lastObservation = checkedAt.map { .init(at: Self.t0 + $0, outcome: outcome) }
        job.cancellationRequestedAt = cancelledAt.map { Self.t0 + $0 }
        job.launchFence = fence
        return job
    }

    @Test("open jobs are checked, finished and fenced jobs are left alone")
    func cadenceByState() {
        #expect(Policy.cadence(job(.starting), awaited: false) == .live)
        #expect(Policy.cadence(job(.running), awaited: false) == .live)
        #expect(Policy.cadence(job(.running, cancelledAt: 1), awaited: false) == .live)
        #expect(Policy.cadence(job(.unverified), awaited: false) == .backoff)
        #expect(Policy.cadence(job(.lost), awaited: false) == .backoff)
        #expect(Policy.cadence(job(.unverified, cancelledAt: 1), awaited: false) == .backoff)
        for status in [RemoteWorkspaceJobStatus.succeeded, .failed, .timedOut, .cancelled] {
            #expect(Policy.cadence(job(status), awaited: false) == .settled)
            #expect(Policy.cadence(job(status, outcome: .unreachable), awaited: false) == .settled)
        }
        // The two legacy jobs of task 636A8A8C: cancelled, host-fenced, unverified.
        #expect(Policy.cadence(job(.unverified, cancelledAt: 1, fence: .legacySealed), awaited: false) == .settled)
    }

    @Test("a waiting request keeps every job it depends on at the live cadence")
    func awaitedJobs() {
        #expect(Policy.cadence(job(.unverified, cancelledAt: 1, fence: .legacySealed), awaited: true) == .live)
        #expect(Policy.cadence(job(.unverified), awaited: true) == .live)
        #expect(Policy.cadence(job(.cancelled, outcome: .unreachable), awaited: true) == .live)
        #expect(Policy.cadence(job(.succeeded), awaited: true) == .settled)
    }

    @Test("a host-only cancellation stays live while awaited: continuation reviews it as unverified")
    func hostOnlyCancellationIsAwaited() {
        var hostOnly = job(.cancelled, cancelledAt: 1, fence: .cancelledBeforeStart)
        hostOnly.schemaVersion = 3
        #expect(RuntimeWorkspaceRemoteJobs.reviewedStatus(hostOnly) == .unverified)
        #expect(Policy.cadence(hostOnly, awaited: true) == .live)
        #expect(Policy.isDue(hostOnly, awaited: true, now: Self.t0 + 15))
        #expect(Policy.cadence(hostOnly, awaited: false) == .settled)
        // A protected withdrawn permit proves the launch never ran: confirmed.
        var withdrawn = job(.cancelled, cancelledAt: 1, fence: .cancelledBeforeStart)
        withdrawn.launchPermit = .withdrawn
        #expect(RuntimeWorkspaceRemoteJobs.reviewedStatus(withdrawn) == .cancelled)
        #expect(Policy.cadence(withdrawn, awaited: true) == .settled)
        var missingPermit = withdrawn
        missingPermit.launchPermit = nil
        #expect(Policy.cadence(missingPermit, awaited: true) == .live)
    }

    @Test("unverified checks thin out with the time since the job, or its cancellation, began")
    func backoffByAge() {
        let open = job(.unverified)
        #expect(Policy.interval(open, awaited: false, now: Self.t0 + 60) == 15)
        #expect(Policy.interval(open, awaited: false, now: Self.t0 + 300) == 60)
        #expect(Policy.interval(open, awaited: false, now: Self.t0 + 1800) == 300)
        #expect(Policy.interval(open, awaited: false, now: Self.t0 + 7200) == 1800)
        #expect(Policy.interval(job(.unverified, cancelledAt: 7000), awaited: false, now: Self.t0 + 7060) == 15)
        #expect(Policy.interval(job(.running), awaited: false, now: Self.t0 + 7200) == 15)
        #expect(Policy.interval(job(.failed), awaited: false, now: Self.t0 + 7200) == nil)
    }

    @Test("due once the interval has passed since the last check, never for a settled job")
    func dueByLastCheck() {
        let running = job(.running, checkedAt: 100)
        #expect(!Policy.isDue(running, awaited: false, now: Self.t0 + 110))
        #expect(Policy.isDue(running, awaited: false, now: Self.t0 + 115))
        #expect(Policy.isDue(job(.unverified, checkedAt: nil), awaited: false, now: Self.t0))
        let fenced = job(.unverified, checkedAt: 100, cancelledAt: 50, fence: .legacySealed)
        #expect(!Policy.isDue(fenced, awaited: false, now: Self.t0 + 86_400))
        #expect(Policy.isDue(fenced, awaited: true, now: Self.t0 + 115))
        #expect(!Policy.isDue(job(.succeeded, checkedAt: 100), awaited: false, now: Self.t0 + 86_400))
        // An old unverified job: once per 30 minutes.
        let old = job(.unverified, checkedAt: 7200)
        #expect(!Policy.isDue(old, awaited: false, now: Self.t0 + 7200 + 1700))
        #expect(Policy.isDue(old, awaited: false, now: Self.t0 + 7200 + 1800))
    }

    @Test("a cancellation saved after the last check goes out on the next pass")
    func newCancellationIsDue() {
        #expect(Policy.isDue(job(.running, checkedAt: 100, cancelledAt: 105), awaited: false, now: Self.t0 + 106))
        #expect(!Policy.isDue(job(.running, checkedAt: 110, cancelledAt: 105), awaited: false, now: Self.t0 + 111))
        #expect(Policy.isDue(job(.unverified, checkedAt: 7200, cancelledAt: 9000), awaited: false, now: Self.t0 + 9001))
        // The host already fenced or finished it: nothing left to deliver.
        #expect(!Policy.isDue(job(.unverified, checkedAt: 100, cancelledAt: 105, fence: .legacySealed),
                              awaited: false, now: Self.t0 + 106))
        #expect(!Policy.isDue(job(.cancelled, checkedAt: 100, cancelledAt: 105), awaited: false, now: Self.t0 + 106))
    }

    @Test("only a cancellation the host has neither fenced nor ended awaits delivery")
    func delivery() {
        #expect(Policy.awaitsDelivery(job(.running, cancelledAt: 1)))
        #expect(Policy.awaitsDelivery(job(.unverified, cancelledAt: 1)))
        #expect(!Policy.awaitsDelivery(job(.unverified, cancelledAt: 1, fence: .legacySealed)))
        #expect(!Policy.awaitsDelivery(job(.cancelled, outcome: .unreachable, cancelledAt: 1)))
        #expect(!Policy.awaitsDelivery(job(.running)))
    }
}
