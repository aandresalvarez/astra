import Darwin
import Foundation
import SwiftData
import Testing
import os
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Opt-in measurement, in a fresh process per mode. Machine-dependent memory
/// numbers are evidence, never normal CI thresholds. No production inputs.
@MainActor
@Suite("Export memory ownership evidence", .serialized)
struct WorkspaceExportMemoryEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ASTRA_EXPORT_EVIDENCE"] == "1"))
    func repeatedCommittedExports() async throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["ASTRA_EXPORT_MODE"] ?? "export"
        let large = env["ASTRA_EXPORT_SCALE"] == "representative"
        let pauseSeconds = Int(env["ASTRA_EXPORT_PROFILE_PAUSE"] ?? "0") ?? 0
        try #require((0...60).contains(pauseSeconds))
        let blocks = Int(env["ASTRA_EXPORT_BLOCKS"] ?? "6") ?? 6
        try #require(["export", "history", "combined", "direct", "cleanup", "failure", "cancellation", "termination"].contains(mode))
        try #require((1...30).contains(blocks))
        let seedOnly = env["ASTRA_EXPORT_SEED_ONLY"] == "1"
        let fixture = env["ASTRA_EXPORT_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) }
        try #require(!large || fixture != nil, "Use the runner's reusable fixture for representative measurements")
        let root = seedOnly ? try #require(fixture) : FileManager.default.temporaryDirectory.appendingPathComponent("astra-export-evidence-\(UUID())")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if !seedOnly { try? FileManager.default.removeItem(at: root) } }
        if !seedOnly, let fixture {
            let marker = try String(contentsOf: fixture.appendingPathComponent("synthetic-export-fixture.txt"), encoding: .utf8)
            try #require(marker == "20261106:\(large ? "representative" : "small")")
            try WorkspaceRecoveryService.copyStoreSnapshot(from: fixture.appendingPathComponent("source.store"),
                to: root.appendingPathComponent("source.store"))
        }
        print("EXPORT_EVIDENCE pid=\(getpid()) mode=\(mode) scale=\(large ? "representative" : "small") seed=20261106 blocks=\(blocks)")
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"))])
        if seedOnly || fixture == nil { try seed(container, root: root, large: large, eventCount: seedOnly ? 1 : 300) }
        if seedOnly {
            try "20261106:\(large ? "representative" : "small")".write(to: root.appendingPathComponent("synthetic-export-fixture.txt"), atomically: true, encoding: .utf8)
            return
        }
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspaces = try context.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.name)]))
        for (index, owner) in workspaces.enumerated() {
            let path = root.appendingPathComponent("workspace-\(index)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            owner.primaryPath = path.path
        }
        try context.save()
        let workspace = try #require(workspaces.first)
        let taskID = stableID(2, 0)
        let expectedTasks = large ? 2200 : 12
        let expectedEvents = large ? 75000 : 300
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == expectedTasks)
        #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == expectedEvents)
        #expect(try context.fetchCount(FetchDescriptor<TaskRun>()) == expectedTasks)
        #expect(workspaces.count == 2)
        let observed = ExportReaderEvidence()
        let copy = WorkspaceExportFileIO.copySnapshot
        try await WorkspaceSavedAutoExport.$observeReader.withValue({ observed.reader($0, $1) }) {
            try await WorkspaceExportFileIO.$copySnapshot.withValue({ source, destination in
                try copy(source, destination)
                observed.copied(try snapshotFileIdentities(in: destination.deletingLastPathComponent()))
            }) {
                for block in 0...blocks {
                    if mode == "history" || mode == "combined" {
                        try autoreleasepool {
                            let reader = ModelContext(container)
                            reader.autosaveEnabled = false
                            let page = try TaskThreadHistoryReader.initialPage(taskID: taskID, modelContext: reader)
                            #expect(page.totalEventCount == expectedEvents)
                            #expect(page.events.count <= TaskThreadHistoryReader.defaultEventPageSize)
                        }
                    }
                    switch mode {
                    case "history": break
                    case "direct":
                        let instrumentedCopy = WorkspaceExportFileIO.copySnapshot
                        try await Task.detached {
                            try WorkspaceExportFileIO.$copySnapshot.withValue(instrumentedCopy) {
                                try WorkspaceSavedExportSnapshot.read(container: container) { snapshot in
                                    let reader = ModelContext(snapshot)
                                    reader.autosaveEnabled = false
                                    observed.reader(snapshot, reader)
                                    let owner = try #require(reader.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.name)])).first)
                                    let config = try #require(WorkspaceConfigManager.export(workspace: owner, modelContext: reader))
                                    #expect(config.tasks?.count == expectedTasks)
                                    #expect(config.tasks?.reduce(0, { $0 + $1.events.count }) == expectedEvents)
                                }
                            }
                        }.value
                    case "cleanup":
                        let aggregate = StartupCleanupAggregate()
                        try await WorkspacePersistenceWork.$cleanupJob.withValue(aggregate) {
                            let batch = try #require(await WorkspaceCleanupMirrorBatch.prepare(modelContext: context))
                            for owner in workspaces { #expect(await batch.write(workspaceID: owner.id, modelContext: context)) }
                        }
                        #expect(aggregate.fields()["copy_succeeded"] == "1")
                        try autoreleasepool {
                            var tasks = 0, events = 0
                            for owner in workspaces {
                                let url = try #require(WorkspaceConfigManager.autoExportTarget(for: owner.primaryPath).url)
                                let config = try WorkspaceConfigManager.loadConfig(from: url)
                                tasks += config.tasks?.count ?? 0
                                events += config.tasks?.reduce(0, { $0 + $1.events.count }) ?? 0
                            }
                            #expect(tasks == expectedTasks)
                            #expect(events == expectedEvents)
                        }
                    default:
                        workspace.name = String(format: "A Synthetic %04d", block)
                        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: workspace, modelContext: context)
                        if mode == "failure" {
                            await WorkspaceExportFileIO.$writeStaging.withValue({ _, _ in
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                            }) { #expect(await !WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: workspace, modelContext: context)) }
                            #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 1)
                            #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1)
                        } else if mode == "termination" || mode == "cancellation" {
                            let latch = ExportEvidenceLatch()
                            let job = try #require(WorkspacePersistenceCoordinator.enqueueSavedAutoExport(workspace: workspace,
                                modelContext: context, reader: WorkspaceSavedAutoExport(beforeProjection: { await latch.pause() })))
                            try await latch.wait()
                            if mode == "termination" { #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1) }
                            else { job.cancel() }
                            await latch.release()
                            await job.value
                            if mode == "cancellation" { #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) == 1) }
                        } else {
                            #expect(WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context))
                            await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: workspace.id)
                        }
                        try autoreleasepool {
                            let url = try #require(WorkspaceConfigManager.autoExportTarget(for: workspace.primaryPath).url)
                            let config = try WorkspaceConfigManager.loadConfig(from: url)
                            #expect(config.name == workspace.name)
                            #expect(config.tasks?.count == expectedTasks)
                            #expect(config.tasks?.reduce(0, { $0 + $1.events.count }) == expectedEvents)
                        }
                    }
                    #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
                    try await Task.sleep(for: .milliseconds(100))
                    try observed.sample(block: block, root: root)
                    if pauseSeconds > 0 && (block == 0 || block == blocks) {
                        print("EXPORT_PROFILE_READY pid=\(getpid()) block=\(block)")
                        fflush(stdout)
                        if let marker = env["ASTRA_EXPORT_PROFILE_READY_FILE"] {
                            let data = try JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "block": block])
                            try data.write(to: URL(fileURLWithPath: marker), options: .atomic)
                        }
                        try await Task.sleep(for: .seconds(pauseSeconds))
                    }
                }
            }
        }
        #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == expectedEvents)
        // Deliberately opt-in failure until the demonstrated lifetime defect is
        // fixed. Keep measuring all blocks before enforcing the contract.
        if mode != "history" { #expect(!observed.identities.isEmpty) }
        if env["ASTRA_EXPORT_ASSERT_TEARDOWN"] == "1" {
            #expect(openSnapshotDescriptors(observed.identities).isEmpty)
            #expect(observed.liveReaders == 0)
        }
    }

    private func stableID(_ kind: Int, _ index: Int) -> UUID {
        UUID(uuidString: String(format: "20261106-0000-0000-%04x-%012x", kind, index))!
    }

    private func seed(_ container: ModelContainer, root: URL, large: Bool, eventCount: Int) throws {
        try autoreleasepool {
            let c = ModelContext(container)
            c.autosaveEnabled = false
            for index in 0..<2 {
                let path = root.appendingPathComponent("workspace-\(index)")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                let owner = Workspace(name: index == 0 ? "A Synthetic" : "B Empty", primaryPath: path.path)
                owner.id = stableID(1, index)
                owner.createdAt = Date(timeIntervalSince1970: 0); owner.updatedAt = owner.createdAt
                c.insert(owner)
            }
            try c.save()
        }
        for index in 0..<(large ? 2200 : 12) {
            try autoreleasepool {
                let c = ModelContext(container)
                c.autosaveEnabled = false
                let id = stableID(1, 0)
                let owner = try #require(c.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
                let task = AgentTask(title: "Synthetic \(index)", goal: "Export fixture 20261106", workspace: owner)
                task.id = stableID(2, index)
                task.createdAt = Date(timeIntervalSince1970: 0); task.updatedAt = task.createdAt
                c.insert(task)
                let run = TaskRun(task: task); run.id = stableID(3, index)
                run.startedAt = Date(timeIntervalSince1970: 0)
                c.insert(run)
                try c.save()
            }
        }
        for start in stride(from: 0, to: eventCount, by: 1000) {
            try autoreleasepool {
                let c = ModelContext(container)
                c.autosaveEnabled = false
                let taskID = stableID(2, 0), runID = stableID(3, 0)
                let task = try #require(c.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first)
                let run = try #require(c.fetch(FetchDescriptor<TaskRun>(predicate: #Predicate { $0.id == runID })).first)
                for e in start..<min(start + 1000, eventCount) {
                    // Existing mirrors cap display events at ten but retain
                    // validation/recovery evidence. Stress complete output
                    // through that supported contract, without changing it.
                    let event = TaskEvent(task: task, type: "validation.synthetic", payload: "Synthetic \(e) " + String(repeating: "x", count: 128), run: run)
                    event.id = stableID(4, e)
                    event.timestamp = Date(timeIntervalSince1970: Double(e))
                    c.insert(event)
                }
                task.updatedAt = Date(timeIntervalSince1970: 0)
                try c.save()
            }
        }
    }
}

private actor ExportEvidenceLatch {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func wait() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(entered)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ExportReaderEvidence: @unchecked Sendable {
    private final class Reader: @unchecked Sendable {
        weak var container: ModelContainer?
        weak var context: ModelContext?
        init(_ container: ModelContainer, _ context: ModelContext) { self.container = container; self.context = context }
    }
    private let state = OSAllocatedUnfairLock(initialState: (readers: [Reader](), files: Set<SnapshotFileIdentity>()))
    var identities: Set<SnapshotFileIdentity> { state.withLock { $0.files } }
    var liveReaders: Int { state.withLock { $0.readers.filter { $0.container != nil || $0.context != nil }.count } }
    func reader(_ container: ModelContainer, _ context: ModelContext) {
        let reader = Reader(container, context)
        state.withLock { $0.readers.append(reader) }
    }
    func copied(_ files: Set<SnapshotFileIdentity>) { state.withLock { $0.files.formUnion(files) } }
    @MainActor func sample(block: Int, root: URL) throws {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(result == KERN_SUCCESS)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        var unlinked: [SnapshotFileIdentity: Int64] = [:]
        var descriptors = 0
        let files = identities
        for fd in 0..<Int32(getdtablesize()) {
            var value = stat()
            if fstat(fd, &value) == 0, files.contains(SnapshotFileIdentity(value)) {
                descriptors += 1
                if value.st_nlink == 0 { unlinked[SnapshotFileIdentity(value)] = value.st_size }
            }
        }
        let children = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let weakCounts = state.withLock { value in
            (value.readers.count, value.readers.filter { $0.container != nil }.count, value.readers.filter { $0.context != nil }.count)
        }
        let addresses = state.withLock { value in
            value.readers.compactMap { $0.context }.prefix(3).map {
                String(describing: Unmanaged.passUnretained($0).toOpaque())
            }
        }
        let record: [String: Any] = ["block": block, "footprint_bytes": info.phys_footprint,
            "rss_bytes": info.resident_size, "malloc_live_bytes": stats.size_in_use,
            "malloc_live_blocks": stats.blocks_in_use, "readers_observed": weakCounts.0,
            "containers_alive": weakCounts.1, "contexts_alive": weakCounts.2,
            "context_addresses": addresses,
            "snapshot_descriptors": descriptors, "unlinked_inodes": unlinked.count,
            "unlinked_bytes": unlinked.values.reduce(0, +),
            "snapshot_directories": children.filter { $0.lastPathComponent.hasPrefix(".astra-mirror-") && !$0.lastPathComponent.hasSuffix(".lock") }.count,
            "staging_files": children.filter { $0.lastPathComponent.contains(".astra-export-") }.count,
            "awaited_jobs_active": 0,
            "pending_jobs": WorkspacePersistenceCoordinator.pendingExportWorkspaceCount]
        print("EXPORT_EVIDENCE " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
    }
}
