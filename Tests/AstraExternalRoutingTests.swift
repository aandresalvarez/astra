import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

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

    @Test("external create task URL cannot authorize immediate run")
    func externalCreateTaskURLCannotAuthorizeImmediateRun() throws {
        let workspaceID = UUID()
        let goal = "Fix checkout and add tests"
        var components = URLComponents()
        components.scheme = AstraExternalRouteCodec.scheme(for: .production)
        components.host = "create-task"
        components.queryItems = [
            URLQueryItem(name: "workspace", value: workspaceID.uuidString),
            URLQueryItem(name: "goal", value: goal),
            URLQueryItem(name: "run", value: "1")
        ]

        let url = try #require(components.url)
        let decoded = try #require(AstraExternalRouteCodec.route(from: url, channel: .production))

        #expect(decoded.destination == .createTask(workspaceID: workspaceID, goal: goal, shouldRun: false))
    }

    @Test("generated external create task URL does not request immediate run")
    func generatedExternalCreateTaskURLDoesNotRequestImmediateRun() throws {
        let workspaceID = UUID()
        let route = AstraExternalRoute(
            destination: .createTask(workspaceID: workspaceID, goal: "Run the analysis", shouldRun: true)
        )

        let url = try #require(AstraExternalRouteCodec.url(for: route, channel: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let runValue = components.queryItems?.first { $0.name == "run" }?.value

        #expect(runValue == "0")
    }

    @Test("external create task URL duplicate query keys preserve first value")
    func externalCreateTaskURLDuplicateQueryKeysPreserveFirstValue() throws {
        let workspaceID = UUID()
        let ignoredWorkspaceID = UUID()
        var components = URLComponents()
        components.scheme = AstraExternalRouteCodec.scheme(for: .development)
        components.host = "create-task"
        components.queryItems = [
            URLQueryItem(name: "workspace", value: workspaceID.uuidString),
            URLQueryItem(name: "workspace", value: ignoredWorkspaceID.uuidString),
            URLQueryItem(name: "goal", value: "Keep this goal"),
            URLQueryItem(name: "goal", value: "Ignore this duplicate goal"),
            URLQueryItem(name: "run", value: "1"),
            URLQueryItem(name: "run", value: "false")
        ]

        let url = try #require(components.url)
        let decoded = try #require(AstraExternalRouteCodec.route(from: url, channel: .development))

        #expect(decoded.destination == .createTask(
            workspaceID: workspaceID,
            goal: "Keep this goal",
            shouldRun: false
        ))
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

@Suite("Content external route resolution")
struct ContentExternalRouteResolverTests {
    @Test("workspace and task routes resolve without view state")
    @MainActor
    func workspaceAndTaskRoutesResolveWithoutViewState() throws {
        let container = try makeExternalRouteContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research-\(UUID().uuidString)")
        let task = AgentTask(title: "Review", goal: "Review notes", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let resolver = makeResolver(context: context)
        let workspaceRoute = AstraExternalRoute(destination: .workspace(workspace.id))
        let taskRoute = AstraExternalRoute(destination: .task(task.id))

        guard case .openWorkspace(let resolvedWorkspace) = resolver.resolve(workspaceRoute, workspaces: [workspace]) else {
            Issue.record("Expected workspace route resolution")
            return
        }
        guard case .openTask(let resolvedTask) = resolver.resolve(taskRoute, workspaces: [workspace]) else {
            Issue.record("Expected task route resolution")
            return
        }

        #expect(resolvedWorkspace.id == workspace.id)
        #expect(resolvedTask.id == task.id)
    }

    @Test("create draft route inserts a draft task with draft messages")
    @MainActor
    func createDraftRouteInsertsDraftTask() throws {
        let container = try makeExternalRouteContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research-\(UUID().uuidString)")
        context.insert(workspace)
        try context.save()

        let goal = "  Draft a plan for the study  "
        let resolver = makeResolver(context: context, defaultRuntimeID: AgentRuntimeID.copilotCLI.rawValue)
        let route = AstraExternalRoute(
            destination: .createTask(workspaceID: workspace.id, goal: goal, shouldRun: false)
        )

        guard case .createdTask(let task, let shouldRun) = resolver.resolve(route, workspaces: [workspace]) else {
            Issue.record("Expected created draft task resolution")
            return
        }

        #expect(shouldRun == false)
        #expect(task.status == .draft)
        #expect(task.goal == "Draft a plan for the study")
        #expect(task.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(task.draftMessages.contains("Draft a plan for the study"))
        #expect(task.events.isEmpty)
        #expect(task.workspace?.id == workspace.id)
    }

    @Test("create and run route queues task and records the user message")
    @MainActor
    func createAndRunRouteQueuesTaskAndRecordsUserMessage() throws {
        let container = try makeExternalRouteContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research-\(UUID().uuidString)")
        context.insert(workspace)
        try context.save()

        let resolver = makeResolver(context: context)
        let route = AstraExternalRoute(
            destination: .createTask(workspaceID: workspace.id, goal: "Run the analysis", shouldRun: true)
        )

        guard case .createdTask(let task, let shouldRun) = resolver.resolve(route, workspaces: [workspace]) else {
            Issue.record("Expected created running task resolution")
            return
        }

        #expect(shouldRun)
        #expect(task.status == .queued)
        #expect(task.events.count == 1)
        #expect(task.events.first?.type == "user.message")
        #expect(task.events.first?.payload == "Run the analysis")
    }

    @Test("external create task URL with run flag creates draft task")
    @MainActor
    func externalCreateTaskURLWithRunFlagCreatesDraftTask() throws {
        let container = try makeExternalRouteContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research-\(UUID().uuidString)")
        context.insert(workspace)
        try context.save()

        var components = URLComponents()
        components.scheme = AstraExternalRouteCodec.scheme(for: .development)
        components.host = "create-task"
        components.queryItems = [
            URLQueryItem(name: "workspace", value: workspace.id.uuidString),
            URLQueryItem(name: "goal", value: "Run the analysis"),
            URLQueryItem(name: "run", value: "true")
        ]
        let url = try #require(components.url)
        let route = try #require(AstraExternalRouteCodec.route(from: url, channel: .development))

        let resolver = makeResolver(context: context)
        guard case .createdTask(let task, let shouldRun) = resolver.resolve(route, workspaces: [workspace]) else {
            Issue.record("Expected URL-originated task to resolve as a created draft")
            return
        }

        #expect(shouldRun == false)
        #expect(task.status == .draft)
        #expect(task.events.isEmpty)
        #expect(task.draftMessages.contains("Run the analysis"))
    }

    @Test("missing task routes return visible notice")
    @MainActor
    func unresolvedRoutesReturnMessage() throws {
        let container = try makeExternalRouteContainer()
        let resolver = makeResolver(context: container.mainContext)
        let missingID = UUID(uuidString: "F6E7E20F-D30A-4B1F-AB75-C4558110D332")!
        let route = AstraExternalRoute(destination: .task(missingID))

        guard case .unresolved(let message) = resolver.resolve(route, workspaces: []) else {
            Issue.record("Expected missing task route to resolve to a visible notice")
            return
        }
        #expect(message.contains("Task not found"))
        #expect(message.contains(missingID.uuidString))
    }

    @Test("resolved external route clears stale notice")
    @MainActor
    func resolvedExternalRouteClearsStaleNotice() throws {
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research-\(UUID().uuidString)")
        let task = AgentTask(title: "Review", goal: "Review notes", workspace: workspace)

        #expect(ContentExternalRouteResolution.unresolved("Task not found").noticeMessage == "Task not found")
        #expect(ContentExternalRouteResolution.openWorkspace(workspace).noticeMessage.isEmpty)
        #expect(ContentExternalRouteResolution.openTask(task).noticeMessage.isEmpty)
        #expect(ContentExternalRouteResolution.createdTask(task, shouldRun: false).noticeMessage.isEmpty)
    }

    @MainActor
    private func makeExternalRouteContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }

    @MainActor
    private func makeResolver(
        context: ModelContext,
        defaultRuntimeID: String = TaskExecutionDefaults.runtime.rawValue
    ) -> ContentExternalRouteResolver {
        ContentExternalRouteResolver(
            modelContext: context,
            defaultRuntimeID: defaultRuntimeID,
            defaultModel: TaskExecutionDefaults.model,
            defaultBudget: TaskExecutionDefaults.tokenBudget
        )
    }
}
