import Foundation
import Testing
@testable import ASTRA

@Suite("ASTRA External Routing")
struct AstraExternalRoutingTests {
    @Test("channel schemes remain isolated")
    func channelSchemesRemainIsolated() {
        #expect(AstraExternalRouteCodec.scheme(for: .production) == "astra")
        #expect(AstraExternalRouteCodec.scheme(for: .development) == "astra-dev")
        #expect(AstraExternalRouteCodec.scheme(for: .beta) == "astra-beta")
    }

    @Test("workspace route round trips through URL")
    func workspaceRouteRoundTripsThroughURL() throws {
        let workspaceID = UUID()
        let route = AstraExternalRoute(destination: .workspace(workspaceID))

        let url = try #require(AstraExternalRouteCodec.url(for: route, channel: .development))
        let decoded = try #require(AstraExternalRouteCodec.route(from: url, channel: .development))

        #expect(decoded.destination == .workspace(workspaceID))
        #expect(AstraExternalRouteCodec.route(from: url, channel: .production) == nil)
    }

    @Test("create and run route preserves goal and run flag")
    func createAndRunRoutePreservesGoalAndRunFlag() throws {
        let workspaceID = UUID()
        let goal = "Fix checkout and add tests"
        let route = AstraExternalRoute(
            destination: .createTask(workspaceID: workspaceID, goal: goal, shouldRun: true)
        )

        let url = try #require(AstraExternalRouteCodec.url(for: route, channel: .production))
        let decoded = try #require(AstraExternalRouteCodec.route(from: url, channel: .production))

        #expect(decoded.destination == .createTask(workspaceID: workspaceID, goal: goal, shouldRun: true))
    }

    @Test("voice task titles are compact and readable")
    func voiceTaskTitlesAreCompactAndReadable() {
        #expect(AstraTaskIntentSupport.title(for: "") == "New ASTRA Task")
        #expect(AstraTaskIntentSupport.title(for: "Fix checkout") == "Fix checkout")

        let longGoal = "Fix checkout failure in production by tracing the payment session callback"
        let title = AstraTaskIntentSupport.title(for: longGoal)
        #expect(title.count <= 60)
        #expect(title.hasSuffix("..."))
    }

    @Test("latest unfinished task ignores completed and done tasks")
    func latestUnfinishedTaskIgnoresCompletedAndDoneTasks() {
        let workspace = Workspace(name: "Website", primaryPath: "/tmp/website")
        let olderQueued = AgentTask(title: "Older", goal: "Older", workspace: workspace)
        olderQueued.status = .queued
        olderQueued.updatedAt = Date(timeIntervalSince1970: 10)

        let newerCompleted = AgentTask(title: "Done", goal: "Done", workspace: workspace)
        newerCompleted.status = .completed
        newerCompleted.updatedAt = Date(timeIntervalSince1970: 30)

        let newerMarkedDone = AgentTask(title: "Marked Done", goal: "Marked Done", workspace: workspace)
        newerMarkedDone.status = .queued
        newerMarkedDone.isDone = true
        newerMarkedDone.updatedAt = Date(timeIntervalSince1970: 40)

        let latestRunning = AgentTask(title: "Latest", goal: "Latest", workspace: workspace)
        latestRunning.status = .running
        latestRunning.updatedAt = Date(timeIntervalSince1970: 20)

        workspace.tasks = [olderQueued, newerCompleted, newerMarkedDone, latestRunning]

        #expect(AstraTaskIntentSupport.latestUnfinishedTask(in: workspace)?.id == latestRunning.id)
    }
}
