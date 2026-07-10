import AppKit

/// Drives the workspace instructions `NSTextView` from SwiftUI toolbar
/// buttons — wraps or prefixes the current selection with Markdown syntax
/// using `NSTextView.insertText(_:replacementRange:)`, the same entry point
/// AppKit uses for typed input. That keeps undo/redo, the delegate's
/// `textDidChange`, and the existing syntax-highlighting pipeline working
/// exactly as they already do for typing — the toolbar never touches the
/// `String` binding directly, only the text view.
final class WorkspaceInstructionEditorController {
    weak var textView: NSTextView?

    // MARK: - Inline wrapping

    func toggleBold() { wrapSelection(with: "**", placeholder: "bold text") }
    func toggleItalic() { wrapSelection(with: "*", placeholder: "italic text") }
    func toggleInlineCode() { wrapSelection(with: "`", placeholder: "code") }

    private func wrapSelection(with marker: String, placeholder: String) {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        let ns = textView.string as NSString
        let hasSelection = selectedRange.length > 0
        let core = hasSelection ? ns.substring(with: selectedRange) : placeholder
        let replacement = marker + core + marker

        textView.insertText(replacement, replacementRange: selectedRange)

        if hasSelection {
            placeCursor(at: selectedRange.location + (replacement as NSString).length)
        } else {
            select(NSRange(location: selectedRange.location + (marker as NSString).length, length: (core as NSString).length))
        }
    }

    // MARK: - Heading

    /// Sets the current line's heading level, replacing any existing `#`
    /// marker rather than stacking a second one in front of it.
    func applyHeading(level: Int) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        var line = ns.substring(with: lineRange)
        let trailingNewline = line.hasSuffix("\n") ? "\n" : ""
        if !trailingNewline.isEmpty { line.removeLast() }

        if let markerRange = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            line.removeSubrange(markerRange)
        }

        let prefix = String(repeating: "#", count: max(1, min(level, 6))) + " "
        let replacement = prefix + line + trailingNewline

        textView.insertText(replacement, replacementRange: lineRange)
        placeCursor(at: lineRange.location + (replacement as NSString).length - (trailingNewline as NSString).length)
    }

    // MARK: - Line-prefixed blocks

    func toggleBulletList() { toggleLinePrefix("- ") }
    func toggleQuote() { toggleLinePrefix("> ") }

    /// Numbers every non-blank line touched by the selection, restarting
    /// from 1; toggles the numbers back off if every touched line is already
    /// numbered, so clicking twice is a no-op round trip.
    func toggleNumberedList() {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        let lines = ns.substring(with: lineRange).components(separatedBy: "\n")

        let alreadyNumbered = nonBlankLines(lines).allSatisfy { isNumbered($0) }

        var counter = 1
        let newLines = lines.map { line -> String in
            guard !isBlank(line) else { return line }
            defer { counter += 1 }
            if alreadyNumbered, let markerRange = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                return String(line[markerRange.upperBound...])
            }
            return "\(counter). \(line)"
        }

        replaceLines(lineRange, with: newLines)
    }

    private func toggleLinePrefix(_ prefix: String) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        let lines = ns.substring(with: lineRange).components(separatedBy: "\n")

        let contentLines = nonBlankLines(lines)
        let alreadyPrefixed = !contentLines.isEmpty && contentLines.allSatisfy { $0.hasPrefix(prefix) }

        let newLines = lines.map { line -> String in
            guard !isBlank(line) else { return line }
            return alreadyPrefixed ? String(line.dropFirst(prefix.count)) : prefix + line
        }

        replaceLines(lineRange, with: newLines)
    }

    private func replaceLines(_ lineRange: NSRange, with newLines: [String]) {
        guard let textView else { return }
        let replacement = newLines.joined(separator: "\n")
        textView.insertText(replacement, replacementRange: lineRange)
        select(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private func nonBlankLines(_ lines: [String]) -> [String] {
        lines.filter { !isBlank($0) }
    }

    private func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func isNumbered(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    // MARK: - Link

    /// With a selection, wraps it as the link label and selects the `url`
    /// placeholder next (the label is already known; the URL is what's
    /// missing). With no selection, selects the label placeholder instead so
    /// typing fills it in first.
    func insertLink() {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        let ns = textView.string as NSString
        let hasSelection = selectedRange.length > 0
        let label = hasSelection ? ns.substring(with: selectedRange) : "link text"
        let urlPlaceholder = "url"
        let replacement = "[\(label)](\(urlPlaceholder))"

        textView.insertText(replacement, replacementRange: selectedRange)

        if hasSelection {
            let urlLocation = selectedRange.location + 1 + (label as NSString).length + 2
            select(NSRange(location: urlLocation, length: (urlPlaceholder as NSString).length))
        } else {
            select(NSRange(location: selectedRange.location + 1, length: (label as NSString).length))
        }
    }

    // MARK: - Code block

    func insertCodeBlock() {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        let ns = textView.string as NSString
        let hasSelection = selectedRange.length > 0
        let code = hasSelection ? ns.substring(with: selectedRange) : "code"
        let replacement = "```\n\(code)\n```"

        textView.insertText(replacement, replacementRange: selectedRange)

        if hasSelection {
            placeCursor(at: selectedRange.location + (replacement as NSString).length)
        } else {
            select(NSRange(location: selectedRange.location + 4, length: (code as NSString).length))
        }
    }

    // MARK: - Selection helpers

    private func placeCursor(at location: Int) {
        select(NSRange(location: location, length: 0))
    }

    private func select(_ range: NSRange) {
        guard let textView else { return }
        textView.setSelectedRange(range)
        textView.window?.makeFirstResponder(textView)
    }
}
