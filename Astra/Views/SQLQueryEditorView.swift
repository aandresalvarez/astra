import AppKit
import SwiftUI

struct SQLQueryEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.font = SQLQueryHighlighting.baseFont
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.typingAttributes = SQLQueryHighlighting.baseAttributes

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
            context.coordinator.clearUndoActions()
            textView.string = text
            context.coordinator.clearUndoActions()
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (text as NSString).length),
                length: 0
            ))
        }
        textView.font = SQLQueryHighlighting.baseFont
        textView.typingAttributes = SQLQueryHighlighting.baseAttributes
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
            storage.setAttributes(SQLQueryHighlighting.baseAttributes, range: fullRange)

            for token in SQLSyntaxTokenizer.tokens(in: textView.string) {
                guard token.range.location >= 0,
                      NSMaxRange(token.range) <= storage.length,
                      token.range.length > 0 else {
                    continue
                }
                storage.addAttributes(SQLQueryHighlighting.attributes(for: token), range: token.range)
            }

            storage.endEditing()
            textView.typingAttributes = SQLQueryHighlighting.baseAttributes
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

private enum SQLQueryHighlighting {
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let keywordFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func attributes(for token: SQLSyntaxToken) -> [NSAttributedString.Key: Any] {
        switch token.kind {
        case .word where SQLSyntaxTokenizer.isKeyword(token.text):
            return [
                .font: keywordFont,
                .foregroundColor: NSColor.controlAccentColor
            ]
        case .stringLiteral:
            return [.foregroundColor: NSColor.systemGreen]
        case .quotedIdentifier:
            return [.foregroundColor: NSColor.systemOrange]
        case .lineComment, .blockComment:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .number:
            return [.foregroundColor: NSColor.systemPurple]
        case .symbol:
            return [.foregroundColor: NSColor.tertiaryLabelColor]
        case .whitespace, .word:
            return [:]
        }
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.defaultTabInterval = 28
        return style
    }
}
