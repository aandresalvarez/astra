import AppKit
import Foundation

enum ShelfTextDocumentKind: String, Equatable {
    case markdown
    case text

    var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "doc.richtext"
        case .text: "doc.plaintext"
        }
    }

    static func infer(from url: URL) -> ShelfTextDocumentKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "qmd":
            .markdown
        default:
            .text
        }
    }
}

struct ShelfMarkdownDocument: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    var title: String
    var kind: ShelfTextDocumentKind
    var content: String
    var savedContent: String
    var errorMessage: String?
    var saveErrorMessage: String?
    var contentSignature: String

    var isDirty: Bool {
        content != savedContent
    }
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
        selectedDocument?.title ?? "Text"
    }

    var content: String {
        selectedDocument?.content ?? ""
    }

    var errorMessage: String? {
        selectedDocument?.errorMessage
    }

    var saveErrorMessage: String? {
        selectedDocument?.saveErrorMessage
    }

    var contentSignature: String {
        selectedDocument?.contentSignature ?? ""
    }

    var selectedDocumentKind: ShelfTextDocumentKind? {
        selectedDocument?.kind
    }

    var isSelectedDocumentDirty: Bool {
        selectedDocument?.isDirty == true
    }

    var canSaveSelectedDocument: Bool {
        selectedDocument != nil && selectedDocument?.errorMessage == nil
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

    func updateSelectedContent(_ content: String) {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }),
              documents[index].content != content else {
            return
        }

        documents[index].content = content
        documents[index].errorMessage = nil
        documents[index].saveErrorMessage = nil
        documents[index].contentSignature = Self.contentSignature(
            for: documents[index].fileURL,
            content: content
        )
    }

    func saveSelectedDocument() {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) else {
            return
        }

        do {
            try documents[index].content.write(
                to: documents[index].fileURL,
                atomically: true,
                encoding: .utf8
            )
            documents[index].savedContent = documents[index].content
            documents[index].errorMessage = nil
            documents[index].saveErrorMessage = nil
            documents[index].contentSignature = Self.contentSignature(
                for: documents[index].fileURL,
                content: documents[index].content
            )
        } catch {
            documents[index].saveErrorMessage = "Could not save \(documents[index].fileURL.lastPathComponent): \(error.localizedDescription)"
        }
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
            kind: ShelfTextDocumentKind.infer(from: url),
            content: content,
            savedContent: content,
            errorMessage: errorMessage,
            saveErrorMessage: nil,
            contentSignature: Self.contentSignature(for: url, content: content)
        )
    }

    private static func contentSignature(for url: URL, content: String) -> String {
        "\(url.path)|\(content.count)|\(Date().timeIntervalSince1970)"
    }
}
