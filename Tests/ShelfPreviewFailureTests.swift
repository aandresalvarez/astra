import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Files preview failure reasons")
struct ShelfPreviewFailureTests {
    @Test("Large, missing, unsupported, and empty files have distinct preview outcomes")
    func previewOutcomes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-preview-reasons-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 2_000_001).write(to: large)
        let largeDoc = ShelfMarkdownSession.makeDocument(for: large)
        #expect(largeDoc.previewFailure == .tooLarge)
        #expect(largeDoc.errorMessage?.contains("2 MB") == true)
        #expect(largeDoc.errorMessage?.contains("Open External") == true)
        #expect(ShelfMarkdownSession.makeDocument(for: root.appendingPathComponent("missing.txt")).previewFailure == .missing)
        let binary = root.appendingPathComponent("binary.dat")
        try Data([0xff, 0xfe]).write(to: binary)
        #expect(ShelfMarkdownSession.makeDocument(for: binary).previewFailure == .unsupported)
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        #expect(ShelfMarkdownSession.makeDocument(for: empty).previewFailure == nil)
    }

    @Test("Denied reads retain the OS permission reason instead of being mislabeled missing")
    func deniedReadIsNotMissing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astra-denied-\(UUID()).txt")
        try "test".write(to: url, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        do {
            _ = try HostFileAccessBroker().readData(at: url, intent: .explicitUserSelection)
            Issue.record("A file without read permission must not load")
        } catch { #expect(ShelfPreviewFailure.classify(error) == .permissionDenied) }
    }

    @Test("Corrupt image data is a decode failure")
    func invalidImageIsNotReady() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astra-corrupt-\(UUID()).png")
        try Data([0xff, 0x20]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ShelfMarkdownSession.makeDocument(for: url).previewFailure == .decodeFailed)
    }
}
