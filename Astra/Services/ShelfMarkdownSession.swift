import AppKit
import Foundation

struct ShelfMarkdownDocument: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    var title: String
    var content: String
    var errorMessage: String?
    var contentSignature: String
}

@MainActor
final class ShelfMarkdownSession: ObservableObject {
    @Published private(set) var documents: [ShelfMarkdownDocument] = []
    @Published private(set) var selectedDocumentID: String?
    @Published private(set) var boundTaskID: UUID?

    var selectedDocument: ShelfMarkdownDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var fileURL: URL? {
        selectedDocument?.fileURL
    }

    var title: String {
        selectedDocument?.title ?? "Markdown"
    }

    var content: String {
        selectedDocument?.content ?? ""
    }

    var errorMessage: String? {
        selectedDocument?.errorMessage
    }

    var contentSignature: String {
        selectedDocument?.contentSignature ?? ""
    }

    var displayPath: String {
        fileURL?.path ?? ""
    }

    var hasFile: Bool {
        selectedDocument != nil
    }

    func bindToTask(_ taskID: UUID?) {
        boundTaskID = taskID
    }

    func load(_ url: URL) {
        let document = Self.makeDocument(for: url)
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.append(document)
        }
        selectedDocumentID = document.id
    }

    func selectDocument(_ id: String) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selectedDocumentID = id
    }

    func closeDocument(_ id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedDocumentID == id
        documents.remove(at: index)

        guard wasSelected else { return }
        if documents.isEmpty {
            selectedDocumentID = nil
        } else {
            let nextIndex = min(index, documents.count - 1)
            selectedDocumentID = documents[nextIndex].id
        }
    }

    func closeSelectedDocument() {
        guard let selectedDocumentID else { return }
        closeDocument(selectedDocumentID)
    }

    func reload() {
        guard let fileURL else { return }
        load(fileURL)
    }

    func openExternal() {
        guard let fileURL else { return }
        NSWorkspace.shared.open(fileURL)
    }

    func copyContentToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private static func makeDocument(for url: URL) -> ShelfMarkdownDocument {
        let content: String
        let errorMessage: String?
        do {
            content = try String(contentsOf: url, encoding: .utf8)
            errorMessage = nil
        } catch {
            content = ""
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }

        return ShelfMarkdownDocument(
            id: url.path,
            fileURL: url,
            title: url.lastPathComponent,
            content: content,
            errorMessage: errorMessage,
            contentSignature: "\(url.path)|\(content.count)|\(Date().timeIntervalSince1970)"
        )
    }
}
