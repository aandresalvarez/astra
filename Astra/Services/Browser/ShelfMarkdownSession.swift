import AppKit
import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

enum ShelfTextDocumentKind: String, Equatable {
    case markdown
    case json
    case image
    case text
    case unsupported

    var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        case .image: "Image"
        case .text: "Text"
        case .unsupported: "File"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "doc.richtext"
        case .json: "curlybraces"
        case .image: "photo"
        case .text: "doc.plaintext"
        case .unsupported: "doc"
        }
    }

    var isTextBacked: Bool {
        switch self {
        case .markdown, .json, .text:
            true
        case .image, .unsupported:
            false
        }
    }

    static func infer(from url: URL) -> ShelfTextDocumentKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "qmd":
            .markdown
        case "json", "geojson", "ipynb":
            .json
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp":
            .image
        default:
            .text
        }
    }
}

struct ShelfImagePreview: Equatable {
    let image: NSImage
    let pixelSize: CGSize?
    let signature: String

    static func == (lhs: ShelfImagePreview, rhs: ShelfImagePreview) -> Bool {
        lhs.signature == rhs.signature && lhs.pixelSize == rhs.pixelSize
    }
}

struct ShelfMarkdownDocument: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    var title: String
    var kind: ShelfTextDocumentKind
    var content: String
    var savedContent: String
    var fileByteSize: Int64
    var modifiedAt: Date?
    var isLargePreview: Bool
    var imagePreview: ShelfImagePreview?
    var imageSize: CGSize?
    var formattedJSONContent: String?
    var jsonErrorMessage: String?
    var errorMessage: String?
    var saveErrorMessage: String?
    var contentSignature: String

    var isDirty: Bool {
        content != savedContent
    }
}

protocol ShelfDocumentLoading: Sendable {
    func loadDocument(at url: URL) async -> ShelfMarkdownDocument
}

struct DefaultShelfDocumentLoader: ShelfDocumentLoading {
    func loadDocument(at url: URL) async -> ShelfMarkdownDocument {
        let loadTask = Task.detached(priority: .userInitiated) {
            ShelfMarkdownSession.makeDocument(for: url)
        }
        return await withTaskCancellationHandler {
            await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
    }
}

private struct ShelfFileMetadata {
    let fileByteSize: Int64
    let modifiedAt: Date?
}

private enum ShelfMarkdownTaskBinding: Hashable {
    case task(UUID)
    case unscoped

    init(taskID: UUID?) {
        self = taskID.map(Self.task) ?? .unscoped
    }
}

/// What a task binding wants the shelf to show when it becomes active again.
/// Absence from the intent map means the binding never engaged with the
/// shelf, so automatic content is welcome to fill the vacuum.
private enum ShelfMarkdownSelectionIntent: Equatable {
    /// The user was last looking at this document under the binding.
    case document(String)
    /// The user explicitly emptied the shelf under the binding; nothing loads
    /// automatically for it until the user opens or selects a document.
    case cleared
}

@MainActor
final class ShelfMarkdownSession: ObservableObject {
    nonisolated static let largeTextPreviewBytes: Int64 = 300_000
    nonisolated private static let maxTextDocumentBytes: Int64 = 2_000_000

    @Published private(set) var documents: [ShelfMarkdownDocument] = []
    @Published private(set) var selectedDocumentID: String?
    @Published private(set) var boundTaskID: UUID?
    @Published private(set) var loadingDocumentID: String?
    /// Paths the user explicitly closed. A dismissed document never comes back
    /// through `loadAutomaticallyIfAllowed` — under any task binding — until a
    /// manual `load(_:)` re-legitimizes it: closing a tab is a statement about
    /// the document, not about whichever task happened to be bound.
    private var dismissedDocumentPaths: Set<String> = []
    private var selectionIntentsByTask: [ShelfMarkdownTaskBinding: ShelfMarkdownSelectionIntent] = [:]
    private let documentLoader: any ShelfDocumentLoading
    private var documentLoadGeneration = 0

    init(documentLoader: any ShelfDocumentLoading = DefaultShelfDocumentLoader()) {
        self.documentLoader = documentLoader
    }

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
        selectedDocument?.kind.isTextBacked == true && selectedDocument?.errorMessage == nil
    }

    var displayPath: String {
        fileURL?.path ?? ""
    }

    var hasFile: Bool {
        selectedDocument != nil
    }

    var isLoadingDocument: Bool {
        loadingDocumentID != nil
    }

    func bindToTask(_ taskID: UUID?) {
        guard boundTaskID != taskID else { return }
        cancelPendingDocumentLoad()
        boundTaskID = taskID
        if case .document(let restoredID)? = selectionIntentsByTask[ShelfMarkdownTaskBinding(taskID: taskID)],
           documents.contains(where: { $0.id == restoredID }) {
            selectedDocumentID = restoredID
        } else {
            selectedDocumentID = nil
        }
    }

    func load(_ url: URL) {
        cancelPendingDocumentLoad()
        dismissedDocumentPaths.remove(url.path)
        let documentID = url.path
        if let index = documents.firstIndex(where: { $0.id == documentID }),
           Self.reuseUnchangedImageDocument(documents[index], for: url) {
            if selectedDocumentID != documentID {
                selectDocumentID(documentID)
            }
            return
        }

        let document = Self.makeDocument(for: url)
        applyLoadedDocument(document)
    }

    @discardableResult
    func loadAsync(_ url: URL) async -> Bool {
        dismissedDocumentPaths.remove(url.path)
        documentLoadGeneration &+= 1
        let generation = documentLoadGeneration
        loadingDocumentID = url.path
        defer {
            if generation == documentLoadGeneration {
                loadingDocumentID = nil
            }
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let document = await documentLoader.loadDocument(at: url)
        guard !Task.isCancelled, generation == documentLoadGeneration else { return false }

        applyLoadedDocument(document)
        FilesShelfResponsivenessTelemetry.logPreviewLoad(
            durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: startedAt),
            kind: document.kind,
            byteCount: document.fileByteSize,
            outcome: document.errorMessage == nil ? "ready" : "error",
            taskID: boundTaskID
        )
        if document.errorMessage != nil {
            PerformanceTelemetry.log(
                "files_shelf_preview_error",
                level: .warning,
                fields: [
                    "kind": document.kind.rawValue,
                    "byte_bucket": PerformanceTelemetryFields.byteBucket(Int(clamping: document.fileByteSize))
                ],
                taskID: boundTaskID
            )
        }
        return true
    }

    private func applyLoadedDocument(_ document: ShelfMarkdownDocument) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            if documents[index] != document {
                documents[index] = document
            }
        } else {
            documents.append(document)
        }
        if selectedDocumentID != document.id {
            selectDocumentID(document.id)
        }
    }

    @discardableResult
    func loadAutomaticallyIfAllowed(_ url: URL) -> Bool {
        guard !dismissedDocumentPaths.contains(url.path) else { return false }
        let intent = selectionIntentsByTask[ShelfMarkdownTaskBinding(taskID: boundTaskID)]
        guard intent != .cleared, fileURL?.path != url.path else { return false }
        if case .document(let chosenID)? = intent,
           documents.contains(where: { $0.id == chosenID }),
           documents.contains(where: { $0.id == url.path }) {
            // Both the user's chosen document and the candidate are open tabs:
            // re-selecting the candidate would override an explicit choice.
            // A candidate that is not open yet is new content and may load.
            return false
        }
        load(url)
        return true
    }

    @discardableResult
    func loadAutomaticallyIfAllowedAsync(_ url: URL) async -> Bool {
        guard !dismissedDocumentPaths.contains(url.path) else { return false }
        let intent = selectionIntentsByTask[ShelfMarkdownTaskBinding(taskID: boundTaskID)]
        guard intent != .cleared, fileURL?.path != url.path else { return false }
        if case .document(let chosenID)? = intent,
           documents.contains(where: { $0.id == chosenID }),
           documents.contains(where: { $0.id == url.path }) {
            return false
        }
        return await loadAsync(url)
    }

    func selectDocument(_ id: String) {
        guard documents.contains(where: { $0.id == id }) else { return }
        cancelPendingDocumentLoad()
        selectDocumentID(id)
    }

    func closeDocument(_ id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        dismissedDocumentPaths.insert(id)
        let wasSelected = selectedDocumentID == id
        documents.remove(at: index)

        guard wasSelected else { return }
        if documents.isEmpty {
            selectDocumentID(nil)
        } else {
            let nextIndex = min(index, documents.count - 1)
            selectDocumentID(documents[nextIndex].id)
        }
    }

    /// Single write point for selection: keeps the visible selection and the
    /// bound task's intent in step. `nil` records an explicit clear, not a
    /// missing value — only `closeDocument` passes it, when the user closes
    /// the last open tab.
    private func selectDocumentID(_ id: String?) {
        selectedDocumentID = id
        let binding = ShelfMarkdownTaskBinding(taskID: boundTaskID)
        selectionIntentsByTask[binding] = id.map(ShelfMarkdownSelectionIntent.document) ?? .cleared
    }

    func closeSelectedDocument() {
        guard let selectedDocumentID else { return }
        closeDocument(selectedDocumentID)
    }

    func cancelPendingDocumentLoad() {
        documentLoadGeneration &+= 1
        if loadingDocumentID != nil {
            loadingDocumentID = nil
        }
    }

    func reload() {
        guard let fileURL else { return }
        load(fileURL)
    }

    func updateSelectedContent(_ content: String) {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }),
              documents[index].kind.isTextBacked,
              documents[index].content != content else {
            return
        }

        documents[index].content = content
        let jsonPreview = Self.makeJSONPreview(content: content, kind: documents[index].kind)
        documents[index].formattedJSONContent = jsonPreview.content
        documents[index].jsonErrorMessage = jsonPreview.errorMessage
        documents[index].errorMessage = nil
        documents[index].saveErrorMessage = nil
        documents[index].contentSignature = Self.contentSignature(
            for: documents[index].fileURL,
            fileByteSize: Int64(content.utf8.count),
            modifiedAt: documents[index].modifiedAt,
            content: content
        )
    }

    func saveSelectedDocument() {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }),
              documents[index].kind.isTextBacked else {
            return
        }

        do {
            try documents[index].content.write(
                to: documents[index].fileURL,
                atomically: true,
                encoding: .utf8
            )
            documents[index].savedContent = documents[index].content
            let metadata = try? Self.fileMetadata(for: documents[index].fileURL)
            let fileByteSize = metadata?.fileByteSize ?? Int64(documents[index].content.utf8.count)
            documents[index].fileByteSize = fileByteSize
            documents[index].modifiedAt = metadata?.modifiedAt
            documents[index].isLargePreview = fileByteSize >= Self.largeTextPreviewBytes
            documents[index].errorMessage = nil
            documents[index].saveErrorMessage = nil
            documents[index].contentSignature = Self.contentSignature(
                for: documents[index].fileURL,
                fileByteSize: fileByteSize,
                modifiedAt: documents[index].modifiedAt,
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
        if selectedDocument?.kind.isTextBacked == true {
            NSPasteboard.general.setString(content, forType: .string)
        } else if let fileURL {
            NSPasteboard.general.setString(fileURL.path, forType: .string)
        }
    }

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private static func reuseUnchangedImageDocument(_ document: ShelfMarkdownDocument, for url: URL) -> Bool {
        guard document.kind == .image,
              ShelfTextDocumentKind.infer(from: url) == .image,
              let preview = document.imagePreview,
              let metadata = try? fileMetadata(for: url) else {
            return false
        }

        return preview.signature == contentSignature(for: url, metadata: metadata, content: "")
    }

    nonisolated static func makeDocument(for url: URL) -> ShelfMarkdownDocument {
        let kind = ShelfTextDocumentKind.infer(from: url)
        let content: String
        let errorMessage: String?
        var fileByteSize: Int64 = 0
        var modifiedAt: Date?
        do {
            let metadata = try Self.fileMetadata(for: url)
            fileByteSize = metadata.fileByteSize
            modifiedAt = metadata.modifiedAt

            if kind == .image {
                let preview = Self.imagePreview(for: url, metadata: metadata)
                return ShelfMarkdownDocument(
                    id: url.path,
                    fileURL: url,
                    title: url.lastPathComponent,
                    kind: kind,
                    content: "",
                    savedContent: "",
                    fileByteSize: metadata.fileByteSize,
                    modifiedAt: metadata.modifiedAt,
                    isLargePreview: false,
                    imagePreview: preview,
                    imageSize: preview?.pixelSize,
                    formattedJSONContent: nil,
                    jsonErrorMessage: nil,
                    errorMessage: nil,
                    saveErrorMessage: nil,
                    contentSignature: preview?.signature ?? Self.contentSignature(
                        for: url,
                        metadata: metadata,
                        content: ""
                    )
                )
            }

            guard metadata.fileByteSize <= maxTextDocumentBytes else {
                return ShelfMarkdownDocument(
                    id: url.path,
                    fileURL: url,
                    title: url.lastPathComponent,
                    kind: kind,
                    content: "",
                    savedContent: "",
                    fileByteSize: metadata.fileByteSize,
                    modifiedAt: metadata.modifiedAt,
                    isLargePreview: false,
                    imagePreview: nil,
                    imageSize: nil,
                    formattedJSONContent: nil,
                    jsonErrorMessage: nil,
                    errorMessage: "\(url.lastPathComponent) is too large to preview in the Files shelf.",
                    saveErrorMessage: nil,
                    contentSignature: Self.contentSignature(
                        for: url,
                        metadata: metadata,
                        content: ""
                    )
                )
            }

            let data = try HostFileAccessBroker().readData(
                at: url,
                intent: .explicitUserSelection
            )
            guard let decoded = String(data: data, encoding: .utf8) else {
                return ShelfMarkdownDocument(
                    id: url.path,
                    fileURL: url,
                    title: url.lastPathComponent,
                    kind: .unsupported,
                    content: "",
                    savedContent: "",
                    fileByteSize: metadata.fileByteSize,
                    modifiedAt: metadata.modifiedAt,
                    isLargePreview: false,
                    imagePreview: nil,
                    imageSize: nil,
                    formattedJSONContent: nil,
                    jsonErrorMessage: nil,
                    errorMessage: nil,
                    saveErrorMessage: nil,
                    contentSignature: Self.contentSignature(
                        for: url,
                        metadata: metadata,
                        content: ""
                    )
                )
            }
            content = decoded
            errorMessage = nil
        } catch {
            fileByteSize = 0
            modifiedAt = nil
            content = ""
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }

        let jsonPreview = Self.makeJSONPreview(content: content, kind: kind)
        return ShelfMarkdownDocument(
            id: url.path,
            fileURL: url,
            title: url.lastPathComponent,
            kind: kind,
            content: content,
            savedContent: content,
            fileByteSize: fileByteSize,
            modifiedAt: modifiedAt,
            isLargePreview: fileByteSize >= Self.largeTextPreviewBytes,
            imagePreview: nil,
            imageSize: nil,
            formattedJSONContent: jsonPreview.content,
            jsonErrorMessage: jsonPreview.errorMessage,
            errorMessage: errorMessage,
            saveErrorMessage: nil,
            contentSignature: Self.contentSignature(
                for: url,
                fileByteSize: fileByteSize,
                modifiedAt: modifiedAt,
                content: content
            )
        )
    }

    nonisolated private static func makeJSONPreview(
        content: String,
        kind: ShelfTextDocumentKind
    ) -> (content: String?, errorMessage: String?) {
        guard kind == .json, let data = content.data(using: .utf8) else {
            return (nil, nil)
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard JSONSerialization.isValidJSONObject(object) else {
                return (content, nil)
            }
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            return (String(data: formatted, encoding: .utf8) ?? content, nil)
        } catch {
            return (nil, "Invalid JSON: \(error.localizedDescription)")
        }
    }

    nonisolated private static func imagePreview(
        for url: URL,
        metadata: ShelfFileMetadata
    ) -> ShelfImagePreview? {
        let signature = contentSignature(for: url, metadata: metadata, content: "")
        guard let image = NSImage(contentsOf: url) else { return nil }
        return ShelfImagePreview(
            image: image,
            pixelSize: imagePixelSize(for: image),
            signature: signature
        )
    }

    nonisolated private static func imagePixelSize(for image: NSImage) -> CGSize? {
        let representation = image.representations.max { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }
        guard let representation,
              representation.pixelsWide > 0,
              representation.pixelsHigh > 0 else {
            return image.size == .zero ? nil : image.size
        }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    nonisolated private static func fileMetadata(for url: URL) throws -> ShelfFileMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize: Int64
        if let size = attributes[.size] as? NSNumber {
            byteSize = size.int64Value
        } else {
            byteSize = attributes[.size] as? Int64 ?? 0
        }
        return ShelfFileMetadata(
            fileByteSize: byteSize,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    nonisolated private static func contentSignature(
        for url: URL,
        metadata: ShelfFileMetadata,
        content: String
    ) -> String {
        contentSignature(
            for: url,
            fileByteSize: metadata.fileByteSize,
            modifiedAt: metadata.modifiedAt,
            content: content
        )
    }

    nonisolated private static func contentSignature(
        for url: URL,
        fileByteSize: Int64,
        modifiedAt: Date?,
        content: String
    ) -> String {
        let modified = modifiedAt.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "missing"
        return "\(url.path)|\(fileByteSize)|\(modified)|\(contentHash(content))"
    }

    nonisolated private static func contentHash(_ content: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
