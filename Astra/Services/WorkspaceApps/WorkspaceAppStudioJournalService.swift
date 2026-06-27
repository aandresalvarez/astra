import Foundation

/// On-disk store for the App Studio conversation journal (`studio/journal.json` in the app
/// directory). Mirrors `WorkspaceAppVersionService`: `FileManager`-injected, pure JSON,
/// authoritative for its own file.
///
/// Reads never throw — a missing or corrupt journal is treated as empty, so a build conversation
/// simply starts fresh rather than failing to open. Writes are best-effort and logged, never
/// blocking a turn: the manifest + its version history remain the durable source of truth, so a
/// dropped journal write costs only the conversation log, not the app.
struct WorkspaceAppStudioJournalService: WorkspaceAppStudioJournalStoring {
    var fileManager: FileManager = .default

    func load(appID: String, workspacePath: String) -> WorkspaceAppStudioJournal {
        let path = WorkspaceFileLayout.appStudioJournalFile(workspacePath: workspacePath, appID: appID)
        guard !path.isEmpty,
              fileManager.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let journal = try? Self.decoder.decode(WorkspaceAppStudioJournal.self, from: data)
        else {
            return WorkspaceAppStudioJournal()
        }
        return journal
    }

    func save(_ journal: WorkspaceAppStudioJournal, appID: String, workspacePath: String) {
        let directory = WorkspaceFileLayout.appStudioDirectory(workspacePath: workspacePath, appID: appID)
        let path = WorkspaceFileLayout.appStudioJournalFile(workspacePath: workspacePath, appID: appID)
        guard !directory.isEmpty, !path.isEmpty else { return }
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(journal)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            AppLogger.error("App Studio journal save failed for \(appID): \(error)", category: "WorkspaceApps")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
