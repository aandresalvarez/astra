import Foundation
import Testing
@testable import ASTRA

private struct DelayedShelfDocumentLoader: ShelfDocumentLoading {
    let slowPath: String

    func loadDocument(at url: URL) async -> ShelfMarkdownDocument {
        if url.path == slowPath {
            try? await Task.sleep(nanoseconds: 100_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return ShelfMarkdownSession.makeDocument(for: url)
    }
}

@Suite("Shelf markdown async loading")
struct ShelfMarkdownAsyncLoadingTests {
    @MainActor
    @Test("A stale slow preview cannot replace a newer selection")
    func newestSelectionWins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slowURL = directory.appendingPathComponent("slow.md")
        let fastURL = directory.appendingPathComponent("fast.md")
        try "# Slow".write(to: slowURL, atomically: true, encoding: .utf8)
        try "# Fast".write(to: fastURL, atomically: true, encoding: .utf8)
        let session = ShelfMarkdownSession(
            documentLoader: DelayedShelfDocumentLoader(slowPath: slowURL.path)
        )

        let slowLoad = Task { await session.loadAsync(slowURL) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let fastApplied = await session.loadAsync(fastURL)
        let slowApplied = await slowLoad.value

        #expect(fastApplied)
        #expect(!slowApplied)
        #expect(session.fileURL == fastURL)
        #expect(session.content == "# Fast")
        #expect(!session.isLoadingDocument)
    }

    @MainActor
    @Test("Default async loading preserves JSON preparation behavior")
    func defaultLoaderPreservesDocumentPreparation() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-preview-\(UUID().uuidString).json")
        try "{\"answer\":42}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = ShelfMarkdownSession()

        let applied = await session.loadAsync(file)

        #expect(applied)
        #expect(session.selectedDocumentKind == .json)
        #expect(session.selectedDocument?.formattedJSONContent?.contains("\"answer\" : 42") == true)
    }
}
