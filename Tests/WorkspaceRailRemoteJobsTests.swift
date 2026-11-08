import Foundation
import Testing
import WorkspaceToolSupport
@testable import ASTRA

/// The rail's Remote jobs box: task-scoped, present only while the selected
/// task has SSH jobs, one row per job, and a status read from the record.
@Suite("Workspace Rail Remote Jobs")
struct WorkspaceRailRemoteJobsTests {
    private typealias Rail = WorkspaceRailSectionPresentation
    private typealias Jobs = WorkspaceRailRemoteJobPresentation

    private static let connection = RemoteWorkspaceJobConnection(
        id: "c1", name: "backup", target: "pcornet-backup", arguments: ["pcornet-backup"]
    )

    private func record(_ id: String, label: String? = "SAS run", status: RemoteWorkspaceJobStatus = .unverified,
                        cancelled: Bool = false, fence: RemoteWorkspaceJobLaunchFence? = nil) -> RemoteWorkspaceJobRecord {
        var job = RemoteWorkspaceJobRecord(jobID: id, connection: Self.connection, command: "bash run.sh",
                                           label: label, createdAt: Date(timeIntervalSince1970: 0))
        job.status = status
        if cancelled { job.cancellationRequestedAt = Date(timeIntervalSince1970: 1) }
        job.launchFence = fence
        return job
    }

    private func boxes(_ jobs: Rail.RemoteJobFacts) -> [Rail.Box] {
        Rail.boxes(
            environment: Rail.EnvironmentFacts(primaryPath: "/tmp/w"),
            context: Rail.ContextFacts(),
            capabilities: [],
            remoteJobs: jobs,
            outputs: Rail.OutputFacts(files: [Rail.OutputFile(path: "/tmp/task/out.md")])
        )
    }

    @Test("a task without remote jobs has no Remote jobs box")
    func noJobsNoBox() {
        #expect(Rail.remoteJobsBox(Rail.RemoteJobFacts()) == nil)
        #expect(boxes(Rail.RemoteJobFacts()).map(\.section) == [.environment, .context, .outputs])
    }

    @Test("jobs get one expandable row each, between Capabilities and Outputs, with no add")
    func jobsMakeRows() throws {
        let facts = Jobs.facts(jobs: [
            record("a", label: "q02 SAS run", cancelled: true, fence: .legacySealed),
            record("b", label: "q02 SAS run attempt 2", status: .running)
        ], checkError: nil)
        let built = boxes(facts)
        #expect(built.map(\.section) == [.environment, .context, .remoteJobs, .outputs])

        let box = try #require(built.first { $0.section == .remoteJobs })
        #expect(box.title == "Remote jobs")
        #expect(box.rows.map(\.kind) == [.remoteJob(id: "a"), .remoteJob(id: "b")])
        #expect(box.rows.map(\.title) == ["q02 SAS run", "q02 SAS run attempt 2"])
        #expect(box.rows.map(\.value) == ["Launch blocked", "Running"])
        #expect(box.rows.map(\.isExpandable) == [true, true])
        #expect(box.addActions.isEmpty)
        #expect(Rail.railAddActions(for: built) == Rail.railAddActions(for: boxes(Rail.RemoteJobFacts())))
    }

    @Test("the collapsed line counts jobs per status in first-seen order")
    func collapsedSummary() {
        let blocked = Rail.RemoteJob(id: "a", label: "x", status: "Launch blocked")
        #expect(Rail.remoteJobsSummary(.init(jobs: [blocked, .init(id: "b", label: "y", status: "Launch blocked")])) == "2 launch blocked")
        #expect(Rail.remoteJobsSummary(.init(jobs: [
            .init(id: "a", label: "x", status: "Running"), .init(id: "b", label: "y", status: "Failed")
        ])) == "1 running · 1 failed")
    }

    @Test("a failed check with no listed job still has a row to live on")
    func checkFailureWithoutJobs() throws {
        let box = try #require(Rail.remoteJobsBox(Jobs.facts(jobs: [], checkError: "Remote job check failed")))
        #expect(box.rows.map(\.kind) == [.remoteJobsCheckFailed])
        #expect(box.collapsedSummary == "Last check failed")
    }

    @Test("status reads the cancellation first: blocked, then pending, then the job's own status")
    func statusText() {
        #expect(Jobs.statusText(record("a", cancelled: true, fence: .legacySealed)) == "Launch blocked")
        #expect(Jobs.statusText(record("a", cancelled: true)) == "Cancellation pending")
        #expect(Jobs.statusText(record("a", status: .cancelled, cancelled: true, fence: .cancelledBeforeStart)) == "Cancelled")
        #expect(Jobs.statusText(record("a", status: .timedOut)) == "Timed out")
        #expect(Jobs.statusText(record("a")) == "Unverified")
    }

    @Test("Cancel job is offered only while a cancellation can still change something")
    func cancelAvailability() {
        #expect(Jobs.canCancel(record("a", status: .running)))
        #expect(!Jobs.canCancel(record("a", status: .running, cancelled: true)))
        #expect(!Jobs.canCancel(record("a", cancelled: true, fence: .legacySealed)))
        #expect(!Jobs.canCancel(record("a", status: .succeeded)))
    }

    @Test("a refresh walking several job folders never empties the list, and keeps its order")
    func refreshKeepsUnreachedJobs() {
        let a = record("a"), b = record("b"), c = record("c")
        var seenB = b
        seenB.lastVerifiedAt = Date(timeIntervalSince1970: 9)
        let ids = { (jobs: [RemoteWorkspaceJobRecord]) in jobs.map(\.jobID) }
        // An empty folder first: before, this published [] and the box vanished.
        #expect(ids(RemoteWorkspaceJobMonitor.interimJobs(observed: [], current: [], previous: [a, b, c])) == ["a", "b", "c"])
        let midway = RemoteWorkspaceJobMonitor.interimJobs(observed: [a], current: [seenB], previous: [a, b, c])
        #expect(ids(midway) == ["a", "b", "c"])
        #expect(midway[1].lastVerifiedAt == seenB.lastVerifiedAt)
    }

    @Test("cancelling one job refreshes its folder in place and keeps the others listed")
    func cancellationKeepsOtherJobs() {
        var cancelled = record("b")
        cancelled.cancellationRequestedAt = Date(timeIntervalSince1970: 5)
        let jobs = RemoteWorkspaceJobMonitor.replacingJobs([record("a"), record("b"), record("c")], with: [cancelled, record("d")])
        #expect(jobs.map(\.jobID) == ["a", "b", "c", "d"])
        #expect(jobs[1].cancellationRequestedAt != nil)
    }

    @Test("a box of settled jobs starts collapsed; an open job or a failed check opens it")
    func settledBoxStartsCollapsed() throws {
        let settled = Jobs.facts(jobs: [record("a", cancelled: true, fence: .legacySealed), record("b", status: .succeeded)], checkError: nil)
        #expect(settled.jobs.map(\.isSettled) == [true, true])
        #expect(try #require(Rail.remoteJobsBox(settled)).startsCollapsed)
        let open = Jobs.facts(jobs: [record("a", cancelled: true, fence: .legacySealed), record("b", status: .running)], checkError: nil)
        #expect(try #require(Rail.remoteJobsBox(open)).startsCollapsed == false)
        let failed = Jobs.facts(jobs: [record("a", status: .succeeded)], checkError: "Remote job check failed")
        #expect(try #require(Rail.remoteJobsBox(failed)).startsCollapsed == false)
        // Another request waits on a fresh check of it: still being checked.
        let awaited = Jobs.facts(jobs: [record("a", cancelled: true, fence: .legacySealed)], checkError: nil, awaited: true)
        #expect(try #require(Rail.remoteJobsBox(awaited)).startsCollapsed == false)
    }

    @Test("an unlabeled job is named by its connection")
    func labelFallback() {
        #expect(Jobs.label(record("a", label: "  ")) == "pcornet-backup")
        #expect(Jobs.label(record("a", label: nil)) == "pcornet-backup")
    }
}
