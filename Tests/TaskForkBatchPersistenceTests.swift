import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Fork history graph batching", .serialized)
@MainActor
struct TaskForkBatchPersistenceTests {
    @Test("A saved fork reopens with complete independent history and preserves the checkpoint cutoff")
    func forkGraphSurvivesReopeningAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fork-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelConfiguration(url: root.appendingPathComponent("fork.store"))
        let identities = try autoreleasepool {
            let container = try ModelContainer(for: ASTRASchema.current, configurations: configuration)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let source = makeHistory(events: 384, eventsPerRun: 128)
            let early = TaskEvent(task: source, type: "synthetic.unowned", payload: "before checkpoint")
            early.timestamp = Date(timeIntervalSince1970: 1)
            let late = TaskEvent(task: source, type: "synthetic.unowned", payload: "after checkpoint")
            late.timestamp = Date(timeIntervalSince1970: 10_000)
            source.events += [early, late]
            context.insert(source)
            try context.save()
            let runs = source.runs.sorted(by: TaskRun.isChronologicallyOrdered)
            // A later run's event must stay behind even when its timestamp
            // happens to precede the selected checkpoint.
            let laterEvent = try #require(source.events.first { $0.run === runs[2] })
            laterEvent.timestamp = Date(timeIntervalSince1970: 2)
            try context.save()
            let originalEventIDs = Set(source.events.map(\.id))
            let originalRunIDs = Set(source.runs.map(\.id))

            let fork = try AgentTask.fork(from: source, upToRun: runs[1], in: context)
            try context.save()
            #expect(Set(source.events.map(\.id)) == originalEventIDs)
            #expect(Set(source.runs.map(\.id)) == originalRunIDs)
            #expect(fork.events.count == 258) // 256 run events, early unowned, checkpoint
            #expect(fork.runs.count == 2)
            #expect(Set(fork.events.map(\.id)).isDisjoint(with: originalEventIDs))
            #expect(Set(fork.runs.map(\.id)).isDisjoint(with: originalRunIDs))
            #expect(!fork.events.contains { $0.payload == late.payload || $0.payload == laterEvent.payload })
            return (source.id, fork.id)
        }

        try autoreleasepool {
            let container = try ModelContainer(for: ASTRASchema.current, configurations: configuration)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let tasks = try context.fetch(FetchDescriptor<AgentTask>())
            let source = try #require(tasks.first { $0.id == identities.0 })
            let fork = try #require(tasks.first { $0.id == identities.1 })
            #expect(fork.events.count == 258)
            #expect(fork.runs.count == 2)
            #expect(fork.events.allSatisfy { $0.task === fork })
            #expect(fork.runs.allSatisfy { $0.task === fork && $0.providerSessionId == nil })
            #expect(fork.events.filter { $0.type == "tool.use" }.allSatisfy {
                $0.run?.task === fork && $0.agentName == "Synthetic agent" && $0.teamName == "Synthetic team"
            })
            #expect(fork.events.filter { $0.run != nil }.allSatisfy { event in
                fork.runs.contains { $0.id == event.run?.id }
            })
            #expect(fork.tokensUsed == 256)
            #expect(fork.runs.allSatisfy { $0.output.hasPrefix("Synthetic response") })
            #expect(source.events.count == 386)
            #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == 644)
            context.delete(fork)
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == 386)
            #expect(try context.fetchCount(FetchDescriptor<TaskRun>()) == 3)
            #expect(source.events.count == 386)
        }
    }

    @Test("Rolling back a fork leaves the durable source history intact")
    func rollbackForkGraph() throws {
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let source = makeHistory(events: 256, eventsPerRun: 64)
        context.insert(source)
        try context.save()
        let target = try #require(source.runs.max(by: TaskRun.isChronologicallyOrdered))
        _ = try AgentTask.fork(from: source, upToRun: target, in: context)
        context.rollback()
        // Check durable state in a fresh context; SwiftData may leave an
        // already-held model's relationship cache stale after rollback.
        let reader = ModelContext(container)
        #expect(try reader.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(try reader.fetchCount(FetchDescriptor<TaskRun>()) == 4)
        #expect(try reader.fetchCount(FetchDescriptor<TaskEvent>()) == 256)
        let original = try #require(try reader.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(original.id == source.id)
        #expect(original.events.count == 256)
    }

    @Test("Prefetch preserves relationship ownership and pending history when task UUIDs collide")
    func prefetchedHistoryUsesRelationships() throws {
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let source = makeHistory(events: 16, eventsPerRun: 8)
        let neighbor = makeHistory(events: 16, eventsPerRun: 8)
        neighbor.id = source.id
        neighbor.title = "Unrelated imported task"
        for event in neighbor.events { event.payload = "Foreign history" }
        context.insert(source)
        context.insert(neighbor)
        try context.save()

        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let tasks = try reader.fetch(FetchDescriptor<AgentTask>())
        let coldSource = try #require(tasks.first { $0.title == source.title })
        let target = try #require(coldSource.runs.max(by: TaskRun.isChronologicallyOrdered))
        let pending = TaskEvent(task: coldSource, type: "tool.use", payload: "Pending source history", run: target)
        reader.insert(pending)
        let fork = try AgentTask.fork(from: coldSource, upToRun: target, in: reader)
        try reader.save()
        #expect(fork.events.count == 18) // 16 stored, pending, checkpoint
        #expect(fork.runs.count == 2)
        #expect(fork.events.contains { $0.payload == "Pending source history" })
        #expect(!fork.events.contains { $0.payload == "Foreign history" })
        #expect(fork.events.allSatisfy { $0.task === fork })
    }

    @Test("A complete fork costs less than half of repeated child graph insertions")
    func largeForkInsertionCost() throws {
        let control = try measure(legacyInsertion: true)
        let candidate = try measure(legacyInsertion: false)
        print("[fork-batch] events=4096 runs=64 legacy_cpu_ms=\(control) fork_cpu_ms=\(candidate)")
        #expect(candidate < control * 0.5)
    }

    private func measure(legacyInsertion: Bool) throws -> Double {
        try autoreleasepool {
            let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let task = makeHistory(events: 4_096, eventsPerRun: 64)
            let runs = task.runs
            let events = task.events
            if !legacyInsertion {
                context.insert(task)
                try context.save()
            }
            let target = try #require(runs.max(by: TaskRun.isChronologicallyOrdered))
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            if legacyInsertion {
                // Independent control for the old insertion pattern. It gets
                // no copying, manifest, filtering, or payload-rewrite work;
                // the complete production fork must still beat it.
                context.insert(task)
                runs.forEach(context.insert)
                events.forEach(context.insert)
            } else {
                let fork = try AgentTask.fork(from: task, upToRun: target, in: context)
                #expect(fork.events.count == 4_097)
                #expect(fork.runs.count == 64)
            }
            let elapsed = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<TaskEvent>()) == (legacyInsertion ? 4_096 : 8_193))
            return elapsed
        }
    }

    private func makeHistory(events count: Int, eventsPerRun: Int) -> AgentTask {
        let source = AgentTask(title: "Synthetic fork source", goal: "Preserve the selected history")
        source.sessionId = "synthetic-source-session"
        let runs = (0..<(count / eventsPerRun)).map { index in
            let run = TaskRun(task: source)
            run.status = .completed
            run.startedAt = Date(timeIntervalSince1970: Double(index * eventsPerRun + 10))
            run.completedAt = Date(timeIntervalSince1970: Double((index + 1) * eventsPerRun + 9))
            run.tokensUsed = eventsPerRun
            run.setOutput("Synthetic response \(index)")
            return run
        }
        let events = (0..<count).map { index in
            let event = TaskEvent(task: source, type: "tool.use", payload: "Synthetic event \(index)", run: runs[index / eventsPerRun], agentName: "Synthetic agent", teamName: "Synthetic team")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 10))
            return event
        }
        source.runs = runs
        source.events = events
        return source
    }
}
