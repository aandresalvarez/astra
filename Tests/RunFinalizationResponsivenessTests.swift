import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Explicitly opt in: one disk-backed fixture, no provider calls or user data.
@MainActor
@Suite("Run finalization responsiveness", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RUN_FINALIZATION_BENCHMARK"] == "1"))
struct RunFinalizationResponsivenessTests {
    @Test func productionScale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-finalize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("fixture.store")
        let configuration = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [configuration])
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspaces = (0..<23).map { Workspace(name: "Synthetic \($0)", primaryPath: root.path) }
        for workspace in workspaces { context.insert(workspace) }
        for index in 0..<2_180 {
            // Deliberately skewed: 600 tasks in the workspace being exported.
            let workspace = workspaces[index < 600 ? 0 : 1 + index % 22]
            let task = AgentTask(title: "Synthetic \(index)", goal: String(repeating: "g", count: 1_000), workspace: workspace)
            context.insert(task)
            let runs = (0..<(index < 1_158 ? 3 : 2)).map { _ in TaskRun(task: task) }
            for run in runs { run.status = .completed; run.completedAt = Date(); run.setOutput("Synthetic answer") }
            task.runs = runs
            let events = (0..<(index == 0 ? 2_200 : (index < 2_126 ? 25 : 24))).map { n in
                TaskEvent(task: task, type: n % 3 == 0 ? "tool.result" : "agent.response",
                          payload: "Synthetic event \(n)", run: runs[n % runs.count])
            }
            task.events = events
            task.status = .completed
            task.completedAt = Date()
            if index % 40 == 39 { try context.save(); await Task.yield() }
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 2_180)
        #expect(try context.fetchCount(FetchDescriptor<TaskRun>()) == 5_518)
        #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == 56_621)
        let workspaceID = workspaces[0].id
        // Fresh context pays real relationship faults rather than measuring the seed cache.
        let read = ModelContext(container)
        read.autosaveEnabled = false
        let workspace = try #require(read.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == workspaceID })).first)
        measure("updater") { #expect(AppUpdateSafety.runningTaskCount(in: read) == 0) }
        try measure("save") { workspace.name = "Finalized"; try read.save() }
        try measure("mirror_snapshot") {
            let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: read))
            #expect(config.tasks?.count == 600)
        }
        let pulse = Task { @MainActor () -> (Int, Double) in
            var count = 0
            var maxGap = 0.0
            var previous = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                let now = DispatchTime.now().uptimeNanoseconds
                maxGap = max(maxGap, Double(now - previous) / 1_000_000)
                previous = now
                count += 1
            }
            return (count, maxGap)
        }
        await Task.yield()
        measure("save_and_enqueue_mirror") {
            workspace.name = "After fix"
            #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: read))
        }
        // A second workspace save must inspect only its changed rows, even
        // while this 600-task mirror is still queued on the shared context.
        let otherID = workspaces[1].id
        let other = try #require(read.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == otherID })).first)
        measure("unrelated_save_with_large_mirror_pending") {
            other.name = "Unrelated edit"
            #expect(WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: read))
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while WorkspacePersistenceCoordinator.pendingExportWorkspaceCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        pulse.cancel()
        let (ticks, maxGap) = await pulse.value
        print("[finalize-bench] background_export main_actor_ticks=\(ticks) max_gap_ms=\(maxGap)")
        #expect(ticks > 0, "The main actor must service work while the real mirror is prepared")
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mirror = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self,
            from: Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))))
        #expect(mirror.name == "After fix")
        #expect(mirror.tasks?.count == 600)
        print("[finalize-bench] tasks=2180 runs=5518 events=56621 selected_workspace_tasks=600")
    }

    private func measure(_ label: String, _ body: () throws -> Void) rethrows {
        FileHandle.standardOutput.write(Data("[finalize-bench-start] \(label) pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        let start = DispatchTime.now().uptimeNanoseconds
        let cpu = threadCPU()
        try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("[finalize-bench] \(label) main_thread=\(Thread.isMainThread) wall_ms=\(elapsed) thread_cpu_ms=\(threadCPU() - cpu)")
    }

    private func threadCPU() -> Double {
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1_000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000
    }
}
