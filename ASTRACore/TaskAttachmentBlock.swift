import Foundation

/// The `Attached files:` block a conversation message carries its files in.
///
/// The composer writes it; the launch reads it back for read grants and
/// Docker mounts, and forks and the attachment ledger read it for messages
/// that predate the typed `user.attachments` record. Keeping the writer and
/// the one parser together keeps every reader agreeing on the format.
public enum TaskAttachmentBlock {
    /// Headers that open a block. The second is the planner's context header
    /// for dragged files and folders. Matching ignores case.
    private static let headers: Set<String> = [
        "attached files:",
        "attached files/folders (dragged by user):"
    ]

    /// `text` followed by one block listing `paths`, or `text` alone when
    /// nothing is attached.
    public static func message(_ text: String, attaching paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let fileList = paths.map { "- \($0)" }.joined(separator: "\n")
        return text + "\n\nAttached files:\n\(fileList)"
    }

    /// Every path listed in `text`'s attachment blocks, in order.
    ///
    /// A block runs from its header through consecutive `- ` or `* ` items and
    /// ends at the first blank or non-item line, so a path merely mentioned
    /// in later prose is never picked up. Quotes and backticks around a path
    /// are stripped.
    public static func paths(in text: String) -> [String] {
        var paths: [String] = []
        var isReadingAttachmentBlock = false

        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if headers.contains(trimmedLine.lowercased()) {
                isReadingAttachmentBlock = true
                continue
            }

            guard isReadingAttachmentBlock else { continue }
            guard trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") else {
                isReadingAttachmentBlock = false
                continue
            }

            let rawPath = String(trimmedLine.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paths.append(stripPathDecorators(rawPath))
        }

        return paths
    }

    /// `value` without surrounding whitespace, backticks, or quotes.
    public static func stripPathDecorators(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for pair in [("`", "`"), ("\"", "\""), ("'", "'")] where cleaned.hasPrefix(pair.0) && cleaned.hasSuffix(pair.1) {
            cleaned.removeFirst(pair.0.count)
            cleaned.removeLast(pair.1.count)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}
