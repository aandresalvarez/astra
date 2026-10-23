import Foundation
import SwiftData

/// The lock covers admission, validation and writes. Cooperating nested
/// services carry an explicit, call-scoped permit; a reentrant UI action
/// without that permit must still acquire the lock and is refused.
@MainActor
enum PluginMutationScope {
    final class Permit {
        fileprivate let libraryRoot: String
        fileprivate let sourceRoot: String
        fileprivate let pluginKey: String
        fileprivate let container: ModelContainer
        fileprivate var active = true

        fileprivate init(library: CapabilityLibrary, store: PluginSourceStore,
            pluginID: String, context: ModelContext) {
            libraryRoot = library.directory.standardizedFileURL.resolvingSymlinksInPath().path
            sourceRoot = store.root.standardizedFileURL.resolvingSymlinksInPath().path
            pluginKey = CapabilityLibrary.safeFileName(for: pluginID).lowercased()
            container = context.container
        }
    }

    static func perform<Result>(pluginID: String, library: CapabilityLibrary,
        store: PluginSourceStore, modelContext: ModelContext,
        approvals: CapabilityApprovalStore = CapabilityApprovalStore(),
        permit: Permit? = nil, _ body: (Permit) throws -> Result) throws -> Result {
        if let permit {
            guard permit.active, permit.container === modelContext.container,
                  permit.pluginKey == CapabilityLibrary.safeFileName(for: pluginID).lowercased(),
                  permit.libraryRoot == library.directory.standardizedFileURL.resolvingSymlinksInPath().path,
                  permit.sourceRoot == store.root.standardizedFileURL.resolvingSymlinksInPath().path else {
                throw PluginSourceStoreError.libraryBusy
            }
            return try body(permit)
        }
        return try store.exclusively(pluginID: pluginID) {
            let files = PluginSourceOperationRecovery(library: library, store: store, approvals: approvals)
                .resumeSerialized(modelContext: modelContext)
            guard files == 0, PluginOperationRecovery.resumePending(modelContext: modelContext).deferred == 0 else {
                throw PluginDefinitionChange.Failure.recoveryPending
            }
            let permit = Permit(library: library, store: store, pluginID: pluginID, context: modelContext)
            defer { permit.active = false }
            return try body(permit)
        }
    }
}
