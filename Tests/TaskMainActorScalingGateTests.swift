import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// The invariant behind every "the app froze after I pressed Enter" report on
/// a long task: main-actor work per user action or per UI update is bounded by
/// what is visible or what changed, never by the length of the task's history.
///
/// The production profile that motivated this (task 7900335C, ~2,700 events,
/// 53 runs) spent 17.6 of 20 s on the main thread after one send. Each of the
/// fixes before it (#376, #392, #404, #409, #410, #511, #529) removed one scan
/// and the next one surfaced, because the guards were per-file text denylists
/// and a scan moved one call deeper still passed. This gate measures instead
/// of reading source: it seeds the same task at two history lengths and holds
/// each operation's main-thread CPU time to a budget that does not grow with
/// the history.
///
/// SwiftData itself is not flat. Inserting an event walks the task's whole
/// `events` inverse relationship, and the save that follows converts all of
/// it — about 20 ms each at 5,000 events, measured here per run as
/// `SwiftDataFloor`. No query or cache in ASTRA can remove that; only a
/// schema without the to-many inverse can. So the gate charges each operation
/// for the inserts and saves it actually performed, holds what is left —
/// ASTRA's own work — flat, and records the floor's growth as a known issue
/// that fails loudly the day the schema stops paying it.
///
/// Main-thread CPU time rather than wall clock: the full suite runs in
/// parallel, and a wall clock there measures the host. The budgets are wide
/// for the same reason; a scan that faults the history back in at the larger
/// size costs several times them.
@Suite("Main-actor cost does not grow with task history", .serialized)
@MainActor
struct TaskMainActorScalingGateTests {
    /// The two history lengths. The larger is roughly twice the production
    /// task above; the smaller is a task most users have.
    static let smallHistory = 500
    static let largeHistory = 5_000
    /// `SCALING_GATE_REPETITIONS` lengthens the run so a profiler can attach.
    static let repetitions = Int(ProcessInfo.processInfo.environment["SCALING_GATE_REPETITIONS"] ?? "") ?? 5

    enum Budget {
        /// Growth of ASTRA's own work from the small history to the large one.
        static let growthMilliseconds = 15.0
        /// ASTRA's own work at the large history.
        static let largeHistoryMilliseconds = 60.0
        /// What the floor would grow by if SwiftData's relationship upkeep
        /// were flat: noise only.
        static let floorGrowthMilliseconds = 5.0
    }

    @Test("Pressing Enter, appending an event, and refreshing the task view stay flat in history length")
    func operationsStayFlatInHistoryLength() async throws {
        let small = try await measure(eventCount: Self.smallHistory)
        print("[main-actor-scaling] events=\(Self.smallHistory) \(small.summary)")
        let large = try await measure(eventCount: Self.largeHistory)
        print("[main-actor-scaling] events=\(Self.largeHistory) \(large.summary)")
        for operation in Operation.allCases {
            let smallCost = small.astraMilliseconds[operation] ?? 0
            let largeCost = large.astraMilliseconds[operation] ?? 0
            #expect(
                largeCost - smallCost <= Budget.growthMilliseconds,
                "\(operation.rawValue): ASTRA's own main-actor work grew from \(format(smallCost)) ms at \(Self.smallHistory) events to \(format(largeCost)) ms at \(Self.largeHistory)"
            )
            #expect(
                largeCost <= Budget.largeHistoryMilliseconds,
                "\(operation.rawValue): ASTRA's own main-actor work took \(format(largeCost)) ms at \(Self.largeHistory) events"
            )
        }
        withKnownIssue("SwiftData maintains AgentTask.events on every event insert and save, O(history)") {
            #expect(large.floor.insertFirst + large.floor.save - small.floor.insertFirst - small.floor.save
                <= Budget.floorGrowthMilliseconds)
        }
    }

    /// The gate has teeth: the same operations on tasks nobody prepared take
    /// the history-reading paths every caller used before `TaskEventIndex`,
    /// and those exceed the growth budget. If this ever passes the budget, the
    /// fixture or the accounting stopped exercising the history.
    @Test("Without the derived index, the same operations grow with history length")
    func unpreparedTasksStillScanTheHistory() async throws {
        let small = try await measure(eventCount: Self.smallHistory, prepareIndex: false)
        let large = try await measure(eventCount: Self.largeHistory, prepareIndex: false)
        print("[main-actor-scaling] unprepared events=\(Self.largeHistory) \(large.summary)")
        let growth = Operation.allCases.map {
            (large.astraMilliseconds[$0] ?? 0) - (small.astraMilliseconds[$0] ?? 0)
        }.max() ?? 0
        #expect(growth > Budget.growthMilliseconds * 2, "largest growth \(format(growth)) ms")
    }

    // MARK: - Operations

    enum Operation: String, CaseIterable {
        /// `TaskMainView.sendConversationMessage` on a finished task.
        case send
        /// One durable event, as a streaming run records it, plus the task
        /// view's decision-outcome refresh that the new revision triggers.
        case appendEvent = "append_event"
        /// What the task view and the right rail's Git section evaluate when
        /// the task changes: the decision dock and the worktree scope label.
        case viewUpdate = "view_update"
    }

    /// SwiftData's own cost of growing a task's event log by one, at this
    /// history length: the first insert after a save, each further insert
    /// before the next save, and the save.
    struct SwiftDataFloor {
        var insertFirst = 0.0
        var insertNext = 0.0
        var save = 0.0

        func charge(eventsCreated: Int, saves: Int) -> Double {
            let inserts = eventsCreated > 0 ? insertFirst + Double(eventsCreated - 1) * insertNext : 0
            return inserts + Double(saves) * save
        }
    }

    struct Measurement {
        var rawMilliseconds: [Operation: Double] = [:]
        var astraMilliseconds: [Operation: Double] = [:]
        var floor = SwiftDataFloor()
        var summary: String {
            Operation.allCases.map {
                "\($0.rawValue)_ms=\(format(rawMilliseconds[$0] ?? 0)) \($0.rawValue)_astra_ms=\(format(astraMilliseconds[$0] ?? 0))"
            }.joined(separator: " ")
                + " floor_insert_ms=\(format(floor.insertFirst))/\(format(floor.insertNext)) floor_save_ms=\(format(floor.save))"
        }
    }

    /// One measured operation: its main-thread CPU and what SwiftData did
    /// inside it.
    private struct Sample {
        let milliseconds: Double
        let eventsCreated: Int
        let saves: Int
    }

    private func measure(eventCount: Int, prepareIndex: Bool = true) async throws -> Measurement {
        let fixture = try Fixture(eventCount: eventCount)
        defer { fixture.cleanup() }
        let context = fixture.container.mainContext
        let task = try #require(try fixture.task(in: context))
        // The view opened the task before the user typed: whatever it prepares
        // off the main actor on open is ready by the time Enter is pressed.
        if prepareIndex {
            await TaskMainActorScalingGateTests.prepareOpenedTask(task, in: context)
        } else {
            TaskEventIndex.shared.forget(taskID: task.id)
        }

        let queue = TaskQueue(poolSize: 0)
        let gitViewModel = WorkspaceGitViewModel()
        gitViewModel.setup(for: try #require(task.workspace), selectedTask: task)
        defer { gitViewModel.pauseRefresh() }
        let saves = SaveCounter(context: context)

        var samples: [Operation: [Sample]] = [:]
        var floors: [SwiftDataFloor] = []
        let taskID = task.id
        let eventCount = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.task?.id == taskID })
        func sample(_ body: () -> Void) -> Sample {
            let eventsBefore = (try? context.fetchCount(eventCount)) ?? 0
            let savesBefore = saves.count
            let milliseconds = cpuMilliseconds(body)
            let eventsAfter = (try? context.fetchCount(eventCount)) ?? 0
            return Sample(milliseconds: milliseconds, eventsCreated: eventsAfter - eventsBefore, saves: saves.count - savesBefore)
        }
        for repetition in 0..<Self.repetitions {
            // Production refaults the event relationship after every save, so
            // every operation starts from a store-backed task, never from rows
            // a previous repetition already materialized.
            try context.save()
            var floor = SwiftDataFloor()
            floor.insertFirst = cpuMilliseconds {
                context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "floor"))
            }
            floor.insertNext = cpuMilliseconds {
                context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "floor"))
            }
            floor.save = cpuMilliseconds { try? context.save() }
            floors.append(floor)
            await settle(task, in: context, prepareIndex: prepareIndex)

            try context.save()
            samples[.send, default: []].append(sample {
                _ = TaskConversationContinuationService.continueConversation(
                    message: "Follow-up \(repetition): refine the report",
                    attachmentPaths: [],
                    task: task,
                    policyLevel: .review,
                    source: "scaling_gate",
                    traceID: "scaling-gate",
                    taskQueue: queue,
                    modelContext: context
                )
            })
            await settle(task, in: context, prepareIndex: prepareIndex)

            try context.save()
            samples[.appendEvent, default: []].append(sample {
                let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Read README.md")
                TaskEventInsertionService.insert(event, into: context)
                try? context.save()
                _ = decisionOutcomes(for: task, fixture: fixture, in: context)
            })
            await settle(task, in: context, prepareIndex: prepareIndex)

            try context.save()
            samples[.viewUpdate, default: []].append(sample {
                _ = decisionOutcomes(for: task, fixture: fixture, in: context)
                _ = gitViewModel.activeSelectionScopeLabel
                _ = gitViewModel.unavailableWorktreePath
            })
            await settle(task, in: context, prepareIndex: prepareIndex)
        }
        var measurement = Measurement()
        measurement.floor = SwiftDataFloor(
            insertFirst: median(floors.map(\.insertFirst)),
            insertNext: median(floors.map(\.insertNext)),
            save: median(floors.map(\.save))
        )
        for (operation, values) in samples {
            measurement.rawMilliseconds[operation] = median(values.map(\.milliseconds))
            measurement.astraMilliseconds[operation] = median(values.map {
                max(0, $0.milliseconds - measurement.floor.charge(eventsCreated: $0.eventsCreated, saves: $0.saves))
            })
        }
        return measurement
    }

    private func decisionOutcomes(for task: AgentTask, fixture: Fixture, in context: ModelContext) -> TaskDecisionOutcomeCache {
        TaskDecisionOutcomeResolver.outcomes(
            task: task,
            latestRun: fixture.latestRun,
            windowEvents: fixture.windowEvents,
            decisionArtifactPaths: [],
            modelContext: context
        )
    }

    /// Lets whatever the operation scheduled off the main actor land, the way
    /// the next frame would in the app, so it is not charged to the next one.
    /// Re-preparing is a no-op for a prepared task and restores one another
    /// suite's tasks evicted meanwhile.
    private func settle(_ task: AgentTask, in context: ModelContext, prepareIndex: Bool) async {
        if prepareIndex {
            await TaskMainActorScalingGateTests.prepareOpenedTask(task, in: context)
        }
        await Task.yield()
    }

    /// What opening a task prepares before the user can act on it.
    static func prepareOpenedTask(_ task: AgentTask, in context: ModelContext) async {
        await TaskEventIndex.shared.prepare(task)
    }

    // MARK: - Fixture

    /// A finished task shaped like the production one: a pinned worktree, a
    /// policy selection, and runs of one user message, tool traffic, and an
    /// answer each, with an occasional connector proposal. On disk, because
    /// faulting rows back in from the store is the cost under test.
    struct Fixture {
        static let eventsPerRun = 50

        let root: URL
        let container: ModelContainer
        let taskID: UUID
        let latestRun: TaskDecisionOutcomeResolver.LatestRun
        let windowEvents: [TaskOutcomeEventRecord]

        @MainActor
        init(eventCount: Int) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("main-actor-scaling-\(UUID().uuidString)", isDirectory: true)
            let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
            let worktreePath = root.appendingPathComponent("worktree", isDirectory: true)
            try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
            let storeURL = root.appendingPathComponent("scaling.store")

            var seeded: (taskID: UUID, latestRun: TaskDecisionOutcomeResolver.LatestRun, window: [TaskOutcomeEventRecord])
            do {
                let seedContainer = try ModelContainer(
                    for: ASTRASchema.current,
                    migrationPlan: ASTRAMigrationPlan.self,
                    configurations: [ModelConfiguration(url: storeURL)]
                )
                let context = ModelContext(seedContainer)
                context.autosaveEnabled = false
                seeded = try Self.seed(
                    eventCount: eventCount,
                    workspacePath: workspacePath.path,
                    worktreePath: worktreePath.path,
                    into: context
                )
                retainedSeedContainers.append(seedContainer)
            }
            // A second container on the same file: nothing the seed
            // materialized is cached, so the measured context faults from disk.
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            retainedSeedContainers.append(container)
            taskID = seeded.taskID
            latestRun = seeded.latestRun
            windowEvents = seeded.window
        }

        @MainActor
        func task(in context: ModelContext) throws -> AgentTask? {
            let id = taskID
            var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }

        /// The store stays: the queue and the Git view model this fixture
        /// served may still touch it after the test returns, and removing it
        /// under them only turns their reads into I/O errors.
        func cleanup() {}

        private static func seed(
            eventCount: Int,
            workspacePath: String,
            worktreePath: String,
            into context: ModelContext
        ) throws -> (UUID, TaskDecisionOutcomeResolver.LatestRun, [TaskOutcomeEventRecord]) {
            let workspace = Workspace(name: "Scaling", primaryPath: workspacePath)
            context.insert(workspace)
            let task = AgentTask(title: "Long task", goal: "Analyse the cohort and keep the report current", workspace: workspace)
            task.status = .completed
            task.executionRootPath = worktreePath
            context.insert(task)

            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            func tick() -> Date {
                clock = clock.addingTimeInterval(1)
                return clock
            }
            func record(_ type: String, _ payload: String, run: TaskRun? = nil) -> TaskEvent {
                let event = TaskEvent(task: task, type: type, payload: payload, run: run)
                event.timestamp = tick()
                context.insert(event)
                return event
            }

            let prepared = TaskWorktreePayload(
                repositoryPath: workspacePath,
                worktreePath: worktreePath,
                branch: "astra/long-task"
            )
            let preparedJSON = String(decoding: try JSONEncoder().encode(prepared), as: UTF8.self)
            _ = record(TaskEventTypes.Task.worktreePrepared.rawValue, preparedJSON)
            _ = record(TaskPolicyStore.selectedPolicyEventType, #"{"level":"review","source":"seed","selectedAt":0}"#)

            let toolResult = String(repeating: "result line with some realistic width to it\n", count: 24)
            let answer = String(repeating: "The cohort summary is unchanged except for the refined counts. ", count: 16)
            let runCount = max(1, eventCount / eventsPerRun)
            var latest: TaskRun?
            var window: [TaskOutcomeEventRecord] = []
            for index in 0..<runCount {
                let run = TaskRun(task: task)
                run.startedAt = tick()
                context.insert(run)
                var runEvents: [TaskEvent] = []
                runEvents.append(record(TaskEventTypes.Conversation.userMessage.rawValue, "Follow-up \(index): refine the report", run: run))
                for call in 0..<((eventsPerRun - 2) / 2) {
                    runEvents.append(record(TaskEventTypes.Tool.use.rawValue, #"{"tool":"Read","input":{"file_path":"notes/\#(call).md"}}"#, run: run))
                    runEvents.append(record(TaskEventTypes.Tool.result.rawValue, toolResult, run: run))
                }
                runEvents.append(record(TaskEventTypes.Conversation.agentResponse.rawValue, answer, run: run))
                run.status = .completed
                run.stopReason = TaskRunStopReason.completed.rawValue
                run.completedAt = tick()
                latest = run
                if index == runCount - 1 {
                    window = runEvents.map {
                        TaskOutcomeEventRecord(id: $0.id, runID: run.id, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
                    }
                }
                if index.isMultiple(of: 500) {
                    try context.save()
                }
            }
            task.updatedAt = tick()
            try context.save()
            let run = try #require(latest)
            return (task.id, .init(id: run.id, startedAt: run.startedAt), window)
        }
    }
}

/// Containers are kept alive for the life of the test process: a container
/// torn down under live model objects traps in an unrelated later suite.
@MainActor private var retainedSeedContainers: [ModelContainer] = []

/// CPU time the calling thread spends in `body`. The suite is main-actor
/// isolated, so this is the main thread's own work, whatever else the
/// machine is doing.
@MainActor
private func cpuMilliseconds(_ body: () -> Void) -> Double {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    return Double(end - start) / 1_000_000
}

private func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

/// Counts the saves of one context. SwiftData posts `didSave` on the thread
/// that saved, so the count is current as soon as `save()` returns.
@MainActor
private final class SaveCounter {
    private(set) var count = 0
    private var observer: (any NSObjectProtocol)?

    init(context: ModelContext) {
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}
