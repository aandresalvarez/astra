import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A task's history reads must cost what that task holds, not what the store
/// holds.
///
/// They used to match rows with `$0.task?.id == taskID`, or with
/// `$0.task?.persistentModelID == owner`. SwiftData writes an optional chain
/// through a relationship as `CASE (ZTASK IS NOT NULL) WHEN 1 THEN … ELSE ? END
/// = ?`, which no index can answer, so every read walked the whole event table.
/// On a production store (185,665 events, 205 MB) each read took 47 to 82 ms
/// whatever the task's size, and a context-state refresh makes six of them:
/// 426 ms on the main thread for a task with 51 events.
///
/// `$0.task != nil && $0.task!.persistentModelID == owner` becomes
/// `ZTASK IS NOT NULL AND ZTASK = ?`, which the relationship's index answers.
/// The nil check matters as much as the unwrap: SwiftData also evaluates the
/// predicate in memory against unsaved rows, where a bare `$0.task!` on a row
/// with no task makes the fetch throw.
@Suite("Task history reads stay inside the task", .serialized)
@MainActor
struct TaskHistoryOwnerQueryTests {
    /// Enough history in other tasks that a walk of the event table costs
    /// several times what the subject's twenty events do. A walk pays per row,
    /// not per byte, so the rows are many and small: with 6,000 wide ones the
    /// optional chain only doubled the cost, and this test did not notice.
    /// They are spread over many tasks because appending to one task's
    /// relationship gets slower with every row it already holds.
    static let otherTasks = 120
    static let eventsPerOtherTask = 200
    static var otherTaskEvents: Int { otherTasks * eventsPerOtherTask }
    static let repetitions = 20

    @Test("Reading one task's history does not slow down as other tasks grow")
    func otherTasksDoNotSlowAReadDown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-owner-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("default.store"))
        )
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Owner query", primaryPath: root.path)
        context.insert(workspace)
        let subject = AgentTask(title: "subject", goal: "g", workspace: workspace)
        context.insert(subject)
        let run = TaskRun(task: subject)
        context.insert(run)
        for index in 0..<20 {
            context.insert(TaskEvent(
                task: subject,
                type: index % 2 == 0 ? "user.message" : "agent.response",
                payload: "event \(index)",
                run: run
            ))
        }
        try context.save()

        let alone = cpuMilliseconds { readHistory(of: subject, run: run) }

        for taskIndex in 0..<Self.otherTasks {
            let other = AgentTask(title: "other \(taskIndex)", goal: "g", workspace: workspace)
            context.insert(other)
            for index in 0..<Self.eventsPerOtherTask {
                context.insert(TaskEvent(task: other, type: "tool.result", payload: "other \(index)"))
            }
            if taskIndex % 10 == 9 { try context.save() }
        }
        try context.save()

        let crowded = cpuMilliseconds { readHistory(of: subject, run: run) }
        print("[owner-query] alone_ms=\(alone) crowded_ms=\(crowded) other_events=\(Self.otherTaskEvents)")
        // Measured here: 38 ms alone; crowded, 39 ms through the index and
        // 154 ms through an optional chain. Twice the cost alone, plus a floor
        // for timer granularity, sits well clear of both.
        #expect(crowded <= alone * 2 + 10,
                "history reads grew from \(alone) ms to \(crowded) ms when other tasks gained \(Self.otherTaskEvents) events")
    }

    @Test("A task that was never saved still reads its own unsaved history")
    func unsavedTaskReadsItsOwnHistory() throws {
        // Held for the whole test: a context whose container is gone traps.
        let container = try inMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let workspace = Workspace(name: "Unsaved", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let saved = AgentTask(title: "saved", goal: "g", workspace: workspace)
        context.insert(saved)
        context.insert(TaskEvent(task: saved, type: "user.message", payload: "saved"))
        try context.save()

        let unsaved = AgentTask(title: "unsaved", goal: "g", workspace: workspace)
        context.insert(unsaved)
        let run = TaskRun(task: unsaved)
        context.insert(run)
        context.insert(TaskEvent(task: unsaved, type: "user.message", payload: "first", run: run))
        context.insert(TaskEvent(task: unsaved, type: "agent.response", payload: "second", run: run))

        #expect(TaskHistoryRead.events(for: unsaved).map(\.payload).sorted() == ["first", "second"])
        #expect(TaskHistoryRead.events(for: unsaved, ofTypes: ["user.message"]).map(\.payload) == ["first"])
        #expect(TaskHistoryRead.events(for: unsaved, runID: run.id).count == 2)
        #expect(TaskHistoryRead.runs(for: unsaved).map(\.id) == [run.id])
        #expect(TaskEventTypeLookup.events(ofType: "agent.response", task: unsaved).map(\.payload) == ["second"])
        #expect(TaskHistoryRead.events(for: saved).map(\.payload) == ["saved"])
    }

    @Test("An unsaved row with no task is skipped, not thrown on")
    func rowWithoutATaskDoesNotBreakTheFetch() throws {
        // Held for the whole test: a context whose container is gone traps.
        let container = try inMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let workspace = Workspace(name: "Orphan", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let task = AgentTask(title: "task", goal: "g", workspace: workspace)
        context.insert(task)
        context.insert(TaskEvent(task: task, type: "user.message", payload: "kept"))
        try context.save()
        let owner = task.persistentModelID

        // A fork copies events before it attaches them, so a pending row with
        // no task is a state the app passes through.
        let orphan = TaskEvent(task: task, type: "user.message", payload: "orphan")
        context.insert(orphan)
        orphan.task = nil

        // The store's own answer, with no fallback behind it: the readers
        // below would hide a throw by scanning the relationship instead.
        let guarded = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task != nil && $0.task!.persistentModelID == owner
        }))
        #expect(guarded.map(\.payload) == ["kept"])
        // Without the nil check this fetch throws "Found nil when unwrapping"
        // on macOS 27.2. Not asserted: it is SwiftData's behaviour to change,
        // and the check costs nothing if it does.

        #expect(TaskHistoryRead.events(for: task).map(\.payload) == ["kept"])
        #expect(TaskEventTypeLookup.events(ofType: "user.message", task: task).map(\.payload) == ["kept"])
        try context.save()
        #expect(TaskHistoryRead.events(for: task, ofTypes: ["user.message"]).map(\.payload) == ["kept"])
    }

    @Test("Every store query reaches a task through a checked unwrap")
    func predicatesReachTheTaskThroughACheckedUnwrap() throws {
        let sources = try TestRepositoryRoot.resolve().appendingPathComponent("Astra", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = Self.predicateBodies(in: source).filter(Self.reachesTaskUnsafely).count
            if count > 0 {
                offenders.append("\(file.path.dropFirst(sources.path.count + 1)) (\(count))")
            }
        }
        #expect(offenders.isEmpty, """
            These predicates reach a row's task through `.task?.`, which makes the store walk the whole \
            table, or through a bare `.task!.`, which throws on an unsaved row with no task. \
            Write `$0.task != nil && $0.task!.persistentModelID == owner`. \(offenders.sorted())
            """)
    }

    @Test("The predicate scan tells the three forms apart")
    func predicateScanTellsTheFormsApart() {
        let source = """
            let a = #Predicate<TaskEvent> { $0.task?.id == taskID && ($0.type == x || $0.type == y) }
            let b = rows.filter { $0.task?.persistentModelID == owner }
            let c = FetchDescriptor<TaskRun>(predicate: #Predicate { run in
                run.task!.persistentModelID == owner
            })
            let d = #Predicate<TaskEvent> { event in
                event.task != nil && event.task!.persistentModelID == owner && event.type == x
            }
            """
        let bodies = Self.predicateBodies(in: source)
        #expect(bodies.count == 3)
        #expect(bodies.map(Self.reachesTaskUnsafely) == [true, true, false])
    }

    /// The text between the braces that follow each `#Predicate`.
    static func predicateBodies(in source: String) -> [Substring] {
        var bodies: [Substring] = []
        var search = source.startIndex
        while let marker = source.range(of: "#Predicate", range: search..<source.endIndex),
              let open = source[marker.upperBound...].firstIndex(of: "{") {
            var depth = 0
            var close = source.endIndex
            for index in source[open...].indices {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" {
                    depth -= 1
                    if depth == 0 { close = index; break }
                }
            }
            bodies.append(source[open..<close])
            search = close
        }
        return bodies
    }

    /// Whether a predicate body optional-chains through `task`, or unwraps it
    /// without the nil check in front.
    static func reachesTaskUnsafely(_ body: Substring) -> Bool {
        if body.contains(".task?.") { return true }
        let unwraps = body.components(separatedBy: ".task!.").count - 1
        let checked = body.components(separatedBy: ".task != nil && ").count - 1
        return unwraps > checked
    }

    private func inMemoryContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func readHistory(of task: AgentTask, run: TaskRun) {
        for _ in 0..<Self.repetitions {
            _ = TaskHistoryRead.events(for: task, ofTypes: ["user.message", "agent.response"])
            _ = TaskHistoryRead.events(for: task, runID: run.id)
            _ = TaskHistoryRead.runs(for: task)
            _ = TaskEventTypeLookup.events(ofType: "user.message", task: task)
            _ = TaskPlanService.reconstruct(for: task)
        }
    }

    /// This thread's CPU time, so a busy machine does not decide the result.
    private func cpuMilliseconds(_ work: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        work()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }
}
