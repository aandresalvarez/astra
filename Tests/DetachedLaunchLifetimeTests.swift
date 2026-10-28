import Foundation
import Testing
import SwiftData
import ASTRACore
import ASTRAPersistence
import ASTRAModels
@testable import ASTRA

@Suite("Detached launch lifetime")
@MainActor
struct DetachedLaunchLifetimeTests {
    @Test("A completed launch projection releases its task, event and run graph")
    func projectionDoesNotRetainItsHistory() {
        let source = AgentTask(title: "Source", goal: "Read history")
        let run = TaskRun(task: source)
        source.runs = [run]
        source.events = [TaskEvent(task: source, type: "tool.result", payload: "historical output", run: run)]
        weak var copiedTask: AgentTask?
        weak var copiedRun: TaskRun?
        weak var copiedEvent: TaskEvent?
        autoreleasepool {
            let owner = DetachedLaunchProjection(AgentTaskLaunchSnapshot(task: source), from: source)
            defer { withExtendedLifetime(owner) {} }
            let copy = owner.task
            copiedTask = copy
            copiedRun = copy.runs.first
            copiedEvent = copy.events.first
            #expect(copy !== source)
            #expect(copy.events.first !== source.events.first)
        }
        #expect(copiedTask == nil)
        #expect(copiedRun == nil)
        #expect(copiedEvent == nil)
        #expect(source.events.first?.payload == "historical output")
    }
    @Test("The returned execution context keeps its graph even when isolation needs no cleanup")
    func returnedContextOwnsItsHistory() {
        let source = AgentTask(title: "Source", goal: "g")
        let run = TaskRun(task: source); source.runs = [run]
        source.events = [TaskEvent(task: source, type: "tool.result", payload: "history", run: run)]
        weak var copied: AgentTask?
        var returned: AgentRuntimeExecutionContext? = autoreleasepool {
            let owner = DetachedLaunchProjection(AgentTaskLaunchSnapshot(task: source), from: source)
            defer { withExtendedLifetime(owner) {} }
            let context = AgentRuntimeExecutionContext.make(launchTask: owner.task, executionPath: "/tmp", shouldCleanupIsolation: false)
            copied = context.task
            return context
        }
        #expect(copied?.events.first?.payload == "history")
        returned?.cleanup()
        #expect(copied?.events.first?.payload == "history")
        returned = nil
        #expect(copied == nil)
        #expect(source.events.first?.payload == "history")
    }

    @Test("Retiring or cancelling the consumer preserves the graph until the real producer completes", arguments: [false, true])
    func retiredProducerRetainsProjection(cancel: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let source = h.makeTask(runtime: .claudeCode, goal: "Lifetime", model: "test")
        let executionOwner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        defer { executionOwner.finish() }
        let event = TaskEvent(task: source, type: "tool.result", payload: "history")
        h.context.insert(event); try h.context.save()
        var context: AgentRuntimeExecutionContext? = AgentRuntimeExecutionContext.make(
            launchTask: source, executionPath: h.workspaceURL.path, shouldCleanupIsolation: false)
        weak var copiedTask = context?.task
        weak var copiedEvent = context?.task.events.first { $0.type == "tool.result" }
        let gate = ProjectionProducerGate()
        let wait = RuntimeProviderWait(owner: executionOwner)
        let consumer = Task { @MainActor [context = context!] in
            await wait.run { [context] in
                defer { withExtendedLifetime(context) {} }
                await gate.enterAndWait()
                #expect(context.task.events.contains { $0.payload == "history" })
                return AgentProcessResult(exitCode: 0)
            }
        }
        await gate.waitUntilEntered()
        context = nil
        if cancel { consumer.cancel() }
        executionOwner.didNotLaunch()
        executionOwner.requestCancellation()
        #expect(wait.retire(generation: executionOwner.record.ownerID))
        _ = await consumer.value
        #expect(copiedTask != nil && copiedEvent?.payload == "history")
        await gate.open()
        await wait.producer?.value
        #expect(copiedTask == nil && copiedEvent == nil)
        #expect(event.payload == "history" && event.task === source)
    }

    @Test("All detached capability cycles are released while saved source relationships survive reopen")
    func capabilitiesAndSourcePersistence() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let source = h.makeTask(runtime: .claudeCode, goal: "Saved source", model: "test")
        let workspace = try #require(source.workspace)
        let skill = Skill(name: "Owned skill")
        let connector = Connector(name: "Owned account", serviceType: "gcloud", authMethod: "none")
        let tool = LocalTool(name: "Owned tool")
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        workspace.testEnabledCapabilityIDs = [package.id]
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let binding = AccountBinding(componentID: CapabilityResourceOrigin.componentID(for: package.connectors[0]))
        skill.workspace = workspace; connector.workspace = workspace; tool.workspace = workspace
        connector.skill = skill; tool.skill = skill
        activation.workspace = workspace; binding.activation = activation; binding.account = connector
        workspace.skills = [skill]; workspace.connectors = [connector]; workspace.localTools = [tool]
        workspace.pluginActivations = [activation]; activation.bindings = [binding]
        source.skills = [skill]
        h.context.insert(skill); h.context.insert(connector); h.context.insert(tool)
        h.context.insert(activation); h.context.insert(binding)
        let run = TaskRun(task: source); h.context.insert(run)
        let event = TaskEvent(task: source, type: "tool.result", payload: "saved", run: run); h.context.insert(event)
        let artifact = Artifact(task: source, type: "file", path: "/tmp/kept"); h.context.insert(artifact)
        try h.context.save()
        weak var copiedTask: AgentTask?
        weak var copiedWorkspace: Workspace?
        weak var copiedSkill: Skill?
        weak var copiedConnector: Connector?
        weak var copiedTool: LocalTool?
        weak var copiedActivation: PluginActivation?
        weak var copiedBinding: AccountBinding?
        weak var copiedArtifact: Artifact?
        try autoreleasepool {
            let owner = DetachedLaunchProjection(AgentTaskLaunchSnapshot(task: source), from: source)
            defer { withExtendedLifetime(owner) {} }
            copiedTask = owner.task; copiedWorkspace = owner.task.workspace
            copiedSkill = owner.task.skills.first
            copiedConnector = owner.task.workspace?.connectors.first
            copiedTool = owner.task.workspace?.localTools.first
            copiedActivation = owner.task.workspace?.pluginActivations.first
            copiedBinding = copiedActivation?.bindings.first
            copiedArtifact = owner.task.artifacts.first
            _ = try #require(copiedSkill); _ = try #require(copiedConnector); _ = try #require(copiedTool)
            _ = try #require(copiedActivation); _ = try #require(copiedBinding); _ = try #require(copiedArtifact)
        }
        #expect(copiedTask == nil && copiedWorkspace == nil && copiedSkill == nil)
        #expect(copiedConnector == nil && copiedTool == nil && copiedActivation == nil && copiedBinding == nil && copiedArtifact == nil)
        try h.context.save()
        let reopened = ModelContext(h.container)
        let id = source.id
        let saved = try #require(reopened.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        #expect(saved.events.contains { $0.id == event.id && $0.payload == "saved" })
        #expect(saved.runs.contains { $0.id == run.id })
        #expect(saved.artifacts.contains { $0.id == artifact.id })
        #expect(saved.skills.contains { $0.id == skill.id })
        #expect(saved.workspace?.pluginActivations.first?.bindings.first?.account?.id == connector.id)
    }

    @Test("Cleanup refuses an accidentally managed graph without changing saved rows")
    func managedGraphIsNeverUnlinked() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let source = h.makeTask(runtime: .claudeCode, goal: "Saved source", model: "test")
        let run = TaskRun(task: source); h.context.insert(run)
        let event = TaskEvent(task: source, type: "tool.result", payload: "saved", run: run)
        h.context.insert(event); try h.context.save()
        // Simulate a future caller accidentally attaching the projection to a
        // context. The owner must fail closed, not unlink persistent history.
        var owner: DetachedLaunchProjection? = DetachedLaunchProjection(AgentTaskLaunchSnapshot(task: source), from: source)
        let copy = try #require(owner?.task)
        h.context.insert(copy)
        owner = nil
        #expect(copy.modelContext != nil)
        #expect(copy.events.first?.payload == "saved")
        #expect(copy.runs.count == 1)
        #expect(event.task === source && event.run === run)
        #expect(source.events.contains { $0 === event })
        // Never save the deliberately invalid duplicate UUID fixture.
        h.context.rollback()
    }

    @Test("Large detached histories release every copied event")
    func largeHistoryRelease() {
        let source = AgentTask(title: "Long history", goal: "g")
        let run = TaskRun(task: source); source.runs = [run]
        source.events = (0..<24000).map { TaskEvent(task: source, type: "tool.result", payload: "event \($0)", run: run) }
        weak var first: TaskEvent?
        weak var last: TaskEvent?
        var owner: DetachedLaunchProjection? = DetachedLaunchProjection(AgentTaskLaunchSnapshot(task: source), from: source)
        first = owner?.task.events.first; last = owner?.task.events.last
        let started = ContinuousClock.now
        owner = nil
        print("Detached 24000-event disposal duration: \(started.duration(to: .now))")
        #expect(first == nil && last == nil)
        #expect(source.events.count == 24000)
    }

}


private actor ProjectionProducerGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func open() { release?.resume(); release = nil }
}
