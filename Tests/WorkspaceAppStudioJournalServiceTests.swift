import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace App Studio Journal (on-disk conversation + event log)")
struct WorkspaceAppStudioJournalServiceTests {
    private func tempWorkspacePath() -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-studio-journal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    // A fixed, second-aligned date so ISO8601 encode→decode round-trips exactly (no sub-second drift).
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleJournal() -> WorkspaceAppStudioJournal {
        WorkspaceAppStudioJournal(
            messages: [
                StudioMessage(role: .user, text: "build a note taker"),
                StudioMessage(role: .assistant, kind: .summary, text: "Built a note taker.")
            ],
            events: [
                StudioGenerationEvent(
                    kind: .generation, intent: "build a note taker", origin: "model",
                    attemptCount: 1, accepted: true, blockerCount: 0,
                    manifestDigest: "abc123", runtimeID: "codex", model: "gpt-5.5",
                    createdAt: Self.fixedDate
                )
            ]
        )
    }

    @Test("a saved journal round-trips back through load")
    func roundTrip() {
        let path = tempWorkspacePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let service = WorkspaceAppStudioJournalService()
        let journal = sampleJournal()
        service.save(journal, appID: "notes", workspacePath: path)
        let loaded = service.load(appID: "notes", workspacePath: path)
        #expect(loaded == journal)
        #expect(loaded.messages.count == 2)
        #expect(loaded.events.first?.manifestDigest == "abc123")   // the version link survives
    }

    @Test("loading a never-saved app yields an empty journal, not an error")
    func missingIsEmpty() {
        let path = tempWorkspacePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(WorkspaceAppStudioJournalService().load(appID: "absent", workspacePath: path).isEmpty)
    }

    @Test("save creates studio/journal.json under the app directory")
    func saveCreatesFile() {
        let path = tempWorkspacePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        WorkspaceAppStudioJournalService().save(sampleJournal(), appID: "notes", workspacePath: path)
        let file = WorkspaceFileLayout.appStudioJournalFile(workspacePath: path, appID: "notes")
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("a corrupt journal file loads as empty (a fresh conversation), never throws")
    func corruptIsEmpty() {
        let path = tempWorkspacePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dir = WorkspaceFileLayout.appStudioDirectory(workspacePath: path, appID: "notes")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = WorkspaceFileLayout.appStudioJournalFile(workspacePath: path, appID: "notes")
        try? Data("not json{{{".utf8).write(to: URL(fileURLWithPath: file))
        #expect(WorkspaceAppStudioJournalService().load(appID: "notes", workspacePath: path).isEmpty)
    }

    @Test("an empty workspace path is a safe no-op (no crash, empty load)")
    func emptyPathSafe() {
        let service = WorkspaceAppStudioJournalService()
        service.save(sampleJournal(), appID: "notes", workspacePath: "")
        #expect(service.load(appID: "notes", workspacePath: "").isEmpty)
    }
}
