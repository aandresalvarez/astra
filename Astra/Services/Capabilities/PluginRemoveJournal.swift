import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The intent of a Remove in progress, so an exit between saving the
/// activations' deletion and rewriting the affected workspaces' mirrors, or
/// removing the library entry, is finished at the next launch rather than
/// read as "installed, never turned on", or recovered from a mirror that
/// still names what the Remove deleted.
///
/// Written before the save, with the workspaces the Remove changes (an
/// intent from before they were recorded stands for every workspace), and
/// cleared once each of their mirrors is rewritten and the library entry is
/// gone. At launch an intent whose plugin no activation names any more
/// finishes the Remove, a plugin that never had one included; one whose
/// activations are still stored (the save never landed, or the plugin was
/// added again) is dropped. An unreadable store, a mirror that can't be
/// written, or a library entry that can't be read or removed, leaves the
/// intent for the next launch. A journal that exists but can't be read is
/// never rewritten: Remove refuses to start and launch keeps it, so the
/// intents in it are not lost.
@MainActor
struct PluginRemoveJournal {
    /// One Remove: its plugin, and the workspaces whose mirrors it changes
    /// (nil: every workspace).
    struct Intent: Codable, Equatable {
        let pluginID: String
        var workspaceIDs: [UUID]?
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    init?(for modelContext: ModelContext) {
        guard let outbox = PluginSecretCleanupOutbox(for: modelContext) else { return nil }
        self.init(fileURL: outbox.fileURL.deletingLastPathComponent().appendingPathComponent("PluginRemoveIntents.json"))
    }

    /// The plugins with an intent on disk; none when there is no journal.
    /// Throws when the journal exists but can't be read or decoded.
    func pending() throws -> [String] {
        try intents().map(\.pluginID)
    }

    /// The intents on disk, an earlier journal's bare plugin IDs included.
    func intents() throws -> [Intent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if let intents = try? JSONDecoder().decode([Intent].self, from: data) { return intents }
        return try JSONDecoder().decode([String].self, from: data).map { Intent(pluginID: $0, workspaceIDs: nil) }
    }

    /// Records the intent, with the workspaces it changes (nil: every one).
    /// Returns whether it is new: a retry of a Remove whose intent is
    /// already recorded must not clear it if the retry fails, so its
    /// workspaces are added to the recorded ones.
    @discardableResult
    func begin(_ pluginID: String, affecting workspaceIDs: [UUID]? = nil) throws -> Bool {
        var intents = try intents()
        guard let index = intents.firstIndex(where: { $0.pluginID == pluginID }) else {
            try write(intents + [Intent(pluginID: pluginID, workspaceIDs: workspaceIDs)])
            return true
        }
        let recorded = intents[index].workspaceIDs
        let merged: [UUID]? = if let recorded, let workspaceIDs {
            Set(recorded).union(workspaceIDs).sorted { $0.uuidString < $1.uuidString }
        } else {
            nil
        }
        if merged.map(Set.init) != recorded.map(Set.init) {
            intents[index].workspaceIDs = merged
            try write(intents)
        }
        return false
    }

    func finish(_ pluginID: String) {
        guard let intents = try? intents() else { return }
        try? write(intents.filter { $0.pluginID != pluginID })
    }

    /// Rewrites the mirror of each of `intent`'s workspaces still stored
    /// (`WorkspaceConfigManager.exportMirrorNow`). True when every one was.
    static func rewriteMirrors(
        of intent: Intent, modelContext: ModelContext, rewrite: ((Workspace) -> Bool)? = nil
    ) -> Bool {
        let rewrite = rewrite ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: modelContext) }
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()) else { return false }
        let affected = intent.workspaceIDs.map(Set.init)
        return workspaces.filter { affected?.contains($0.id) ?? true }.reduce(true) { written, workspace in
            rewrite(workspace) && written
        }
    }

    /// Finishes interrupted Removes against `library`.
    static func resumePending(
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        journal: PluginRemoveJournal? = nil,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) {
        guard let journal = journal ?? PluginRemoveJournal(for: modelContext) else { return }
        let pending: [Intent]
        do {
            pending = try journal.intents()
        } catch {
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "plugin_remove_resume", "result": "journal_unreadable_kept",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return
        }
        guard !pending.isEmpty else { return }
        guard let activations = try? modelContext.fetch(FetchDescriptor<PluginActivation>()) else {
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "plugin_remove_resume", "result": "store_unreadable_kept"
            ], level: .error)
            return
        }
        for intent in pending {
            let pluginID = intent.pluginID
            guard !activations.contains(where: { $0.pluginID == pluginID && !$0.isDeleted }) else {
                journal.finish(pluginID)
                continue
            }
            // The saved Remove may have exited before its mirrors were
            // rewritten: a recovery from one would bring back what it deleted.
            guard rewriteMirrors(of: intent, modelContext: modelContext, rewrite: rewriteMirror) else {
                AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                    "source": "plugin_remove_resume", "package_id": pluginID, "result": "mirror_rewrite_failed_kept"
                ], level: .error)
                continue
            }
            if !library.installedPackages().contains(where: { $0.id == pluginID }) {
                // An entry still on disk that doesn't decode is not gone: it
                // would block a reinstall under its name, so the intent stays.
                if library.occupiedStorageNames().contains(CapabilityLibrary.safeFileName(for: pluginID).lowercased()) {
                    AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                        "source": "plugin_remove_resume", "package_id": pluginID, "result": "library_entry_unreadable_kept"
                    ], level: .error)
                } else {
                    journal.finish(pluginID)
                }
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

    private func write(_ intents: [Intent]) throws {
        if intents.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(intents.sorted { $0.pluginID < $1.pluginID }).write(to: fileURL, options: [.atomic])
    }
}
