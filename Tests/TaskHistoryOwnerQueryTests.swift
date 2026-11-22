import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A task's history reads should cost what that task holds, not what the
/// store holds, and must return the same rows on every supported system.
///
/// The portable predicate, `$0.task?.id == taskID`, is an optional chain
/// through a relationship. SwiftData writes it as `CASE (ZTASK IS NOT NULL)
/// WHEN 1 THEN … END = ?`, which no index can answer, so each read walks the
/// whole event table: 40 to 70 ms on a production store with 185,665 events,
/// whatever the task's size, several times per context refresh.
///
/// `$0.task != nil && $0.task!.persistentModelID == owner` becomes
/// `ZTASK IS NOT NULL AND ZTASK = ?` on the relationship's index, but SwiftData
/// only runs it from macOS 27; before that the fetch throws
/// `unsupportedPredicate`. `TaskOwnerPredicate` chooses between the two, so
/// these tests exercise the indexed form where it exists and the portable one
/// elsewhere, and hold both to the same answers.
@Suite("Task history reads stay inside the task", .serialized)
@MainActor
struct TaskHistoryOwnerQueryTests {
    /// Enough history in other tasks that a walk of the event table costs
    /// several times what the subject's twenty events do. A walk pays per row,
    /// not per byte, so the rows are many and small. They are spread over many
    /// tasks because appending to one task's relationship gets slower with
    /// every row it already holds.
    static let otherTasks = 120
    static let eventsPerOtherTask = 200
    static var otherTaskEvents: Int { otherTasks * eventsPerOtherTask }
    static let repetitions = 20

    @Test("Where the index can be used, reading one task's history does not slow down as other tasks grow")
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
        // Before macOS 27 the reads are the portable scans, which do grow
        // with the store; there is nothing to hold them to.
        guard TaskOwnerPredicate.usesRelationshipIndex(for: subject.persistentModelID, in: context) else { return }

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
        // Twice the cost alone, plus a floor for timer granularity. Through
        // the portable scans the crowded read costs about four times as much.
        #expect(crowded <= alone * 2 + 10,
                "history reads grew from \(alone) ms to \(crowded) ms when other tasks gained \(Self.otherTaskEvents) events")
    }

    /// The same expectations hold whichever predicate the system gets: the
    /// indexed one from macOS 27, the portable one before. Each reader is
    /// compared with a walk of the task's own relationship, so neither form is
    /// the other's reference.
    @Test("Every reader returns exactly the task's rows, with a twin task sharing its UUID")
    func readersAgreeWithTheRelationship() throws {
        let container = try inMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let workspace = Workspace(name: "Agree", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let task = AgentTask(title: "task", goal: "g", workspace: workspace)
        // Importing a workspace as a duplicate restores task UUIDs, so two
        // live tasks can share one. Only the owner tells their rows apart.
        let twin = AgentTask(title: "twin", goal: "g", workspace: workspace)
        twin.id = task.id
        context.insert(task)
        context.insert(twin)
        let run = TaskRun(task: task)
        let otherRun = TaskRun(task: task)
        let twinRun = TaskRun(task: twin)
        // Runs whose output carries protocol events are the plan's recovery
        // runs; `otherRun` has none.
        run.setOutput("ASTRA_EVENT own")
        twinRun.setOutput("ASTRA_EVENT twin")
        #expect(run.hasProtocolEvents == true && otherRun.hasProtocolEvents == false)
        context.insert(run)
        context.insert(otherRun)
        context.insert(twinRun)
        let planned: String = TaskPlanEventTypes.created
        let stepped: String = TaskPlanEventTypes.stepStarted
        let kinds: [String] = ["user.message", "agent.response", "tool.use", "plan.custom", planned, stepped]
        for (index, kind) in (kinds + kinds).enumerated() {
            let owningRun: TaskRun? = index % 3 == 0 ? nil : (index % 3 == 1 ? run : otherRun)
            context.insert(TaskEvent(task: task, type: kind, payload: "payload \(index % 4)", run: owningRun))
            context.insert(TaskEvent(task: twin, type: kind, payload: "payload \(index % 4)", run: twinRun))
        }
        try context.save()
        // One unsaved row as well: a fetch has to merge pending changes.
        context.insert(TaskEvent(task: task, type: "user.message", payload: "payload 0", run: run))

        let own: [TaskEvent] = task.events.filter { !$0.isDeleted }
        #expect(own.count == 13)
        /// `actual` must be exactly the task's own rows that `matches` keeps.
        func check(_ label: String, _ actual: [TaskEvent], _ matches: (TaskEvent) -> Bool) {
            let returned: [UUID] = actual.map(\.id).sorted { $0.uuidString < $1.uuidString }
            let wanted: [UUID] = own.filter(matches).map(\.id).sorted { $0.uuidString < $1.uuidString }
            #expect(returned == wanted, "\(label)")
        }
        let someID: UUID = try #require(own.first?.id)
        let types: Set<String> = ["user.message", "tool.use"]
        let runID: UUID = run.id
        let otherRunID: UUID = otherRun.id

        check("all", TaskHistoryRead.events(for: task)) { _ in true }
        check("types", TaskHistoryRead.events(for: task, ofTypes: types)) { types.contains($0.type) }
        check("types or prefix", TaskHistoryRead.events(for: task, ofTypes: types, orTypePrefix: "plan.")) {
            types.contains($0.type) || $0.type.hasPrefix("plan.")
        }
        check("payload", TaskHistoryRead.events(for: task, matchingPayload: "payload 1")) { $0.payload == "payload 1" }
        check("run", TaskHistoryRead.events(for: task, runID: runID)) { $0.run?.id == runID }
        let found: UUID? = TaskHistoryRead.event(id: someID, in: task)?.id
        #expect(found == someID)
        check("type", TaskEventTypeLookup.events(ofType: "agent.response", task: task)) { $0.type == "agent.response" }
        check("type and run", TaskEventTypeLookup.events(ofType: "tool.use", task: task, run: otherRun)) {
            $0.type == "tool.use" && $0.run?.id == otherRunID
        }

        // The plan reader with an owner returns only the task's plan events
        // and recovery runs, whichever predicates ran. A twin's runs applied
        // to this task's plan could complete or block steps that are not
        // theirs. Without an owner the UUID is all it can match on.
        let planKinds: Set<String> = [planned, stepped]
        let owner: PersistentIdentifier = task.persistentModelID
        let withOwner = try TaskPlanStateReader.read(taskID: task.id, owner: owner, modelContext: context)
        let withoutOwner = try TaskPlanStateReader.read(taskID: task.id, modelContext: context)
        check("plan", withOwner.events) { planKinds.contains($0.type) }
        let ownedPlanEvents: [TaskEvent] = withoutOwner.events.filter { $0.task?.persistentModelID == owner }
        let withOwnerIDs: [UUID] = withOwner.events.map(\.id)
        let ownedIDs: [UUID] = ownedPlanEvents.map(\.id)
        #expect(withOwnerIDs == ownedIDs, "the same events, in the same order, as the portable read keeps for this task")
        let ownRunIDs: Set<UUID> = [run.id]
        let recoveredRunIDs: Set<UUID> = Set(withOwner.recoveryRuns.map(\.id))
        #expect(recoveredRunIDs == ownRunIDs)
        let unscopedRunIDs: Set<UUID> = Set(withoutOwner.recoveryRuns.map(\.id))
        #expect(unscopedRunIDs.contains(twinRun.id), "without an owner the twin's run comes back too")
        let unscopedEventCount: Int = withoutOwner.events.count
        #expect(unscopedEventCount == withOwner.events.count * 2, "and so do the twin's plan events")
    }

    /// The plan snapshot refresh rebuilds the plan from the reader's rows
    /// directly, with no ownership check of its own.
    @Test("A plan snapshot refresh ignores a twin task's plan events and runs")
    func snapshotRefreshIgnoresATwin() throws {
        let container = try inMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let workspace = Workspace(name: "Twin plan", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let task = AgentTask(title: "task", goal: "g", workspace: workspace)
        let twin = AgentTask(title: "twin", goal: "g", workspace: workspace)
        twin.id = task.id
        context.insert(task)
        context.insert(twin)
        context.insert(TaskRun(task: task))
        try context.save()
        let first: TaskPlanStateSnapshot? = try TaskPlanStateSnapshot.refreshed(
            for: task, modelContext: context, cached: .empty)
        let alone: TaskPlanStateSnapshot = first ?? .empty

        // History on the twin only: a plan event and a run that could carry
        // protocol output.
        context.insert(TaskEvent(task: twin, type: TaskPlanEventTypes.cancelled, payload: "twin"))
        let twinRun = TaskRun(task: twin)
        twinRun.setOutput("ASTRA_EVENT twin")
        #expect(twinRun.hasProtocolEvents == true)
        context.insert(twinRun)
        try context.save()

        let refreshed: TaskPlanStateSnapshot? = try TaskPlanStateSnapshot.refreshed(
            for: task, modelContext: context, cached: alone)
        #expect(refreshed == nil, "the twin's rows changed this task's plan signature")
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

        if TaskOwnerPredicate.usesRelationshipIndex(for: owner, in: context) {
            // The store's own answer, with no fallback behind it: the readers
            // below would hide a throw by scanning the relationship instead.
            // Without the nil check in front of the unwrap this fetch throws
            // "Found nil when unwrapping" on macOS 27.2.
            let guarded = try context.fetch(FetchDescriptor<TaskEvent>(predicate: TaskOwnerPredicate.events(ownedBy: owner)))
            #expect(guarded.map(\.payload) == ["kept"])
        }

        #expect(TaskHistoryRead.events(for: task).map(\.payload) == ["kept"])
        #expect(TaskEventTypeLookup.events(ofType: "user.message", task: task).map(\.payload) == ["kept"])
        try context.save()
        #expect(TaskHistoryRead.events(for: task, ofTypes: ["user.message"]).map(\.payload) == ["kept"])
    }

    /// The forced unwrap throws `unsupportedPredicate` before macOS 27, at
    /// fetch time, on machines no local run covers. It must never be chosen
    /// there, and every indexed predicate must actually run where it is.
    @Test("The indexed predicates are chosen only where SwiftData runs them")
    func indexedPredicatesRunWhereTheyAreChosen() throws {
        let container = try inMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let workspace = Workspace(name: "Capability", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let task = AgentTask(title: "task", goal: "g", workspace: workspace)
        context.insert(task)
        context.insert(TaskEvent(task: task, type: "user.message", payload: "kept"))
        context.insert(Artifact(task: task, type: "markdown", path: "/tmp/kept.md"))
        try context.save()
        let owner = task.persistentModelID

        let indexed: Bool = TaskOwnerPredicate.usesRelationshipIndex(for: owner, in: context)
        if #available(macOS 27, *) {} else {
            #expect(!indexed, "the forced unwrap is unsupported before macOS 27")
        }
        guard indexed else { return }

        let now = Date()
        let eventPredicates: [Predicate<TaskEvent>] = [
            TaskOwnerPredicate.events(ownedBy: owner),
            TaskOwnerPredicate.events(ownedBy: owner, type: "user.message"),
            TaskOwnerPredicate.events(ownedBy: owner, type: "user.message", runID: UUID()),
            TaskOwnerPredicate.events(ownedBy: owner, types: ["user.message"]),
            TaskOwnerPredicate.events(ownedBy: owner, types: ["user.message"], orTypePrefix: "plan."),
            TaskOwnerPredicate.events(ownedBy: owner, types: ["user.message"], orType: "task.stats", withPayloadPrefix: "x"),
            TaskOwnerPredicate.events(ownedBy: owner, excludingTypes: "a", "b", "c"),
            TaskOwnerPredicate.events(ownedBy: owner, payload: "kept"),
            TaskOwnerPredicate.events(ownedBy: owner, runID: UUID()),
            TaskOwnerPredicate.events(ownedBy: owner, id: UUID()),
            TaskOwnerPredicate.events(ownedBy: owner, ids: [UUID()]),
            TaskOwnerPredicate.events(ownedBy: owner, since: now.addingTimeInterval(-60))
        ]
        for (index, predicate) in eventPredicates.enumerated() {
            #expect(throws: Never.self, "event predicate \(index)") {
                _ = try context.fetch(FetchDescriptor<TaskEvent>(predicate: predicate))
            }
        }
        let artifacts = try context.fetch(FetchDescriptor<Artifact>(predicate: TaskOwnerPredicate.artifacts(ownedBy: owner)))
        #expect(artifacts.count == 1)
    }

    @Test("Forced unwraps in store queries are checked, and live only in TaskOwnerPredicate")
    func forcedUnwrapsStayInOnePlace() throws {
        let sources = try TestRepositoryRoot.resolve().appendingPathComponent("Astra", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var checkedUnwraps = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let bodies = Self.predicateBodies(in: source)
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            if relative == "Models/TaskOwnerPredicate.swift" {
                let unchecked = bodies.filter(Self.unwrapsWithoutACheck).count
                checkedUnwraps += bodies.filter(Self.unwrapsARelationship).count - unchecked
                if unchecked > 0 { offenders.append("\(relative) (\(unchecked) unchecked)") }
            } else {
                let count = bodies.filter(Self.unwrapsARelationship).count
                if count > 0 { offenders.append("\(relative) (\(count))") }
            }
        }
        #expect(offenders.isEmpty, """
            A forced unwrap in a predicate throws `unsupportedPredicate` before macOS 27, and without a nil \
            check in front it throws on an unsaved row. Add the predicate to `TaskOwnerPredicate` as \
            `$0.task != nil && $0.task!.persistentModelID == owner` and choose it with `pick`. \(offenders.sorted())
            """)
        #expect(checkedUnwraps > 0, "the scan found no predicates in TaskOwnerPredicate.swift")
    }

    @Test("The predicate scan tells the forms apart")
    func predicateScanTellsTheFormsApart() {
        let source = """
            let a = #Predicate<TaskEvent> { $0.task?.id == taskID && ($0.type == x || $0.type == y) }
            let b = rows.filter { $0.task!.persistentModelID == owner }
            let c = FetchDescriptor<TaskRun>(predicate: #Predicate { run in
                run.task!.persistentModelID == owner
            })
            let d = #Predicate<TaskEvent> { event in
                event.task != nil && event.task!.persistentModelID == owner && event.type == x
            }
            """
        let bodies = Self.predicateBodies(in: source)
        #expect(bodies.count == 3)
        #expect(bodies.map(Self.unwrapsARelationship) == [false, true, true])
        #expect(bodies.map(Self.unwrapsWithoutACheck) == [false, true, false])
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

    /// Whether a predicate body force-unwraps a row's task or run.
    static func unwrapsARelationship(_ body: Substring) -> Bool {
        body.contains(".task!.") || body.contains(".run!.")
    }

    /// Whether it does so without the nil check in front.
    static func unwrapsWithoutACheck(_ body: Substring) -> Bool {
        for relationship in ["task", "run"] {
            let unwraps = body.components(separatedBy: ".\(relationship)!.").count - 1
            let checked = body.components(separatedBy: ".\(relationship) != nil && ").count - 1
            if unwraps > checked { return true }
        }
        return false
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
