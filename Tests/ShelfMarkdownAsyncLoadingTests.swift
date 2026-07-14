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

    @MainActor
    @Test("Cancelling an async preview always clears its loading state")
    func cancellationClearsLoadingState() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-cancel-\(UUID().uuidString).md")
        try "# Slow".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = ShelfMarkdownSession(documentLoader: DelayedShelfDocumentLoader(slowPath: file.path))

        let load = Task { await session.loadAsync(file) }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.cancelPendingDocumentLoad()

        #expect(await !load.value)
        #expect(!session.isLoadingDocument)
        #expect(!session.hasFile)
    }

    @MainActor
    @Test("Selecting an open tab supersedes a pending preview")
    func openTabSelectionSupersedesPendingPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-tab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let openURL = directory.appendingPathComponent("open.md")
        let slowURL = directory.appendingPathComponent("slow.md")
        try "# Open".write(to: openURL, atomically: true, encoding: .utf8)
        try "# Slow".write(to: slowURL, atomically: true, encoding: .utf8)
        let session = ShelfMarkdownSession(documentLoader: DelayedShelfDocumentLoader(slowPath: slowURL.path))
        session.load(openURL)

        let pending = Task { await session.loadAsync(slowURL) }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.selectDocument(openURL.path)

        #expect(await !pending.value)
        #expect(session.fileURL == openURL)
        #expect(!session.isLoadingDocument)
    }

    @MainActor
    @Test("Async reload never overwrites edits made while the read is pending")
    func pendingReloadPreservesDirtyEdits() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-dirty-\(UUID().uuidString).md")
        try "# Disk v1".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = ShelfMarkdownSession(documentLoader: DelayedShelfDocumentLoader(slowPath: file.path))
        session.load(file)
        try "# Disk v2".write(to: file, atomically: true, encoding: .utf8)

        let pending = Task { await session.loadAsync(file) }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.updateSelectedContent("# Local edit")

        #expect(await !pending.value)
        #expect(session.content == "# Local edit")
        #expect(session.isSelectedDocumentDirty)
        #expect(!session.isLoadingDocument)
    }

    @MainActor
    @Test("Closing a document cancels its pending reload")
    func closingDocumentCancelsPendingReload() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-close-\(UUID().uuidString).md")
        try "# Document".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = ShelfMarkdownSession(documentLoader: DelayedShelfDocumentLoader(slowPath: file.path))
        session.load(file)

        let pending = Task { await session.loadAsync(file) }
        try await Task.sleep(nanoseconds: 10_000_000)
        session.closeDocument(file.path)

        #expect(await !pending.value)
        #expect(!session.hasFile)
        #expect(!session.documents.contains(where: { $0.id == file.path }))
        #expect(!session.isLoadingDocument)
    }
}
