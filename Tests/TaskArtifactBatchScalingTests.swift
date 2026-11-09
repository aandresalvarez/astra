import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Artifact relationship batching cost", .serialized)
@MainActor
struct TaskArtifactBatchScalingTests {
    @Test("A large batch does not allocate one task graph per new artifact")
    func largeBatchAllocationCost() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let task = AgentTask(title: "Synthetic large artifact batch", goal: "Produce files")
        context.insert(task)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-batch-allocation-\(UUID())")
        try autoreleasepool {
            task.artifacts = (0..<4_096).map {
                Artifact(task: task, type: "txt", path: root.appendingPathComponent("old-\($0).txt").path)
            }
            try context.save()
        }
        let files = (0..<512).map {
            TaskOutputDiscoveredFile(path: root.appendingPathComponent("new-\($0).txt").path,
                                     relativePath: "new-\($0).txt", type: "txt")
        }
        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        try autoreleasepool {
            let result = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: task, modelContext: context)
            // Measure before draining autoreleased relationship bookkeeping.
            // 64 MiB leaves room for the real rows and their summary, but not
            // hundreds of copied 4,096-row inverse graphs. All malloc zones
            // are included; this is allocated heap, not RSS or disk space.
            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            let allocatedBytes = Int(after.size_in_use) - Int(before.size_in_use)
            print("[artifact-batch-allocation] existing=4096 added=512 heap_delta_bytes=\(allocatedBytes)")
            #expect(allocatedBytes < 64 * 1_024 * 1_024)
            #expect(result.createdArtifacts.count == 512)
            try context.save()
            #expect(task.artifacts.count == 4_608)
            #expect(try context.fetchCount(FetchDescriptor<Artifact>()) == 4_608)
        }
    }

    @Test("Reconciliation costs less than half of repeated growing-relationship writes")
    func bulkRelationshipCost() throws {
        // Independent legacy control on the same machine. Include all of the
        // service's normalization/stat work in the candidate, but give the
        // control only insertion work: the service must still beat it.
        let control = try measure(useService: false)
        let batch = try measure(useService: true)
        print("[artifact-batch] existing=1024 added=512 legacy_cpu_ms=\(control) batch_cpu_ms=\(batch)")
        #expect(batch < control * 0.5)
    }

    private func measure(useService: Bool) throws -> Double {
        try autoreleasepool {
            let container = try ModelContainer(
                for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let task = AgentTask(title: "Synthetic artifact scaling", goal: "Generate outputs")
            context.insert(task)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-batch-scaling-\(UUID())")
            task.artifacts = (0..<1_024).map {
                Artifact(task: task, type: "txt", path: root.appendingPathComponent("old-\($0).txt").path)
            }
            try context.save()
            let files = (0..<512).map {
                TaskOutputDiscoveredFile(path: root.appendingPathComponent("new-\($0).txt").path,
                                         relativePath: "new-\($0).txt", type: "txt")
            }
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            if useService {
                let result = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(files, for: task, modelContext: context)
                #expect(result.createdArtifacts.count == 512)
            } else {
                for file in files {
                    let artifact = Artifact(task: task, type: "txt", path: file.path)
                    context.insert(artifact)
                    task.artifacts.append(artifact)
                }
            }
            let milliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
            try context.save()
            #expect(task.artifacts.count == 1_536)
            #expect(try context.fetchCount(FetchDescriptor<Artifact>()) == 1_536)
            return milliseconds
        }
    }
}
