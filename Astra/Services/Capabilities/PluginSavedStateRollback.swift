import SwiftData

/// Completes rollback only after callers have restored their saved graph.
/// Restoring array-backed attributes can itself be tracked as an
/// edit even when those values equal the committed state. A final rollback
/// clears that tracking without a compensating save. Callers must enter the
/// mutation with a clean context and restore every domain value first;
/// this must never discard a person's unrelated pending editor work.
@MainActor
enum PluginSavedStateRollback {
    static func finish(in context: ModelContext) {
        if context.hasChanges { context.rollback() }
    }
}
