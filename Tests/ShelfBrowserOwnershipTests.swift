import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Browser sessions respect imported owners", .serialized)
@MainActor
struct ShelfBrowserOwnershipTests {
    @Test("Imported copies keep pinned browsers and deletion separate")
    func importedPinnedCopies() throws {
        let f = try BrowserOwnerFixture()
        let store = ShelfBrowserSessionStore()
        let first = f.session(store, f.a)
        let second = f.session(store, f.b)
        defer { first.teardown(); second.teardown() }
        #expect(first !== second)
        #expect(first.boundOwner == ShelfBrowserOwner(f.a))
        #expect(second.boundOwner == ShelfBrowserOwner(f.b))
        store.releaseSession(for: f.a.id, ownerID: f.a.persistentModelID)
        #expect(f.session(store, f.b) === second)
        #expect(store.taskSessionCountForTesting == 1)
    }

    @Test("Updates, ambiguity and teardown are scoped to a session instance")
    func registryOwnership() throws {
        let f = try BrowserOwnerFixture()
        let registry = ShelfBrowserBridgeRegistry.shared
        registry.reset()
        defer { registry.reset() }
        let a = UUID(), b = UUID(), duplicate = UUID()
        func publish(_ task: AgentTask, session: UUID, page: String) {
            registry.update(endpoint: "http://127.0.0.1:12345", currentURL: page, currentTitle: page,
                taskID: task.id, taskOwnerID: task.persistentModelID, sessionID: session,
                accessToken: page, isPresented: true, isEnabled: true)
        }
        publish(f.a, session: a, page: "Owner A")
        publish(f.b, session: b, page: "Owner B")
        #expect(f.environment(f.a)["ASTRA_BROWSER_TOKEN"] == "Owner A")
        #expect(f.environment(f.b)["ASTRA_BROWSER_TOKEN"] == "Owner B")
        #expect(registry.environmentVariables(for: f.a.id).isEmpty)
        publish(f.a, session: duplicate, page: "Another window")
        #expect(f.environment(f.a).isEmpty)
        #expect(f.environment(f.b)["ASTRA_BROWSER_TOKEN"] == "Owner B")
        registry.remove(sessionID: duplicate)
        registry.remove(sessionID: a)
        #expect(f.environment(f.b)["ASTRA_BROWSER_TOKEN"] == "Owner B")
    }

    @Test("Runtime launch clones retain owner provenance without granting access to imported copies",
          arguments: [AgentRuntimeID.claudeCode, .codexCLI, .antigravityCLI, .copilotCLI, .cursorCLI, .openCodeCLI])
    func runtimeProvenance(runtime: AgentRuntimeID) throws {
        let f = try BrowserOwnerFixture()
        let registry = ShelfBrowserBridgeRegistry.shared
        registry.reset()
        defer { registry.reset() }
        f.a.runtimeID = runtime.rawValue
        registry.update(endpoint: "http://127.0.0.1:12345", currentURL: "https://example.com/owner-a",
            currentTitle: "Owner A", taskID: f.a.id, taskOwnerID: f.a.persistentModelID,
            sessionID: UUID(), accessToken: "a-only", isPresented: true, isEnabled: true)
        let clone = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: f.a), from: f.a)
        let nested = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: clone), from: clone)
        #expect(clone.persistentModelID != f.a.persistentModelID)
        for task in [f.a, clone, nested] {
            #expect(ShelfBrowserOwner(task) == ShelfBrowserOwner(f.a))
            #expect(TaskCapabilityResolver.shouldExposeBrowserBridge(for: task))
            #expect(AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task)["ASTRA_BROWSER_TOKEN"] == "a-only")
            let sections = ShelfBrowserPromptSection.sections(for: task, contextText: "Read the browser",
                enabledBrowserAdapters: [], runtime: runtime, runtimeCapabilityProfile: nil)
            #expect(!sections.isEmpty == BrowserBridgeRuntimeLaunchGuard.canCarryBridge(runtime: runtime, runtimeCapabilityProfile: nil))
        }
        #expect(!TaskCapabilityResolver.shouldExposeBrowserBridge(for: f.b))
        #expect(AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: f.b)["ASTRA_BROWSER_TOKEN"] == nil)
        #expect(ShelfBrowserPromptSection.sections(for: f.b, contextText: "Read the browser",
            enabledBrowserAdapters: [], runtime: runtime, runtimeCapabilityProfile: nil).isEmpty)
    }

    @Test("Browser policy queries and caches use the actual row before applying limits")
    func policyOwner() throws {
        let f = try BrowserOwnerFixture()
        let context = f.container.mainContext
        let a = TaskEvent(task: f.a, type: "user.message", payload: "A only")
        let b = TaskEvent(task: f.b, type: "user.message", payload: "B only")
        a.timestamp = Date(timeIntervalSince1970: 1)
        b.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(a); context.insert(b); context.insert(TaskRun(task: f.b))
        try context.save()
        var projection = BrowserSessionPolicyTaskProjection()
        #expect(projection.latestUserMessage(for: f.a, modelContext: context) == "A only")
        #expect(projection.latestUserMessage(for: f.b, modelContext: context) == "B only")
        #expect(!BrowserSessionPolicyContext.hasRuns(task: f.a, modelContext: context))
        #expect(BrowserSessionPolicyContext.hasRuns(task: f.b, modelContext: context))
        let revision = projection.revision(for: f.a)
        #expect(revision != projection.revision(for: f.b))
        let insertion = DurableTaskEventInsertion(taskID: f.b.id, eventID: b.id, type: b.type,
            payload: "Notification is not owner evidence", timestamp: b.timestamp)
        let invalidated = projection.record(insertion, selectedTaskID: f.a.id)
        #expect(invalidated)
        #expect(projection.latestUserMessage(for: f.a, modelContext: context) == "A only")
        let published = BrowserSessionPolicyPublication(taskOwnerID: f.a.persistentModelID,
            workspaceOwnerID: f.a.workspace?.persistentModelID, taskID: f.a.id,
            workspaceID: f.a.workspace?.id, policy: .failClosed)
        #expect(published.policyForSession(taskID: f.b.id, workspaceID: f.b.workspace?.id,
            taskOwnerID: f.b.persistentModelID, workspaceOwnerID: f.b.workspace?.persistentModelID) == nil)
    }
}

@MainActor
struct BrowserOwnerFixture {
    let registry: ShelfBrowserBridgeRegistry
    let container: ModelContainer
    let a: AgentTask
    let b: AgentTask
    init(registry: ShelfBrowserBridgeRegistry = .shared) throws {
        self.registry = registry
        container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let workspace = Workspace(name: "Browser A", primaryPath: "/tmp/browser-owner-a")
        let copy = Workspace(name: "Browser B", primaryPath: "/tmp/browser-owner-b")
        copy.id = workspace.id
        a = AgentTask(title: "Original", goal: "Read the browser", workspace: workspace)
        b = AgentTask(title: "Imported", goal: "Read the browser", workspace: copy)
        b.id = a.id
        for item in [workspace, copy] { container.mainContext.insert(item) }
        for item in [a, b] { container.mainContext.insert(item) }
        try container.mainContext.save()
    }
    func session(_ store: ShelfBrowserSessionStore, _ task: AgentTask, pinned: Bool = true) -> ShelfBrowserSession {
        store.session(for: task.id, pinnedToTask: pinned, enabledBrowserAdapters: [], taskOwnerID: task.persistentModelID)
    }
    func environment(_ task: AgentTask) -> [String: String] {
        registry.environmentVariables(for: task.id, ownerID: ShelfBrowserOwner(task).modelID)
    }
    func waitForEnvironment(_ task: AgentTask) async throws -> [String: String] {
        for _ in 0..<200 {
            let env = environment(task)
            if env["ASTRA_BROWSER_URL"] != nil { return env }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserOwnerTestFailure.timeout
    }
}
enum BrowserOwnerTestFailure: Error { case timeout }
