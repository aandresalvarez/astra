import Foundation
import SwiftData
import ASTRAModels

extension TaskPublicationDecisionEvidenceReader {
    struct Work: Equatable, Sendable {
        var failureRowsScanned = 0
        var toolUseLookups = 0
        var cacheHits = 0
        var intentSkips = 0
    }

    struct Signature: Equatable {
        let ownerID: PersistentIdentifier
        let runID: UUID
        let historyInvalidation: Int
        let edits: Int
        let head: [TaskEventSnapshot]
        let failureCount: Int
        let newestFailure: TaskEventSnapshot?
        let precedingUseCount: Int
        let newestPrecedingUse: TaskEventSnapshot?
    }

    /// One actor-confined derived entry, never a durable decision owner. Every
    /// lookup checks relevant persisted rows/counts and the selected evidence.
    /// Ordinary messages and tool uses after the last failure do not rescan it.
    final class Cache {
        struct Entry {
            let signature: Signature
            let events: [TaskEventSnapshot]
        }
        var entry: Entry?
        var work = Work()
        private var observedOwnerID: PersistentIdentifier?
        private(set) var mutations: MutationTracker
        init(container: ModelContainer) { mutations = MutationTracker(container: container) }

        func selectOwner(_ ownerID: PersistentIdentifier, container: ModelContainer) {
            guard observedOwnerID != ownerID || mutations.containerID != ObjectIdentifier(container) else { return }
            entry = nil
            observedOwnerID = ownerID
            mutations = MutationTracker(container: container, ownerID: ownerID)
        }
    }

    /// Cache readers observe existing evidence edits/deletions; insertions and
    /// backdating are checked by the persisted signature. A view model can also
    /// observe inserted failures/receipts to request a committed-state refresh.
    /// New tool uses do not invalidate prior-failure evidence on ordinary appends.
    /// Both save boundaries advance the revision: a read during an in-flight
    /// commit must not remain cached after didSave. Failed saves never block
    /// readers, and the next willSave replaces that context's pending scope.
    /// Callbacks inspect changes on the saving thread; only locked value state
    /// crosses to the reader. Context references are weak.
    final class MutationTracker: @unchecked Sendable {
        let containerID: ObjectIdentifier
        private struct PendingSave {
            weak var context: ModelContext?
            let relevant: Bool
        }
        private let lock = NSLock()
        private var sequence = 0
        private var pending: [ObjectIdentifier: PendingSave] = [:]
        private var observers: [NSObjectProtocol] = []

        init(container: ModelContainer, ownerID: PersistentIdentifier? = nil,
             observeInsertedEvidence: Bool = false, onRelevantCommit: (@Sendable () -> Void)? = nil) {
            let containerID = ObjectIdentifier(container)
            self.containerID = containerID
            observers.append(NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] note in
                guard let context = note.object as? ModelContext,
                      ObjectIdentifier(context.container) == containerID else { return }
                let inserted = Set(context.insertedModelsArray.map { ObjectIdentifier($0 as AnyObject) })
                let relevant = (context.changedModelsArray + context.deletedModelsArray).contains { model in
                    guard let event = model as? TaskEvent else { return false }
                    if inserted.contains(ObjectIdentifier(model as AnyObject)),
                       !observeInsertedEvidence || event.type == "tool.use" { return false }
                    if let ownerID, event.task?.persistentModelID != ownerID,
                       !(event.isDeleted && event.task == nil) { return false }
                    return event.type.hasPrefix("git.publish.") || event.type == "tool.result.failed" || event.type == "tool.use"
                }
                self?.willSave(context, relevant: relevant)
            })
            observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] note in
                guard let context = note.object as? ModelContext,
                      ObjectIdentifier(context.container) == containerID else { return }
                if self?.didSave(context) == true { onRelevantCommit?() }
            })
        }

        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

        var revision: Int {
            lock.lock(); defer { lock.unlock() }
            return sequence
        }

        private func willSave(_ context: ModelContext, relevant: Bool) {
            lock.lock(); defer { lock.unlock() }
            pending = pending.filter { $0.value.context != nil }
            pending[ObjectIdentifier(context)] = PendingSave(context: context, relevant: relevant)
            if relevant { sequence &+= 1 }
        }

        private func didSave(_ context: ModelContext) -> Bool {
            lock.lock(); defer { lock.unlock() }
            // An observer installed after willSave must still invalidate a
            // read captured before that already-in-flight save commits.
            let relevant = pending.removeValue(forKey: ObjectIdentifier(context))?.relevant ?? true
            pending = pending.filter { $0.value.context != nil }
            if relevant { sequence &+= 1 }
            return relevant
        }
    }
}
