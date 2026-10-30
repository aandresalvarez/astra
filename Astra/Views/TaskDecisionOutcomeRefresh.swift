import Foundation
import SwiftData
import ASTRAModels

/// Presentation invalidation only. Durable events/runs still answer every
/// decision; neither this key nor the save observer can authorize an action.
enum TaskDecisionOutcomeRefresh {
    @MainActor
    struct Projection {
        private(set) var key: Key?
        private(set) var outcomes = TaskDecisionOutcomeCache()

        @discardableResult
        mutating func refresh(key: Key, resolve: () -> TaskDecisionOutcomeCache) -> Bool {
            guard self.key != key else { return false }
            outcomes = resolve()
            self.key = key
            return true
        }
    }

    static func affectsOutcomes(_ type: String) -> Bool {
        TaskDeliverableExpectation.deliveryHistoryEventTypes.contains(type)
            || ConnectorMutationRequirementResolver.resolutionEventTypes.contains(type)
            || type.hasPrefix("git.publish.")
            || type.hasPrefix("github.review.")
            || type == TaskEventTypes.Tool.resultFailed.rawValue
    }

    struct RunKey: Equatable, Sendable {
        let id: UUID
        let startedAt: Date
        let status: RunStatus
        let stopReason: String

        init(_ run: TaskRunSnapshot) {
            id = run.id; startedAt = run.startedAt
            status = run.status; stopReason = run.stopReason
        }

        init(_ run: TaskRun) {
            id = run.id; startedAt = run.startedAt
            status = run.status; stopReason = run.stopReason
        }
    }

    /// Built with the immutable transcript snapshot, off-main in production.
    /// The view reads these arrays without scanning tool traffic per body pass.
    struct SnapshotInputs: Equatable, Sendable {
        let runs: [RunKey]
        let events: [TaskEventSnapshot]

        init(events: [TaskEventSnapshot], runs: [TaskRunSnapshot]) {
            self.init(events: events, runs: runs, cancellationCheck: {})
        }

        init(events window: [TaskEventSnapshot], runs: [TaskRunSnapshot], cancellationCheck: () throws -> Void) rethrows {
            self.runs = runs.map(RunKey.init)
            var lastUse: [UUID?: TaskEventSnapshot] = [:]
            var legacyUses = Set<UUID>()
            var start = 0
            // The window is chronological. Process ties together: a legacy
            // failure can depend on any use at its timestamp; the resolver's
            // timestamp/UUID ordering chooses the greatest UUID among them.
            while start < window.count {
                if start.isMultiple(of: 128) { try cancellationCheck() }
                var end = start
                while end < window.count, window[end].timestamp == window[start].timestamp {
                    let event = window[end]
                    if event.type == TaskEventTypes.Tool.use.rawValue {
                        if let previous = lastUse[event.runID], previous.timestamp == event.timestamp {
                            if previous.id.uuidString < event.id.uuidString { lastUse[event.runID] = event }
                        } else {
                            lastUse[event.runID] = event
                        }
                    }
                    end += 1
                    if end.isMultiple(of: 128) { try cancellationCheck() }
                }
                for event in window[start..<end] where event.type == TaskEventTypes.Tool.resultFailed.rawValue {
                    if let use = lastUse[event.runID] { legacyUses.insert(use.id) }
                }
                start = end
            }
            try cancellationCheck()
            events = window.filter { affectsOutcomes($0.type) || legacyUses.contains($0.id) }
        }
    }

    struct Key: Equatable {
        let scope: TaskAttachmentHistoryScope
        let status: TaskStatus
        let intent: [[String]]
        let locations: [String]
        let runs: [RunKey]
        let events: [TaskEventSnapshot]
        let artifactPaths: [String]
        let saveRevision: Int
        let historyInvalidation: Int

        @MainActor
        init(task: AgentTask, snapshot: TaskThreadSnapshot?, artifactPaths: [String], saveRevision: Int) {
            scope = .init(task: task)
            status = task.status
            intent = [[task.title, task.goal], task.inputs, task.acceptanceCriteria, task.constraints]
            locations = [task.workspace?.primaryPath ?? "", task.executionRootPath ?? ""]
            runs = snapshot?.decisionOutcomeInputs.runs ?? []
            events = snapshot?.decisionOutcomeInputs.events ?? []
            self.artifactPaths = artifactPaths
            self.saveRevision = saveRevision
            historyInvalidation = TaskThreadHistoryInvalidation.token(for: task.id)
        }
    }

    /// Reads only the context's pending changes at its explicit save boundary,
    /// so direct insertions, edits, deletions and backdated history outside the
    /// transcript window invalidate too. Never traverses task relationships.
    @MainActor
    struct SaveTracker {
        private var runKeys: [PersistentIdentifier: RunKey] = [:]

        mutating func record(context: ModelContext, task: AgentTask) -> Bool {
            let owner = task.persistentModelID
            var relevant = false
            for model in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
                if let event = model as? TaskEvent, affectsOutcomes(event.type),
                   event.task?.persistentModelID == owner || (event.isDeleted && event.task == nil) {
                    relevant = true
                }
                if let run = model as? TaskRun,
                   run.task?.persistentModelID == owner || (run.isDeleted && run.task == nil) {
                    let key = RunKey(run)
                    if runKeys.updateValue(key, forKey: run.persistentModelID) != key || run.isDeleted {
                        relevant = true
                    }
                }
            }
            if runKeys.count > 256 {
                let recent = runKeys.sorted { $0.value.startedAt > $1.value.startedAt }.prefix(128)
                runKeys = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
            }
            return relevant
        }
    }
}
