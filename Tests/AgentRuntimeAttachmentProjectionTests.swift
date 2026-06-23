import Foundation
import Testing
@testable import ASTRA

@MainActor
struct AgentRuntimeAttachmentProjectionTests {
    @Test("Attachment projection only grants explicit existing attachment paths")
    func grantsOnlyExplicitExistingAttachmentPaths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-attachments-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let attachedFile = root.appendingPathComponent("DBT Unit Tests (1).md")
        let attachedFolder = root.appendingPathComponent("fixture inputs", isDirectory: true)
        let missingFile = root.appendingPathComponent("missing.md")
        try "dbt unit-test notes".write(to: attachedFile, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: attachedFolder, withIntermediateDirectories: true)

        let task = AgentTask(title: "Attachment", goal: "Use the attached file")
        task.inputs = [
            attachedFolder.path,
            "context: not a path",
            missingFile.path
        ]
        let contextText = """
        This prose mentions \(root.path), but it is not an attachment block.

        Attached files:
        - "\(attachedFile.path)"
        - \(missingFile.path)

        The provider should only receive explicit existing paths.
        """

        let paths = AgentRuntimeAttachmentProjection.readablePaths(
            for: task,
            contextText: contextText
        )

        #expect(paths == [
            attachedFolder.standardizedFileURL.path,
            attachedFile.standardizedFileURL.path
        ])
    }

    @Test("Attachment projection ignores ordinary prose paths")
    func ignoresOrdinaryProsePaths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-attachment-ignore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let mentionedFile = root.appendingPathComponent("not-attached.md")
        try "not an attachment".write(to: mentionedFile, atomically: true, encoding: .utf8)

        let task = AgentTask(title: "Attachment", goal: "Use current context only")
        let paths = AgentRuntimeAttachmentProjection.readablePaths(
            for: task,
            contextText: "Please do not read \(mentionedFile.path); it is only mentioned in prose."
        )

        #expect(paths.isEmpty)
    }

    @Test("Attachment block parsing stops at non-list text")
    func attachmentBlockParsingStopsAtNonListText() {
        let paths = AgentRuntimeAttachmentProjection.attachmentBlockPaths(in: """
        Attached files/folders (dragged by user):
        - /tmp/one.md
        This is no longer part of the attachment list.
        - /tmp/two.md
        """)

        #expect(paths == ["/tmp/one.md"])
    }
}
