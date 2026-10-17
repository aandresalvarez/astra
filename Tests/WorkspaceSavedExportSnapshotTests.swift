import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@Suite("Saved export immutable store snapshot", .serialized)
@MainActor
struct WorkspaceSavedExportSnapshotTests {
    @Test("A projection remains readable while the live store deletes its faulted rows", arguments: [false, true])
    func deletionDuringProjection(wholeWorkspace: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-export-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"))])
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Keep snapshot", primaryPath: root.path)
        let task = AgentTask(title: "Keep task", goal: "Synthetic", workspace: workspace)
        let event = TaskEvent(task: task, type: "agent.response", payload: "Saved before deletion")
        context.insert(task)
        context.insert(event)
        try context.save()
        let ready = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let read = Task.detached {
            defer { ready.continuation.finish() }
            return try WorkspaceSavedExportSnapshot.read(container: container) { snapshot in
                let snapshotURL = try #require(snapshot.configurations.first?.url)
                // Database copies must inherit their store owner's protected
                // location, never the temp roots granted to provider CLIs.
                #expect(snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
                    == container.configurations.first?.url.deletingLastPathComponent())
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: snapshotURL.deletingLastPathComponent().path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                let reader = ModelContext(snapshot)
                reader.autosaveEnabled = false
                let owner = try #require(reader.fetch(FetchDescriptor<Workspace>()).first)
                // Resolve the relationship, leaving its individual rows faulted.
                let events = try #require(owner.tasks.first).events
                ready.continuation.yield(())
                resume.wait()
                return (payloads: events.map(\.payload), directory: snapshotURL.deletingLastPathComponent())
            }
        }
        for await _ in ready.stream { break }
        // This is deliberately a real concurrent commit after the reader has
        // obtained relationship identifiers, rather than a mock fetch failure.
        if wholeWorkspace {
            SwiftDataDeletionPreparation.prepare(workspace)
            context.delete(workspace)
        } else { context.delete(event) }
        do { try context.save() }
        catch { resume.signal(); _ = try? await read.value; throw error }
        resume.signal()
        let result = try await read.value
        #expect(result.payloads == ["Saved before deletion"])
        #expect(!FileManager.default.fileExists(atPath: result.directory.path))
        #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == 0)
    }
}
