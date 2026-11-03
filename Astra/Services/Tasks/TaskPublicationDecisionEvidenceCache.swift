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
        let mutations: MutationTracker
        init(container: ModelContainer) { mutations = MutationTracker(container: container) }
    }

    /// Only existing publication/tool-evidence edits or deletions invalidate
    /// the cache. Insertions/backdating are checked by the persisted signature.
    /// Notification callbacks read changes on the saving context's own thread;
    /// only a locked integer crosses back to the history actor. No model or
    /// context is retained, and the observer is removed with its store.
    final class MutationTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence = 0
        private var observer: NSObjectProtocol?

        init(container: ModelContainer) {
            let containerID = ObjectIdentifier(container)
            observer = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] note in
                guard let context = note.object as? ModelContext,
                      ObjectIdentifier(context.container) == containerID else { return }
                let inserted = Set(context.insertedModelsArray.map { ObjectIdentifier($0 as AnyObject) })
                for model in context.changedModelsArray + context.deletedModelsArray {
                    guard !inserted.contains(ObjectIdentifier(model as AnyObject)), let event = model as? TaskEvent,
                          event.type.hasPrefix("git.publish.") || event.type == "tool.result.failed" || event.type == "tool.use" else { continue }
                    self?.invalidate()
                    return
                }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        var revision: Int {
            lock.lock(); defer { lock.unlock() }
            return sequence
        }

        private func invalidate() {
            lock.lock(); defer { lock.unlock() }
            sequence &+= 1
        }
    }
}
