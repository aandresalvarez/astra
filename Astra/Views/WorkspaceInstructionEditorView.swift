import AppKit
import SwiftUI

/// A plain-text editor for workspace instructions with live Markdown syntax
/// highlighting — headings, list/quote markers, emphasis, code spans, links,
/// and dividers get distinct styling as you type, same technique as
/// `SQLQueryEditorView`. This is deliberately NOT a rich-text/WYSIWYG editor:
/// the underlying value stays a plain `String` of raw Markdown; only the
/// on-screen styling changes.
struct WorkspaceInstructionEditorView: NSViewRepresentable {
    @Binding var text: String
    var controller: WorkspaceInstructionEditorController?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isSelectable = true
        textView.isEditable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.font = MarkdownSourceHighlighting.baseFont
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.typingAttributes = MarkdownSourceHighlighting.baseAttributes

        scrollView.documentView = textView
        context.coordinator.textView = textView
        controller?.textView = textView
        updateNSView(scrollView, context: context)
        // `.focused()` doesn't bridge to a custom NSViewRepresentable's inner
        // NSTextView, so this stands in for the "cursor is ready to type"
        // auto-focus the old SwiftUI TextEditor got via @FocusState. Deferred
        // one runloop tick: the view isn't in a window yet at this point.
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        context.coordinator.text = $text
        context.coordinator.isApplyingExternalChange = true
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            context.coordinator.clearUndoActions()
            textView.string = text
            context.coordinator.clearUndoActions()
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (text as NSString).length),
                length: 0
            ))
        }
        textView.font = MarkdownSourceHighlighting.baseFont
        textView.typingAttributes = MarkdownSourceHighlighting.baseAttributes
        context.coordinator.applyHighlighting()
        context.coordinator.isApplyingExternalChange = false
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
        scrollView.documentView = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isApplyingExternalChange = false
        private var isApplyingHighlighting = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  !isApplyingHighlighting,
                  let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
            applyHighlighting()
        }

        func applyHighlighting() {
            guard let textView,
                  let storage = textView.textStorage,
                  !isApplyingHighlighting else {
                return
            }

            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            let selectedRanges = textView.selectedRanges
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(MarkdownSourceHighlighting.baseAttributes, range: fullRange)

            for token in MarkdownSourceSyntaxTokenizer.tokens(in: textView.string) {
                guard token.range.location >= 0,
                      NSMaxRange(token.range) <= storage.length,
                      token.range.length > 0 else {
                    continue
                }
                storage.addAttributes(MarkdownSourceHighlighting.attributes(for: token.kind), range: token.range)
            }

            storage.endEditing()
            textView.typingAttributes = MarkdownSourceHighlighting.baseAttributes
            textView.selectedRanges = adjustedRanges(selectedRanges, maxLength: storage.length)
        }

        func clearUndoActions() {
            guard let textView else { return }
            textView.undoManager?.removeAllActions(withTarget: textView)
        }

        func detach() {
            guard let textView else { return }
            clearUndoActions()
            textView.delegate = nil
            textView.allowsUndo = false
            self.textView = nil
        }

        private func adjustedRanges(_ ranges: [NSValue], maxLength: Int) -> [NSValue] {
            ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, maxLength)
                let length = min(range.length, max(maxLength - location, 0))
                return NSValue(range: NSRange(location: location, length: length))
            }
        }
    }
}

private enum MarkdownSourceHighlighting {
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func attributes(for kind: MarkdownSourceSyntaxTokenizer.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .headingMarker, .blockquoteMarker, .codeFenceMarker, .emphasisMarker, .linkBracket:
            return [.foregroundColor: NSColor.tertiaryLabelColor]

        case .heading(let level):
            return [
                .font: NSFont.monospacedSystemFont(ofSize: headingSize(for: level), weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]

        case .listMarker:
            return [.font: codeFont, .foregroundColor: NSColor.controlAccentColor]

        case .divider:
            return [.foregroundColor: NSColor.separatorColor]

        case .codeBlockLine:
            return [
                .font: codeFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05)
            ]

        case .codeSpanMarker:
            return [.foregroundColor: NSColor.tertiaryLabelColor]

        case .codeSpan:
            return [.font: codeFont, .foregroundColor: NSColor.systemPurple]

        case .bold:
            return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)]

        case .italic:
            return [.font: obliqueFont]

        case .strikethrough:
            return [
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ]

        case .linkLabel:
            return [.foregroundColor: NSColor.linkColor]

        case .linkURL:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    private static func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 15
        case 3: return 14
        default: return 13
        }
    }

    private static var obliqueFont: NSFont {
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }
}
