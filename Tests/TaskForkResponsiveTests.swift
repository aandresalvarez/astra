import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Responsive saved task forks", .serialized)
@MainActor
struct TaskForkResponsiveTests {
    @Test("UI work and edits continue during copying; duplicate forks are rejected and saved history exports")
    func responsiveForkAndExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let operation = start(fixture, gate: gate)
        #expect(await gate.started.first(where: { _ in true }) == true)
        #expect(TaskForkCreationCoordinator.hasActiveForks)
        // This actor turn runs while the real worker is held before save.
        // Holding a UI-owned context or wrapping a synchronous fork in Task
        // cannot satisfy this independent main-actor progress assertion.
        fixture.source.goal = "Edited while the fork copies"
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
            workspace: fixture.workspace, modelContext: fixture.context)
        do {
            _ = try await create(fixture)
            Issue.record("Duplicate fork was admitted")
        } catch TaskForkCreationCoordinator.CreationError.alreadyCreating {}
        gate.release.signal()
        let forkID = try await operation.value
        let fork = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>(
            predicate: #Predicate { $0.persistentModelID == forkID })).first)
        #expect(!TaskForkCreationCoordinator.hasActiveForks)
        #expect(fork.modelContext === fixture.context)
        #expect(fork.events.count == 258)
        #expect(fork.runs.count == 4)
        #expect(fixture.workspace.tasks.contains { $0.persistentModelID == fork.persistentModelID })
        #expect(fixture.source.goal == "Edited while the fork copies")
        let inheritedSkill = try #require(fork.skills.first)
        #expect(inheritedSkill.tasks.contains { $0.persistentModelID == fork.persistentModelID })
        #expect(await WorkspacePersistenceCoordinator.exportSavedMirrorNow(
            workspace: fixture.workspace, modelContext: fixture.context))
        let reader = ModelContext(fixture.container)
        let id = fork.id
        let saved = try #require(try reader.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        #expect(saved.events.count == 258)
        #expect(saved.events.allSatisfy { $0.task === saved })
        #expect(saved.runs.allSatisfy { $0.providerSessionId == nil })
        let mirror = try String(contentsOf: fixture.root.appendingPathComponent("workspace/.astra/.astra-workspace.json"), encoding: .utf8)
        #expect(mirror.contains(fork.id.uuidString))
    }

    @Test("Cancellation rolls back only the uncommitted fork and removes its prepared folder")
    func cancellationCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let operation = start(fixture, gate: gate)
        _ = await gate.started.first(where: { _ in true })
        operation.cancel()
        gate.release.signal()
        do { _ = try await operation.value; Issue.record("Cancelled fork committed") }
        catch is CancellationError {}
        try assertOnlySource(fixture)
        #expect(!TaskForkCreationCoordinator.hasActiveForks)
    }

    @Test("Failure before save leaves source data intact and cleans prepared files")
    func failedCommitCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate(fail: true)
        let operation = start(fixture, gate: gate)
        _ = await gate.started.first(where: { _ in true })
        gate.release.signal()
        do { _ = try await operation.value; Issue.record("Injected failure committed") }
        catch let error as CocoaError { #expect(error.code == .fileWriteOutOfSpace) }
        try assertOnlySource(fixture)
    }

    @Test("Deleting the source during background work cannot resurrect it or create a fork")
    func deletionInvalidatesFork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let operation = start(fixture, gate: gate)
        _ = await gate.started.first(where: { _ in true })
        fixture.context.delete(fixture.source)
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
            workspace: fixture.workspace, modelContext: fixture.context)
        gate.release.signal()
        do { _ = try await operation.value; Issue.record("Deleted source produced a fork") }
        catch AgentTaskForkError.targetRunMissing {}
        let reader = ModelContext(fixture.container)
        #expect(try reader.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        #expect(try reader.fetchCount(FetchDescriptor<TaskEvent>()) == 0)
    }

    @Test("Quit waits for cancellation cleanup before allowing store teardown")
    func terminationDrainsFork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let operation = start(fixture, gate: gate)
        _ = await gate.started.first(where: { _ in true })
        var drained = false
        let drain = Task {
            await TaskForkCreationCoordinator.cancelAndDrain()
            drained = true
        }
        _ = await gate.cancelled.first(where: { _ in true })
        #expect(!drained)
        gate.release.signal()
        await drain.value
        do { _ = try await operation.value; Issue.record("Quit cancellation committed a fork") }
        catch is CancellationError {}
        #expect(!TaskForkCreationCoordinator.hasActiveForks)
        try assertOnlySource(fixture)
    }

    @Test("The background export does not lose a concurrent UI debounce save")
    func concurrentPendingEditSurvives() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let operation = start(fixture, gate: gate)
        _ = await gate.started.first(where: { _ in true })
        fixture.source.goal = "Pending edit during fork"
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: fixture.workspace,
            modelContext: fixture.context, delayNanoseconds: 60_000_000_000)
        gate.release.signal()
        _ = try await operation.value
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: fixture.workspace.id)
        // The committed fork may already be mirrored, but the unsaved edit
        // must remain a separate obligation that termination can drain.
        #expect(fixture.context.hasChanges)
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceIDs.contains(fixture.workspace.id))
        // The drain is process-wide: another suite's pending export may be counted with this one.
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: fixture.context) >= 1)
        let reader = ModelContext(fixture.container)
        let id = fixture.source.id
        let saved = try #require(try reader.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        #expect(saved.goal == "Pending edit during fork")
        #expect(try reader.fetchCount(FetchDescriptor<AgentTask>()) == 2)
    }

    @Test("Fixture cleanup drains its own pending export without consuming another workspace's work")
    func fixtureCleanupKeepsOtherPendingExports() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let neighbor = try Fixture()
        defer { neighbor.remove() }
        for owner in [fixture, neighbor] {
            WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: owner.workspace,
                modelContext: owner.context, delayNanoseconds: 60_000_000_000)
        }
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceIDs.contains(fixture.workspace.id))
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceIDs.contains(neighbor.workspace.id))
        fixture.remove()
        #expect(!WorkspacePersistenceCoordinator.pendingExportWorkspaceIDs.contains(fixture.workspace.id))
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceIDs.contains(neighbor.workspace.id))
    }

    private func create(_ fixture: Fixture) async throws -> AgentTask {
        try await TaskForkCreationCoordinator.create(
            source: fixture.source, targetRun: fixture.target,
            mode: .conversationSharedFiles, policy: TaskForkPolicy(repository: nil, eligibleFileCount: 0),
            modelContext: fixture.context)
    }

    private func start(_ fixture: Fixture, gate: Gate) -> Task<PersistentIdentifier, Error> {
        TaskForkCreationCoordinator.$saveFork.withValue({ container, source, target, options in
            try TaskForkSavedStore.$beforeCommit.withValue({
                gate.continuation.yield(!Thread.isMainThread)
                gate.continuation.finish()
                let deadline = Date().addingTimeInterval(15)
                while gate.release.wait(timeout: .now() + 0.01) != .success {
                    if Task.isCancelled { gate.cancelContinuation.yield(true); gate.cancelContinuation.finish() }
                    if Date() >= deadline { throw CocoaError(.userCancelled) }
                }
                if gate.fail { throw CocoaError(.fileWriteOutOfSpace) }
            }) {
                try TaskForkSavedStore.create(container: container, sourceID: source, targetRunID: target, options: options)
            }
        }) {
            Task { try await create(fixture).persistentModelID }
        }
    }

    private func assertOnlySource(_ fixture: Fixture) throws {
        let reader = ModelContext(fixture.container)
        #expect(try reader.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(try reader.fetchCount(FetchDescriptor<TaskEvent>()) == 256)
        let tasks = URL(fileURLWithPath: WorkspaceFileLayout.taskRoot(for: fixture.workspace.primaryPath))
        let children = (try? FileManager.default.contentsOfDirectory(atPath: tasks.path)) ?? []
        #expect(children.allSatisfy { $0 == String(fixture.source.id.uuidString.prefix(8)) })
    }

    private final class Gate: Sendable {
        let started: AsyncStream<Bool>
        let continuation: AsyncStream<Bool>.Continuation
        let cancelled: AsyncStream<Bool>
        let cancelContinuation: AsyncStream<Bool>.Continuation
        let release = DispatchSemaphore(value: 0)
        let fail: Bool
        init(fail: Bool = false) {
            (started, continuation) = AsyncStream.makeStream(of: Bool.self)
            (cancelled, cancelContinuation) = AsyncStream.makeStream(of: Bool.self)
            self.fail = fail
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let source: AgentTask
        let target: TaskRun

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("responsive-fork-\(UUID())")
            let folder = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(url: root.appendingPathComponent("test.store")))
            context = container.mainContext
            context.autosaveEnabled = false
            workspace = Workspace(name: "Synthetic responsive fork", primaryPath: folder.path)
            let source = AgentTask(title: "Synthetic source", goal: "Fork fixed history", workspace: workspace)
            self.source = source
            let skill = Skill(name: "Synthetic fork skill")
            skill.workspace = workspace
            source.skills = [skill]
            let runs = (0..<4).map { index in
                let run = TaskRun(task: source)
                run.status = .completed
                run.startedAt = Date(timeIntervalSince1970: Double(index * 64))
                run.completedAt = Date(timeIntervalSince1970: Double((index + 1) * 64))
                return run
            }
            source.runs = runs
            source.events = (0..<256).map { index in
                let event = TaskEvent(task: source, type: "tool.use", payload: "Synthetic \(index)", run: runs[index / 64])
                event.timestamp = Date(timeIntervalSince1970: Double(index))
                return event
            }
            target = runs[3]
            context.insert(workspace)
            context.insert(source)
            context.insert(skill)
            try context.save()
            _ = try TaskWorkspaceAccess(task: source).ensureTaskFolder()
            _ = workspace.tasks // Exercise already-loaded UI relationships.
            _ = skill.tasks
        }

        func remove() {
            // Retiring the gate alone does not remove the coordinator's
            // pending obligation. Drain this fixture before deleting its store
            // so a later termination test cannot consume its leftover export.
            WorkspacePersistenceCoordinator.flushPendingExportSynchronously(
                workspaceID: workspace.id, modelContext: context)
            #expect(!WorkspacePersistenceCoordinator.pendingExportWorkspaceIDs.contains(workspace.id))
            WorkspaceAutoExportGate.shared.retire(workspaceID: workspace.id.uuidString)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
