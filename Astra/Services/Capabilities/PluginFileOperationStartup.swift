import Foundation
import SwiftData

/// Must run before plugin migrations, built-in sync or runtime admission.
/// Only file restoration failures block launch; an offline workspace mirror
/// stays retryable while the already-committed definition remains usable.
@MainActor
enum PluginFileOperationStartup {
    static func blocker(
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        approvals: CapabilityApprovalStore = CapabilityApprovalStore()
    ) -> PersistentStoreRecoveryBlocker? {
        let recovery = PluginFileOperationRecovery(journal: PluginFileOperationJournal(library: library, approvals: approvals))
        let result = recovery.resumePending(modelContext: modelContext, completesMirrors: false)
        guard result.deferred > 0 else { return nil }
        return PersistentStoreRecoveryBlocker(
            title: "A plugin change needs recovery",
            message: "ASTRA couldn't safely restore an interrupted plugin change. Its recovery files were kept. Restore access to this app channel's plugin folders and relaunch.",
            technicalDetail: "plugin_file_operations_pending=\(result.deferred)", actions: [.revealStore, .quit])
    }
}
