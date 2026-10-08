import Foundation
import ASTRAModels

/// What ASTRA did outside the machine on this task, from the same receipts the
/// chat shows. An Auto-sent Jira issue is created after the provider's turn
/// ends, so only its receipt knows the key and link, and a follow-up such as
/// "comment on the issue you just created" needs them in the provider's own
/// context, not only on screen.
enum ExternalActionPromptContext {
    static let maximumRecords = 12

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
        sections.append(PromptContextSection(
            kind: .recentTranscript,
            text: "Actions outside ASTRA recorded on this task (from their receipts, oldest first):\n"
                + records.map { "- \($0.contextLine)" }.joined(separator: "\n"),
            sourcePointers: []
        ))
    }
}
