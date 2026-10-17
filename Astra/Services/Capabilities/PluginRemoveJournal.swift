import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The intent of a Remove in progress, so an exit between saving the
/// activations' deletion and removing the library entry is finished at the
/// next launch rather than read as "installed, never turned on".
///
/// Written before the save, cleared once the library entry is gone. At
/// launch an intent whose plugin no activation names any more finishes the
/// Remove, a plugin that never had one included; one whose activations are
/// still stored (the save never landed, or the plugin was added again) is
/// dropped. An unreadable store or a library entry that can't be removed
/// leaves the intent for the next launch.
@MainActor
struct PluginRemoveJournal {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    init?(for modelContext: ModelContext) {
        guard let outbox = PluginSecretCleanupOutbox(for: modelContext) else { return nil }
        self.init(fileURL: outbox.fileURL.deletingLastPathComponent().appendingPathComponent("PluginRemoveIntents.json"))
    }

    func pending() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func begin(_ pluginID: String) throws {
        try write(Array(Set(pending() + [pluginID])))
    }

    func finish(_ pluginID: String) {
        try? write(pending().filter { $0 != pluginID })
    }

    /// Finishes interrupted Removes against `library`.
    static func resumePending(modelContext: ModelContext, library: CapabilityLibrary = CapabilityLibrary(), journal: PluginRemoveJournal? = nil) {
        guard let journal = journal ?? PluginRemoveJournal(for: modelContext) else { return }
        let pending = journal.pending()
        guard !pending.isEmpty else { return }
        guard let activations = try? modelContext.fetch(FetchDescriptor<PluginActivation>()) else {
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "plugin_remove_resume", "result": "store_unreadable_kept"
            ], level: .error)
            return
        }
        for pluginID in pending {
            guard !activations.contains(where: { $0.pluginID == pluginID && !$0.isDeleted }) else {
                journal.finish(pluginID)
                continue
            }
            if !library.installedPackages().contains(where: { $0.id == pluginID }) {
                journal.finish(pluginID)
                continue
            }
            do {
                _ = try library.removePackage(id: pluginID)
                journal.finish(pluginID)
                CapabilityCatalogPersistenceEvents.post(.global)
            } catch {
                AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                    "source": "plugin_remove_resume", "package_id": pluginID,
                    "result": "library_removal_failed_kept", "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
    }

    private func write(_ ids: [String]) throws {
        if ids.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: fileURL, options: [.atomic])
    }
}
