import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// `TaskGeneratedFilesTrigger` no longer counts `task.artifacts` on every pass
/// of `TaskMainView.body`; the observer hears about new rows from
/// `TaskArtifactPersistenceService` instead. The announcement itself is tested
/// with the service. This hosts the real observer and finalizes real runs —
/// the path generated files arrive by — to prove the whole chain still reaches
/// `onGeneratedFilesChange`, and stays quiet when a run produced nothing.
@Suite("Task thread change observer")
@MainActor
struct TaskThreadChangeObserverTests {
    private final class Calls {
        var snapshotChanges = 0
        var generatedFilesChanges = 0
    }

    /// Keeps the host, window and container alive for the process, as the
    /// other hosted-view suites do, so no view update can outlive its models.
    @MainActor
    private enum HostLifetime {
        private static var retained: [Any] = []

        static func keepAlive(_ values: Any...) {
            retained.append(contentsOf: values)
        }
    }

    /// Run-loop turns drive the hosted update; main-actor turns run what it
    /// schedules. Bounded by turns, not wall clock, so a busy machine is slow
    /// rather than failing. See `SidebarTaskStoreSignalIntegrationTests`.
    private func settle(until predicate: () -> Bool, turns: Int = 600) async {
        for _ in 0..<turns {
            if predicate() { return }
            _ = await MainActor.run {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func finishedRun(for task: AgentTask, in context: ModelContext) -> TaskRun {
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.setOutput("Done.")
        run.completedAt = Date()
        context.insert(run)
        return run
    }

    @Test("the generated-files callback fires when a run finalizes with new artifacts")
    func generatedFilesCallbackFiresWhenARunFinalizesWithNewArtifacts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-thread-observer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workspace = Workspace(name: "Observer", primaryPath: root.path)
        let task = AgentTask(title: "Observer task", goal: "Write a report", workspace: workspace)
        task.status = .completed
        context.insert(workspace)
        context.insert(task)

        let calls = Calls()
        let observer = TaskThreadChangeObserver(
            task: task,
            generatedFilesLatestRun: nil,
            onSnapshotChange: { calls.snapshotChanges += 1 },
            onGeneratedFilesChange: { calls.generatedFilesChanges += 1 }
        )
        let host = NSHostingView(rootView: observer.frame(width: 10, height: 10))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        HostLifetime.keepAlive(container, context, host, window)
        defer {
            host.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()
        await settle(until: { false }, turns: 5)

        // A run that produced nothing new. Waiting for the snapshot callback
        // proves the observer processed the finalize, so the zero below is a
        // finding rather than a callback that simply had not run yet.
        await AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: finishedRun(for: task, in: context),
            modelContext: context,
            phase: "run"
        )
        await settle(until: { calls.snapshotChanges > 0 })
        #expect(calls.snapshotChanges > 0, "The observer never updated; the rest of this test would be vacuous")
        #expect(calls.generatedFilesChanges == 0)

        // A run that wrote a deliverable into the task folder.
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "# Report".write(
            toFile: (folder as NSString).appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        await AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: finishedRun(for: task, in: context),
            modelContext: context,
            phase: "run"
        )
        await settle(until: { calls.generatedFilesChanges > 0 })
        #expect(task.artifacts.contains { $0.path.hasSuffix("/report.md") })
        #expect(calls.generatedFilesChanges == 1)
    }
}
