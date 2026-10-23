import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// End-to-end main-thread CPU cost, including SwiftData insert/save work.
/// Disk-backed fixtures refault between actions; a history-wide scan must
/// exceed this budget even on a warm store. No cost is subtracted or excused.
@Suite("Long-chat main-actor cost stays bounded", .serialized)
@MainActor
struct TaskMainActorScalingGateTests {
    /// A tenfold history increase, spanning the user's 2,700-event case.
    static let smallHistory = 500
    static let largeHistory = 5_000
    /// `SCALING_GATE_REPETITIONS` lengthens the run so a profiler can attach.
    static let repetitions = max(1, Int(ProcessInfo.processInfo.environment["SCALING_GATE_REPETITIONS"] ?? "") ?? 5)

    enum Budget {
        static let growthMilliseconds = 80.0
        static let largeHistoryMilliseconds = 100.0
        // Launch copies the complete history, including agent metadata. It
        // has a separate linear-copy budget; the interactive reads above
        // must still avoid history-wide work and keep their original limits.
        static let launchGrowthMilliseconds = 180.0
        static let launchLargeHistoryMilliseconds = 200.0
    }

    @Test("Send, append, view refresh and complete launch copy stay within their budgets")
    func operationsStayWithinBudget() async throws {
        let small = try await measure(eventCount: Self.smallHistory)
        let large = try await measure(eventCount: Self.largeHistory)
        print("[main-actor-scaling] events=\(Self.smallHistory) \(small.summary)")
        print("[main-actor-scaling] events=\(Self.largeHistory) \(large.summary)")
        for operation in Operation.allCases {
            let smallCost = small.rawMilliseconds[operation] ?? 0
            let largeCost = large.rawMilliseconds[operation] ?? 0
            let growthBudget = operation == .launchSnapshot ? Budget.launchGrowthMilliseconds : Budget.growthMilliseconds
            let largeBudget = operation == .launchSnapshot ? Budget.launchLargeHistoryMilliseconds : Budget.largeHistoryMilliseconds
            #expect(largeCost - smallCost <= growthBudget,
                    "\(operation.rawValue): grew from \(format(smallCost)) to \(format(largeCost)) ms")
            #expect(largeCost <= largeBudget,
                    "\(operation.rawValue): \(format(largeCost)) ms including persistence")
        }
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
        case launchSnapshot = "launch_snapshot"
    }

    struct Measurement {
        var rawMilliseconds: [Operation: Double] = [:]
        var summary: String {
            Operation.allCases.map {
                "\($0.rawValue)_ms=\(format(rawMilliseconds[$0] ?? 0))"
            }.joined(separator: " ")
        }
    }

    private func measure(eventCount: Int) async throws -> Measurement {
        let fixture = try Fixture(eventCount: eventCount)
        defer { fixture.cleanup() }
        let context = fixture.container.mainContext
        let task = try #require(try fixture.task(in: context))
        let queue = TaskQueue(poolSize: 0)
        let gitViewModel = WorkspaceGitViewModel()
        gitViewModel.setup(for: try #require(task.workspace), selectedTask: task)
        defer { gitViewModel.pauseRefresh() }
        var samples: [Operation: [Double]] = [:]
        for repetition in 0..<Self.repetitions {
            // Production refaults the event relationship after every save, so
            // every operation starts from a store-backed task, never from rows
            // a previous repetition already materialized.
            try context.save()
            var submitted = false
            samples[.send, default: []].append(cpuMilliseconds {
                let result = TaskConversationContinuationService.continueConversation(
                    message: "Follow-up \(repetition): refine the report",
                    attachmentPaths: [],
                    task: task,
                    policyLevel: .review,
                    source: "scaling_gate",
                    traceID: "scaling-gate",
                    taskQueue: queue,
                    modelContext: context
                )
                if case .success = result { submitted = true }
            })
            #expect(submitted, "A fast rejection is not a successful send")
            await Task.yield()

            try context.save()
            var saved = false
            samples[.appendEvent, default: []].append(cpuMilliseconds {
                let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Read README.md")
                TaskEventInsertionService.insert(event, into: context)
                do { try context.save(); saved = true } catch { saved = false }
                _ = decisionOutcomes(for: task, fixture: fixture, in: context)
            })
            #expect(saved)
            await Task.yield()

            try context.save()
            samples[.viewUpdate, default: []].append(cpuMilliseconds {
                _ = decisionOutcomes(for: task, fixture: fixture, in: context)
                _ = TaskRuntimePermissionState.build(task: task)
                _ = gitViewModel.activeSelectionScopeLabel
                _ = gitViewModel.unavailableWorktreePath
            })
            await Task.yield()

            try context.save()
            let launch = AgentTaskLaunchSnapshot(task: task)
            samples[.launchSnapshot, default: []].append(cpuMilliseconds {
                let copy = TaskExecutionLaunchSnapshotApplicator.detachedTask(launch, from: task)
                #expect(copy.events.count >= eventCount)
            })
            await Task.yield()
        }
        var measurement = Measurement()
        for (operation, values) in samples {
            measurement.rawMilliseconds[operation] = median(values)
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

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}
