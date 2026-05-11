import AppKit
import SwiftUI

struct ShelfMarkdownPanelView: View {
    @ObservedObject var session: ShelfMarkdownSession
    @Binding var isPresented: Bool
    @Binding var isPinnedToTask: Bool
    @State private var viewMode: ShelfTextViewMode = .preview
    @State private var isEditing = false
    @State private var wrapLines = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !session.documents.isEmpty {
                tabStrip
            }
            Divider()
            documentBody
            if session.hasFile {
                Divider()
                statusBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(ObjectIdentifier(session))
        .onAppear(perform: normalizeViewMode)
        .onChange(of: session.selectedDocumentID) {
            isEditing = false
            normalizeViewMode()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: session.selectedDocumentKind?.systemImage ?? "doc.text")
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(Stanford.cardinalRed)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !session.displayPath.isEmpty {
                    Text(session.displayPath)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            modePicker

            Button {
                if isEditing {
                    isEditing = false
                } else {
                    viewMode = .source
                    isEditing = true
                }
            } label: {
                Image(systemName: isEditing ? "pencil.slash" : "pencil")
            }
            .disabled(!session.hasFile)
            .help(isEditing ? "Stop editing" : "Edit text")

            Button {
                session.saveSelectedDocument()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(!session.canSaveSelectedDocument || !session.isSelectedDocumentDirty)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save changes")

            Button {
                session.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!session.hasFile)
            .help("Reload text")

            Button {
                session.copyContentToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(!session.hasFile)
            .help("Copy text")

            Button {
                session.openExternal()
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .disabled(!session.hasFile)
            .help("Open in default app")

            overflowMenu

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close text shelf")
        }
        .buttonStyle(TextShelfToolbarButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var modePicker: some View {
        if session.selectedDocumentKind == .markdown {
            Picker("", selection: $viewMode) {
                Label("Preview", systemImage: "doc.richtext")
                    .tag(ShelfTextViewMode.preview)
                Label("Source", systemImage: "curlybraces")
                    .tag(ShelfTextViewMode.source)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 154)
            .help("Switch between rendered Markdown and source")
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.documents) { document in
                    textTab(document)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .frame(height: 40)
        .background(Stanford.cardBackground.opacity(0.55))
    }

    private func textTab(_ document: ShelfMarkdownDocument) -> some View {
        let isSelected = session.selectedDocumentID == document.id
        return HStack(spacing: 6) {
            Button {
                session.selectDocument(document.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: document.kind.systemImage)
                        .font(Stanford.ui(11, weight: .semibold))
                    Text(document.title)
                        .font(Stanford.ui(12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if document.isDirty {
                        Circle()
                            .fill(Stanford.cardinalRed)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
                .foregroundStyle(isSelected ? Stanford.black : Stanford.coolGrey)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.fileURL.path)

            Button {
                session.closeDocument(document.id)
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(isSelected ? Stanford.black.opacity(0.75) : Stanford.coolGrey.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.001))
                    )
            }
            .buttonStyle(.plain)
            .help("Close \(document.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 190, height: 34)
        .background(isSelected ? Stanford.cardBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Stanford.cardinalRed : Color.clear)
                .frame(height: 2)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Toggle(isOn: $isPinnedToTask) {
                Label(
                    "Pin to task",
                    systemImage: isPinnedToTask ? "pin.fill" : "pin"
                )
            }

            Divider()

            Toggle("Wrap lines", isOn: $wrapLines)

            Divider()

            Button {
                session.revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!session.hasFile)

            Button {
                session.closeSelectedDocument()
            } label: {
                Label("Close current file", systemImage: "xmark")
            }
            .disabled(!session.hasFile)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help("Text shelf options")
    }

    @ViewBuilder
    private var documentBody: some View {
        if let errorMessage = session.errorMessage {
            ContentUnavailableView {
                Label("Text unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") {
                    session.reload()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !session.hasFile {
            ContentUnavailableView {
                Label("No text file", systemImage: "doc.text")
            } description: {
                Text("Generated Markdown and text files from the selected task will appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if effectiveViewMode == .preview, session.selectedDocumentKind == .markdown {
            if session.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("Empty Markdown file", systemImage: "doc.richtext")
                } description: {
                    Text("Switch to Source to edit this file.")
                } actions: {
                    Button("Edit Source") {
                        viewMode = .source
                        isEditing = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SelectableMarkdownDocumentView(
                    text: session.content,
                    signature: session.contentSignature
                )
                .background(Stanford.cardBackground.opacity(0.45))
            }
        } else {
            ShelfTextEditorView(
                text: Binding(
                    get: { session.content },
                    set: { session.updateSelectedContent($0) }
                ),
                isEditable: isEditing,
                wrapLines: wrapLines
            )
            .background(Stanford.cardBackground.opacity(0.45))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let document = session.selectedDocument {
                Label(document.kind.displayName, systemImage: document.kind.systemImage)
                Text("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
                Text("\(session.content.count) characters")
                if document.isDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .foregroundStyle(Stanford.cardinalRed)
                }
                if let saveErrorMessage = session.saveErrorMessage {
                    Label(saveErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Stanford.poppy)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Label(isEditing ? "Editing" : "Read-only", systemImage: isEditing ? "pencil" : "lock")
            }
        }
        .font(Stanford.caption(11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Stanford.cardBackground.opacity(0.65))
    }

    private var effectiveViewMode: ShelfTextViewMode {
        guard session.selectedDocumentKind == .markdown else { return .source }
        return viewMode
    }

    private var lineCount: Int {
        guard !session.content.isEmpty else { return 0 }
        return session.content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func normalizeViewMode() {
        if session.selectedDocumentKind == .markdown {
            if !isEditing {
                viewMode = .preview
            }
        } else {
            viewMode = .source
        }
    }
}

private enum ShelfTextViewMode: String, Hashable {
    case preview
    case source
}

private struct TextShelfToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.55 : 0.82))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ShelfTextEditorView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let wrapLines: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        context.coordinator.text = $text
        context.coordinator.isApplyingExternalChange = true
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (text as NSString).length),
                length: 0
            ))
        }

        textView.isEditable = isEditable
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        configureWrapping(for: textView, in: scrollView)
        context.coordinator.isApplyingExternalChange = false
    }

    private func configureWrapping(for textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = !wrapLines
        textView.isHorizontallyResizable = !wrapLines
        textView.autoresizingMask = wrapLines ? [.width] : [.width, .height]
        textView.textContainer?.widthTracksTextView = wrapLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isApplyingExternalChange = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}

private struct SelectableMarkdownDocumentView: NSViewRepresentable {
    let text: String
    let signature: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.lastSignature != signature,
              let textView = context.coordinator.textView else {
            return
        }

        context.coordinator.lastSignature = signature
        textView.textStorage?.setAttributedString(MarkdownShelfTextRenderer.attributedString(for: text))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastSignature = ""
    }
}

private enum MarkdownShelfTextRenderer {
    static func attributedString(for text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownTextView.parse(text)

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 28 : level == 2 ? 22 : 18
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: size, weight: .bold),
                    color: .labelColor,
                    lineSpacing: 4,
                    paragraphSpacing: 12
                )
            case .listItem(let depth):
                let indent = String(repeating: "    ", count: depth)
                append(
                    "\(indent)\(depth == 0 ? "•" : "◦") \(block.content)\n",
                    to: result,
                    font: .systemFont(ofSize: 15),
                    color: .labelColor,
                    lineSpacing: 5,
                    paragraphSpacing: 6
                )
            case .codeBlock:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    color: .labelColor,
                    lineSpacing: 3,
                    paragraphSpacing: 10,
                    background: NSColor.textBackgroundColor.withAlphaComponent(0.22)
                )
            case .table:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    color: .labelColor,
                    lineSpacing: 4,
                    paragraphSpacing: 10
                )
            case .blockquote:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: 15).withTraits(.italicFontMask),
                    color: .secondaryLabelColor,
                    lineSpacing: 5,
                    paragraphSpacing: 10
                )
            case .notice:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: 14, weight: .medium),
                    color: .labelColor,
                    lineSpacing: 4,
                    paragraphSpacing: 10
                )
            case .label:
                append(
                    block.content + "\n",
                    to: result,
                    font: .systemFont(ofSize: 15, weight: .semibold),
                    color: .labelColor,
                    lineSpacing: 5,
                    paragraphSpacing: 6
                )
            case .divider:
                append("────────\n\n", to: result, font: .systemFont(ofSize: 13), color: .separatorColor)
            case .blank:
                result.append(NSAttributedString(string: "\n"))
            case .text:
                append(
                    block.content + "\n\n",
                    to: result,
                    font: .systemFont(ofSize: 16),
                    color: .labelColor,
                    lineSpacing: 7,
                    paragraphSpacing: 12
                )
            }
        }

        return result
    }

    private static func append(
        _ text: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat = 5,
        paragraphSpacing: CGFloat = 8,
        background: NSColor? = nil
    ) {
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(MarkdownLinkifier.markdownAttributed(text)))
        let range = NSRange(location: 0, length: attributed.length)
        guard range.length > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping

        attributed.addAttribute(.font, value: font, range: range)
        attributed.addAttribute(.foregroundColor, value: color, range: range)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        if let background {
            attributed.addAttribute(.backgroundColor, value: background, range: range)
        }
        attributed.enumerateAttribute(.link, in: range) { value, linkRange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.linkColor, range: linkRange)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: linkRange)
        }

        result.append(attributed)
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}
