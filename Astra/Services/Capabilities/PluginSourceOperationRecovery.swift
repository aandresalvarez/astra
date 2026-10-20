import Foundation
import SwiftData

/// Source-aware recovery runs under the existing global library lock. The
/// generic file protocol remains usable before sources exist, but refuses a
/// linked manifest when this metadata participant isn't available.
@MainActor
struct PluginSourceOperationRecovery {
    let library: CapabilityLibrary
    let store: PluginSourceStore
    var approvals = CapabilityApprovalStore()

    /// The caller already owns sourceStore.exclusively.
    func resumeSerialized(modelContext: ModelContext, completesMirrors: Bool = true) -> Int {
        let files = PluginFileOperationJournal(library: library, approvals: approvals)
        let sources = PluginSourceOperationJournal(store: store)
        let replay = PluginFileOperationRecovery(journal: files).resumePending(modelContext: modelContext,
            completesMirrors: completesMirrors, metadata: sources.handler(modelContext: modelContext))
        let orphans = sources.resumeOrphans(modelContext: modelContext, files: files)
        return replay.deferred + orphans.deferred
    }

    @discardableResult
    func resumePending(modelContext: ModelContext, completesMirrors: Bool = true) -> Int {
        do {
            return try store.exclusively(pluginID: "__plugin_recovery__") {
                resumeSerialized(modelContext: modelContext, completesMirrors: completesMirrors)
            }
        } catch { return 1 }
    }

    static func startupBlocker(modelContext: ModelContext) -> PersistentStoreRecoveryBlocker? {
        let pending = Self(library: CapabilityLibrary(), store: PluginSourceStore())
            .resumePending(modelContext: modelContext, completesMirrors: false)
        guard pending > 0 else { return nil }
        return PersistentStoreRecoveryBlocker(title: "A plugin change needs recovery",
            message: "ASTRA couldn't safely recover an interrupted plugin or source change. Its recovery files were kept. Restore access to the plugin folders and relaunch.",
            technicalDetail: "plugin_operations_pending=\(pending)", actions: [.revealStore, .quit])
    }
}
