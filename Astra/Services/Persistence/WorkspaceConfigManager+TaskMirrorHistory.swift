import Foundation
import SwiftData
import ASTRAModels

extension WorkspaceConfigManager {
    /// The rows of one task's history that its mirror can contain.
    ///
    /// A mirror keeps a task's last `MirrorLimits.maxEventsPerTask` events, its
    /// recovery events, and the messages its retained turn requests point at.
    /// Reading `task.events` for that loads the whole history: on a task with
    /// 76,000 events, every save of its workspace loaded all of them into the
    /// export's context to keep under a thousand.
    ///
    /// A task with more than `boundedReadMinimumEventCount` events is read
    /// through the relationship index instead, asking the store only for those
    /// rows. A smaller task, a context with unsaved changes, and a system where
    /// SwiftData cannot run the indexed predicates (`TaskOwnerPredicate`) read
    /// the relationship as before. Either way the export writes the same
    /// mirror, and any failed bounded fetch falls back to the relationship.
    struct TaskMirrorHistory {
        /// Every event the mirror can need, in no order: the whole history, or
        /// the newest events (all at or after the oldest of the newest
        /// `maxEventsPerTask`, so a timestamp tie is complete), every recovery
        /// event, and any message added by `include(eventIDs:)`.
        private(set) var events: [TaskEvent]
        private var bounded: Bounded?

        private struct Bounded {
            let task: AgentTask
            let owner: PersistentIdentifier
            let context: ModelContext
        }

        /// Below this many events the relationship is one query, cheaper than
        /// the dozen the bounded read makes. A task-local so tests can force
        /// either read on a small fixture.
        @TaskLocal static var boundedReadMinimumEventCount = 1_000

        var isBounded: Bool { bounded != nil }

        init(task: AgentTask, modelContext: ModelContext) {
            let owner = task.persistentModelID
            if !modelContext.hasChanges,
               TaskOwnerPredicate.usesRelationshipIndex(for: owner, in: modelContext),
               let rows = try? Self.boundedRows(owner: owner, in: modelContext) {
                events = rows
                bounded = Bounded(task: task, owner: owner, context: modelContext)
            } else {
                events = task.events
                bounded = nil
            }
        }

        /// Adds the events of `ids` that `events` lacks. A retained turn
        /// request's message can be older than the newest events.
        mutating func include(eventIDs ids: Set<UUID>) {
            guard let bounded else { return }
            let missing = ids.subtracting(events.map(\.id))
            guard !missing.isEmpty else { return }
            do {
                let rows = try Self.fetch(TaskOwnerPredicate.events(ownedBy: bounded.owner, ids: Array(missing)),
                    owner: bounded.owner, in: bounded.context)
                events = Self.unique(events + rows)
            } catch {
                events = bounded.task.events
                self.bounded = nil
            }
        }

        func containsEvent(ofType type: String) -> Bool {
            guard let bounded else { return events.contains { $0.type == type } }
            var descriptor = FetchDescriptor(predicate: TaskOwnerPredicate.events(ownedBy: bounded.owner, type: type))
            descriptor.fetchLimit = 1
            guard let rows = try? bounded.context.fetch(descriptor) else {
                return bounded.task.events.contains { $0.type == type }
            }
            return rows.contains { $0.task?.persistentModelID == bounded.owner }
        }

        func events(ofTypes types: Set<String>, orTypePrefix prefix: String) -> [TaskEvent] {
            let matches = { (event: TaskEvent) in types.contains(event.type) || event.type.hasPrefix(prefix) }
            guard let bounded else { return events.filter(matches) }
            let predicate = TaskOwnerPredicate.events(ownedBy: bounded.owner, types: Array(types), orTypePrefix: prefix)
            guard let rows = try? Self.fetch(predicate, owner: bounded.owner, in: bounded.context) else {
                return bounded.task.events.filter(matches)
            }
            return rows.filter(matches)
        }

        /// Nil when the task is small enough that the relationship is cheaper.
        private static func boundedRows(owner: PersistentIdentifier, in context: ModelContext) throws -> [TaskEvent]? {
            let all = TaskOwnerPredicate.events(ownedBy: owner)
            guard try context.fetchCount(FetchDescriptor(predicate: all)) > boundedReadMinimumEventCount else { return nil }
            var newest = FetchDescriptor(predicate: all, sortBy: [SortDescriptor(\TaskEvent.timestamp, order: .reverse)])
            newest.fetchLimit = MirrorLimits.maxEventsPerTask
            var rows: [TaskEvent] = []
            if let oldestKept = try context.fetch(newest).last?.timestamp {
                rows += try fetch(TaskOwnerPredicate.events(ownedBy: owner, since: oldestKept), owner: owner, in: context)
            }
            for prefix in taskRecoveryEventTypePrefixes {
                rows += try fetch(TaskOwnerPredicate.events(ownedBy: owner, typePrefix: prefix), owner: owner, in: context)
            }
            return unique(rows)
        }

        private static func fetch(_ predicate: Predicate<TaskEvent>, owner: PersistentIdentifier,
                                  in context: ModelContext) throws -> [TaskEvent] {
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.relationshipKeyPathsForPrefetching = [\TaskEvent.run]
            return try context.fetch(descriptor).filter { $0.task?.persistentModelID == owner }
        }

        private static func unique(_ rows: [TaskEvent]) -> [TaskEvent] {
            var seen = Set<PersistentIdentifier>()
            return rows.filter { seen.insert($0.persistentModelID).inserted }
        }
    }
}
