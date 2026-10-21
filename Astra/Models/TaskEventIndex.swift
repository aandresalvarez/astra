import Foundation
import SwiftData
import os

/// What rules that read an event need from it, whether they get the live
/// row or the index's record of it.
public protocol TaskEventValue {
    var id: UUID { get }
    var type: String { get }
    var payload: String { get }
    var timestamp: Date { get }
}

extension TaskEvent: TaskEventValue {}

/// One task event as the index keeps it: a value, never a model object.
public struct TaskEventRecord: TaskEventValue, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let runID: UUID?
    public let type: String
    public let payload: String
    public let timestamp: Date

    public init(id: UUID, runID: UUID?, type: String, payload: String, timestamp: Date) {
        self.id = id
        self.runID = runID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }

    public init(event: TaskEvent) {
        self.init(id: event.id, runID: event.run?.id, type: event.type, payload: event.payload, timestamp: event.timestamp)
    }

    /// `TaskEvent.decodePayload(as:)` for a record.
    public func decodePayload<T: Decodable>(
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Result<T, TaskEventPayloadDecodeError> {
        guard let data = payload.data(using: .utf8) else { return .failure(.invalidUTF8) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }

    /// Oldest first; ties broken by id so every reader agrees on one order.
    public static func isChronologicallyOrdered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct TaskRunRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let runStatus: RunStatus
    public let stopReason: String

    public init(id: UUID, startedAt: Date, runStatus: RunStatus, stopReason: String) {
        self.id = id
        self.startedAt = startedAt
        self.runStatus = runStatus
        self.stopReason = stopReason
    }
}

/// The derived facts of one task's event log that the UI and the send path
/// ask for: every sparse event type, grouped by type, plus what is cheap to
/// keep for all of them (ids, count, newest timestamp) and the task's runs.
///
/// It is never persisted, so it is not a second owner of task state: the
/// event log is, and this is rebuilt from it whenever it cannot prove it is
/// current (see `TaskEventIndex`).
public struct TaskEventFacts: Sendable {
    public let taskID: UUID
    /// Moves on every change, so views can key work on it.
    public private(set) var revision: Int = 0
    public private(set) var eventCount: Int = 0
    public private(set) var latestEventAt: Date?
    public private(set) var runs: [TaskRunRecord] = []
    private var eventIDs: Set<UUID> = []
    private var recordsByType: [String: [TaskEventRecord]] = [:]
    private var indexedTypeByID: [UUID: String] = [:]

    public init(taskID: UUID) {
        self.taskID = taskID
    }

    /// The types the index keeps whole. Everything a run streams by the
    /// hundred — tool calls and results, agent text, system notices — is
    /// left out; what is kept is what a task records once per turn or less.
    public static func isIndexed(_ type: String) -> Bool {
        type == "user.message" || indexedPrefixes.contains { type.hasPrefix($0) }
    }

    private static let indexedPrefixes = [
        "astra.policy.",
        "task.",
        "plan.",
        "execution.request.",
        "connector.mutation.",
        "github.review."
    ]

    public func contains(eventID: UUID) -> Bool {
        eventIDs.contains(eventID)
    }

    /// An indexed event by id; nil for an event of a type the index does not
    /// keep.
    public func record(id: UUID) -> TaskEventRecord? {
        guard let type = indexedTypeByID[id] else { return nil }
        return recordsByType[type]?.last { $0.id == id }
    }

    /// The task's events of `type`, oldest first. `type` must be indexed.
    public func records(ofType type: String) -> [TaskEventRecord] {
        precondition(Self.isIndexed(type), "\(type) is not an indexed event type")
        return recordsByType[type] ?? []
    }

    /// The task's events of any of `types`, oldest first. Every type must be
    /// indexed.
    public func records<Types: Sequence>(ofTypes types: Types) -> [TaskEventRecord] where Types.Element == String {
        types.flatMap { records(ofType: $0) }.sorted(by: TaskEventRecord.isChronologicallyOrdered)
    }

    /// Adds one event, or replaces what an already-known event carried (a
    /// source event linked to its run after the fact). Idempotent.
    mutating func fold(_ record: TaskEventRecord) {
        revision &+= 1
        if eventIDs.insert(record.id).inserted {
            eventCount += 1
            if latestEventAt.map({ record.timestamp > $0 }) ?? true {
                latestEventAt = record.timestamp
            }
        } else if Self.isIndexed(record.type) {
            recordsByType[record.type]?.removeAll { $0.id == record.id }
        } else {
            return
        }
        guard Self.isIndexed(record.type) else { return }
        indexedTypeByID[record.id] = record.type
        var records = recordsByType[record.type] ?? []
        // Events arrive in creation order almost always, so this is an append.
        let index = records.lastIndex { TaskEventRecord.isChronologicallyOrdered($0, record) }.map { $0 + 1 } ?? 0
        records.insert(record, at: index)
        recordsByType[record.type] = records
    }

    mutating func remove(eventID: UUID) {
        guard eventIDs.remove(eventID) != nil else { return }
        revision &+= 1
        eventCount -= 1
        if let type = indexedTypeByID.removeValue(forKey: eventID) {
            recordsByType[type]?.removeAll { $0.id == eventID }
        }
    }

    mutating func replaceRuns(_ runs: [TaskRunRecord]) {
        revision &+= 1
        self.runs = runs
    }

    mutating func noteRun(_ run: TaskRunRecord) {
        revision &+= 1
        runs.removeAll { $0.id == run.id }
        runs.append(run)
    }

    mutating func carryRevision(from previous: TaskEventFacts?) {
        if let previous { revision = max(revision, previous.revision &+ 1) }
    }
}

/// The single owner of `TaskEventFacts`: built off the main actor from the
/// store when a task is opened or admitted, then kept current one event at a
/// time from `TaskEvent`'s designated initializer — the one construction
/// point every event passes through — so a reader on the main actor pays for
/// what changed, never for the length of the history.
///
/// What the initializer cannot see (a deletion, a rollback, an event created
/// off the main thread, a run's status moving) marks the entry stale, and the
/// next read schedules an off-main rebuild while it keeps serving the facts it
/// has. The rebuild reads the store, then folds back the main context's
/// unsaved inserts and the events created while it ran, and drops its unsaved
/// deletions, so what it publishes is the context's view, not just the disk's.
///
/// Readers ask only about tasks someone prepared. For any other task
/// `facts(for:)` is nil and callers read `task.events` the way they did before
/// this existed, so a task never opened costs what it always did and nothing
/// is cached for it.
public final class TaskEventIndex: @unchecked Sendable {
    public static let shared = TaskEventIndex()

    /// Prepared tasks kept at once. Preparing one more evicts the least
    /// recently used, which then reads `task.events` again.
    static let defaultCapacity = 32
    let capacity: Int
    /// How long a changing task's runs and unseen mutations may lag.
    static let staleRebuildInterval: TimeInterval = 2

    private struct Entry {
        var facts: TaskEventFacts?
        let container: ModelContainer
        /// The prepared row. Task ids are not unique — importing a workspace
        /// as a duplicate restores the exported ids — so every read and fold
        /// also matches on this.
        let owner: PersistentIdentifier
        var lastUsed: UInt64
        var generation = 0
        /// Non-nil while a rebuild runs: records created in the meantime,
        /// folded again into its result.
        var createdDuringRebuild: [TaskEventRecord]?
        var removedDuringRebuild: Set<UUID> = []
        var stale = false
        var lastRebuildAt = Date.distantPast
        var builtFromUpdatedAt: Date?
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        var clock: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = TaskEventIndex.defaultCapacity) {
        self.capacity = capacity
    }

    // MARK: Reading

    /// Current facts for a prepared task, or nil when it is not prepared or
    /// its first build has not landed. Never blocks on the store.
    public func facts(for task: AgentTask) -> TaskEventFacts? {
        let taskID = task.id
        guard state.withLock({ $0.entries[taskID] != nil }) else { return nil }
        let owner = task.persistentModelID
        let updatedAt = task.updatedAt
        var rebuild: ModelContainer?
        let facts = state.withLock { state -> TaskEventFacts? in
            guard var entry = state.entries[taskID], entry.owner == owner else { return nil }
            state.clock &+= 1
            entry.lastUsed = state.clock
            let changedSinceBuild = entry.builtFromUpdatedAt.map { updatedAt > $0 } ?? false
            let due = Date().timeIntervalSince(entry.lastRebuildAt) >= Self.staleRebuildInterval
            if entry.createdDuringRebuild == nil, entry.stale || (changedSinceBuild && due) {
                rebuild = entry.container
            }
            state.entries[taskID] = entry
            return entry.facts
        }
        if let rebuild {
            Task { @MainActor in await self.rebuild(taskID: taskID, container: rebuild) }
        }
        return facts
    }

    /// `task`'s events of `types`, oldest first: from the index when the
    /// task is prepared, otherwise from `task.events`. Every type must be
    /// indexed (`TaskEventFacts.isIndexed`).
    public static func records(for task: AgentTask, ofTypes types: Set<String>) -> [TaskEventRecord] {
        if let facts = shared.facts(for: task) {
            return facts.records(ofTypes: types)
        }
        return task.events
            .filter { !$0.isDeleted && types.contains($0.type) }
            .map(TaskEventRecord.init(event:))
            .sorted(by: TaskEventRecord.isChronologicallyOrdered)
    }

    /// `task`'s runs: from the index when the task is prepared, otherwise
    /// from `task.runs`.
    public static func runs(for task: AgentTask) -> [TaskRunRecord] {
        if let facts = shared.facts(for: task) { return facts.runs }
        return task.runs.map {
            TaskRunRecord(id: $0.id, startedAt: $0.startedAt, runStatus: $0.status, stopReason: $0.stopReason)
        }
    }

    /// `task`'s event with `eventID`, which must be of an indexed type. A
    /// prepared task answers from the index; a miss is confirmed against
    /// `task.events`, as `contains(eventID:in:)` does.
    public static func record(id eventID: UUID, in task: AgentTask) -> TaskEventRecord? {
        if let record = shared.facts(for: task)?.record(id: eventID) { return record }
        return task.events.first { $0.id == eventID }.map(TaskEventRecord.init(event:))
    }

    /// Whether `task` has an event with `eventID`. A prepared task answers a
    /// yes from the index; a no is confirmed against `task.events`, so a
    /// lagging index can never report a present event missing.
    public static func contains(eventID: UUID, in task: AgentTask) -> Bool {
        if shared.facts(for: task)?.contains(eventID: eventID) == true { return true }
        return task.events.contains { $0.id == eventID }
    }

    public func isPrepared(_ taskID: UUID) -> Bool {
        state.withLock { $0.entries[taskID]?.facts != nil }
    }

    /// Whether `task` itself, not just its id, has readable facts.
    public func isPrepared(_ task: AgentTask) -> Bool {
        facts(for: task) != nil
    }

    // MARK: Preparing

    /// Builds the task's facts off the main actor. Call when a task is
    /// opened or admitted; returns once they are readable.
    @MainActor
    public func prepare(_ task: AgentTask) async {
        guard let context = task.modelContext else { return }
        let container = context.container
        let taskID = task.id
        let owner = task.persistentModelID
        let needsBuild = state.withLock { state -> Bool in
            state.clock &+= 1
            if var entry = state.entries[taskID], entry.owner == owner {
                entry.lastUsed = state.clock
                state.entries[taskID] = entry
                return entry.facts == nil && entry.createdDuringRebuild == nil
            }
            state.entries[taskID] = Entry(facts: nil, container: container, owner: owner, lastUsed: state.clock)
            Self.evictIfNeeded(&state, capacity: capacity)
            return true
        }
        // A build already in flight publishes on its own; until it lands,
        // readers take the legacy path.
        guard needsBuild else { return }
        await rebuild(taskID: taskID, container: container)
    }

    /// `prepare` for the queue: admission and the worker read history
    /// facts, so they are built off the main actor once instead of rescanned
    /// per read. False when the task was deleted while the build, a
    /// suspension point, ran.
    @MainActor
    public func prepareForAdmission(_ task: AgentTask) async -> Bool {
        await prepare(task)
        return !task.isDeleted
    }

    @MainActor
    private func rebuild(taskID: UUID, container: ModelContainer) async {
        let generation: Int? = state.withLock { state in
            guard var entry = state.entries[taskID], entry.createdDuringRebuild == nil else { return nil }
            entry.generation += 1
            entry.createdDuringRebuild = []
            entry.removedDuringRebuild = []
            entry.stale = false
            entry.lastRebuildAt = Date()
            state.entries[taskID] = entry
            return entry.generation
        }
        guard let generation, let owner = state.withLock({ $0.entries[taskID]?.owner }) else { return }
        let builtFromUpdatedAt = Self.updatedAt(of: taskID, in: container.mainContext)
        let built = await Task.detached(priority: .utility) {
            try? TaskEventFactsReader.read(taskID: taskID, container: container)
        }.value
        // Unsaved work in the main context is part of the task as every
        // other main-actor reader sees it.
        let pending = Self.pendingChanges(for: owner, in: container.mainContext)
        state.withLock { state in
            guard var entry = state.entries[taskID], entry.generation == generation else { return }
            let created = entry.createdDuringRebuild ?? []
            entry.createdDuringRebuild = nil
            // A store error, or an id two tasks share: the index cannot
            // answer for this task, so it stops claiming to.
            guard var facts = built else {
                state.entries.removeValue(forKey: taskID)
                return
            }
            defer { state.entries[taskID] = entry }
            for record in pending.inserted + created { facts.fold(record) }
            for id in pending.deleted.union(entry.removedDuringRebuild) { facts.remove(eventID: id) }
            facts.carryRevision(from: entry.facts)
            entry.facts = facts
            entry.builtFromUpdatedAt = builtFromUpdatedAt
        }
    }

    // MARK: Keeping current

    /// Called from `TaskEvent.init`. O(1) for a prepared task, a dictionary
    /// miss for any other.
    func noteCreated(in task: AgentTask, record: TaskEventRecord, run: TaskRunRecord? = nil) {
        let taskID = task.id
        // The identity is read only for a task someone prepared.
        guard state.withLock({ $0.entries[taskID] != nil }) else { return }
        let owner = task.persistentModelID
        state.withLock { state in
            guard var entry = state.entries[taskID], entry.owner == owner else { return }
            entry.facts?.fold(record)
            if let run { entry.facts?.noteRun(run) }
            entry.createdDuringRebuild?.append(record)
            state.entries[taskID] = entry
        }
    }

    /// A source event linked to the run that admitted it.
    public func noteChanged(_ event: TaskEvent) {
        guard let task = event.task else { return }
        noteCreated(in: task, record: TaskEventRecord(event: event))
    }

    /// Deletes `event` and drops it from the index. Every `TaskEvent`
    /// deletion goes through here: most are rollbacks of an insert whose save
    /// failed, which no save notification would ever report.
    public static func delete(_ event: TaskEvent, from modelContext: ModelContext) {
        shared.noteDeleted(eventID: event.id)
        modelContext.delete(event)
    }

    /// The owning task may already be unlinked (`task.events.removeAll`
    /// before the delete), so this looks in every prepared task; there are at
    /// most `capacity`.
    public func noteDeleted(eventID: UUID) {
        state.withLock { state in
            for (taskID, var entry) in state.entries {
                let known = entry.facts?.contains(eventID: eventID) == true
                    || entry.createdDuringRebuild?.contains { $0.id == eventID } == true
                guard known || entry.createdDuringRebuild != nil else { continue }
                entry.facts?.remove(eventID: eventID)
                entry.createdDuringRebuild?.removeAll { $0.id == eventID }
                if entry.createdDuringRebuild != nil { entry.removedDuringRebuild.insert(eventID) }
                state.entries[taskID] = entry
            }
        }
    }

    public func noteRun(_ run: TaskRunRecord, of task: AgentTask) {
        let taskID = task.id
        guard state.withLock({ $0.entries[taskID] != nil }) else { return }
        let owner = task.persistentModelID
        state.withLock { state in
            guard var entry = state.entries[taskID], entry.owner == owner else { return }
            entry.facts?.noteRun(run)
            state.entries[taskID] = entry
        }
    }

    /// Something changed the task's events in a way the initializer did not
    /// see: a rollback, a compaction, a payload rewritten in place. The next
    /// read rebuilds.
    public func markStale(taskID: UUID) {
        state.withLock { state in
            guard var entry = state.entries[taskID] else { return }
            entry.stale = true
            state.entries[taskID] = entry
        }
    }

    public func markAllStale() {
        state.withLock { state in
            for key in state.entries.keys { state.entries[key]?.stale = true }
        }
    }

    public func forget(taskID: UUID) {
        _ = state.withLock { $0.entries.removeValue(forKey: taskID) }
    }

    // MARK: Helpers

    private static func evictIfNeeded(_ state: inout State, capacity: Int) {
        while state.entries.count > capacity,
              let oldest = state.entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            state.entries.removeValue(forKey: oldest)
        }
    }

    @MainActor
    private static func updatedAt(of taskID: UUID, in context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.updatedAt
    }

    @MainActor
    private static func pendingChanges(
        for owner: PersistentIdentifier,
        in context: ModelContext
    ) -> (inserted: [TaskEventRecord], deleted: Set<UUID>) {
        let inserted = context.insertedModelsArray.compactMap { model -> TaskEventRecord? in
            guard let event = model as? TaskEvent, event.task?.persistentModelID == owner else { return nil }
            return TaskEventRecord(event: event)
        }
        let deleted = Set(context.deletedModelsArray.compactMap { model -> UUID? in
            guard let event = model as? TaskEvent else { return nil }
            return event.id
        })
        return (inserted, deleted)
    }
}

/// Reads a task's facts from the store on whatever thread calls it, through a
/// context of its own. Nothing but values leaves it.
enum TaskEventFactsReader {
    struct AmbiguousTaskID: Error {}

    static func read(taskID: UUID, container: ModelContainer) throws -> TaskEventFacts {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // The reads below match on the id; two tasks sharing it would mix.
        guard try context.fetchCount(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })) == 1 else {
            throw AmbiguousTaskID()
        }
        var facts = TaskEventFacts(taskID: taskID)

        var all = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.task?.id == taskID })
        all.propertiesToFetch = [\.id, \.type, \.timestamp]
        var indexed: [TaskEvent] = []
        for event in try context.fetch(all) {
            if TaskEventFacts.isIndexed(event.type) {
                indexed.append(event)
            } else {
                facts.fold(TaskEventRecord(id: event.id, runID: nil, type: event.type, payload: "", timestamp: event.timestamp))
            }
        }
        // Payload and run only for the sparse rows that need them.
        for event in indexed.sorted(by: { $0.timestamp < $1.timestamp }) {
            facts.fold(TaskEventRecord(event: event))
        }

        let runs = try context.fetch(FetchDescriptor<TaskRun>(predicate: #Predicate { $0.task?.id == taskID }))
        facts.replaceRuns(runs.map {
            TaskRunRecord(id: $0.id, startedAt: $0.startedAt, runStatus: $0.status, stopReason: $0.stopReason)
        })
        return facts
    }
}
