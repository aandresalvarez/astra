import Foundation
import ASTRAModels

/// What ASTRA did outside the machine on this task, from the same receipts the
/// chat shows. A Jira issue sent from the review dock is created after the
/// provider's turn ends, so only its receipt knows the key and link, and a
/// follow-up such as "comment on the issue you just created" needs them in the
/// provider's own context, not only on screen.
///
/// A receipt's text partly comes from the destination's response (an issue
/// key, a link), so each line is one line of printable text with a length
/// cap, and the section has a byte cap too: a response cannot fill the next
/// prompt or add lines of its own.
enum ExternalActionPromptContext {
    static let maximumRecords = 12
    static let maximumLineCharacters = 240
    static let maximumSectionBytes = 3_000

    static func normalizedLine(_ text: String) -> String {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : scalar
        }))
        let collapsed = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > maximumLineCharacters ? String(collapsed.prefix(maximumLineCharacters - 1)) + "…" : collapsed
    }

    static func appendRecords(for task: AgentTask, to sections: inout [PromptContextSection]) {
        let records = task.events
            .compactMap { event in
                ExternalActionRecordProjection.record(
                    type: event.type, payload: event.payload, eventID: event.id, timestamp: event.timestamp
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(maximumRecords)
        guard !records.isEmpty else { return }
        // Newest first under the cap, then back to oldest first.
        var lines: [String] = []
        var bytes = 0
        for record in records.reversed() {
            let line = "- " + normalizedLine(record.contextLine)
            guard bytes + line.utf8.count + 1 <= maximumSectionBytes else { break }
            lines.insert(line, at: 0)
            bytes += line.utf8.count + 1
        }
        guard !lines.isEmpty else { return }
        sections.append(PromptContextSection(
            kind: .recentTranscript,
            text: "Actions outside ASTRA recorded on this task (from their receipts, oldest first):\n"
                + lines.joined(separator: "\n"),
            sourcePointers: []
        ))
    }
}
