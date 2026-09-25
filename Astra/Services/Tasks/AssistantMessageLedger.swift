import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The assistant messages of one run, keyed by provider message identity, in
/// the order the provider started them.
///
/// During recording it is the only writer of keyed `agent.response` rows and of
/// the text they contribute to `run.output`: a delta appends to its message's
/// draft, and a final copy replaces the draft when it differs. Rows never mix
/// two messages; a message longer than the row cap continues in more rows.
@MainActor
final class AssistantMessageLedger {
    struct Entry {
        let key: String
        var text: String
        var committed: Bool
        var rows: [TaskEvent]
        /// `AgentEventRecordingState.nonMessageSequence` at the entry's last
        /// write: equal to the current value means nothing was recorded since.
        var lastWriteSequence: Int
    }

    private(set) var entries: [Entry] = []
    private var indexByKey: [String: Int] = [:]

    var joinedText: String {
        entries.map(\.text).joined()
    }

    func index(of key: String) -> Int? {
        indexByKey[key]
    }

    func appendEntry(key: String, sequence: Int) -> Int {
        let index = entries.count
        entries.append(Entry(key: key, text: "", committed: false, rows: [], lastWriteSequence: sequence))
        indexByKey[key] = index
        return index
    }

    func update(_ index: Int, _ change: (inout Entry) -> Void) {
        change(&entries[index])
    }
}

@MainActor
enum AssistantMessageRecording {
    static func record(
        _ fragment: AssistantMessageFragment,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState state: AgentEventRecordingState
    ) {
        // Unkeyed text must never keep coalescing into a row written before
        // this message.
        state.breakConversationCoalescing(for: run)
        switch fragment.kind {
        case .delta:
            appendDelta(fragment, to: task, run: run, modelContext: modelContext, state: state)
        case .final:
            applyFinal(fragment, to: task, run: run, modelContext: modelContext, state: state)
        }
    }

    private static func appendDelta(
        _ fragment: AssistantMessageFragment,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        state: AgentEventRecordingState
    ) {
        guard !fragment.text.isEmpty else { return }
        let ledger = state.messageLedger(for: run)
        let sequence = state.nonMessageSequence(for: run)
        let index = ledger.index(of: fragment.key) ?? ledger.appendEntry(key: fragment.key, sequence: sequence)
        guard !ledger.entries[index].committed else { return }
        let movesForward = canMoveForward(index, in: ledger, sequence: sequence)
        ledger.update(index) { $0.text += fragment.text }
        appendToRows(fragment.text, entry: index, ledger: ledger, movesForward: movesForward,
                     task: task, run: run, modelContext: modelContext, cap: state.messageRowCap)
        ledger.update(index) { $0.lastWriteSequence = sequence }
        if index == ledger.entries.count - 1 || state.hasUnkeyedText(for: run) {
            run.appendOutput(fragment.text)
        } else {
            run.setOutput(ledger.joinedText)
        }
        state.clearOutputFromCompletedSummary(for: run)
    }

    private static func applyFinal(
        _ fragment: AssistantMessageFragment,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        state: AgentEventRecordingState
    ) {
        let ledger = state.messageLedger(for: run)
        let sequence = state.nonMessageSequence(for: run)
        guard let index = ledger.index(of: fragment.key) else {
            // A final without a streamed draft: a subagent message, or a stream
            // without partial messages. It is the message's only copy.
            guard !fragment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let index = ledger.appendEntry(key: fragment.key, sequence: sequence)
            ledger.update(index) {
                $0.text = fragment.text
                $0.committed = true
            }
            appendToRows(fragment.text, entry: index, ledger: ledger, movesForward: true,
                         task: task, run: run, modelContext: modelContext, cap: state.messageRowCap)
            run.appendOutput(fragment.text)
            state.clearOutputFromCompletedSummary(for: run)
            return
        }
        let entry = ledger.entries[index]
        guard !entry.committed else { return }
        ledger.update(index) { $0.committed = true }
        // The common case: the streamed draft already is the message.
        guard whitespaceCollapsed(entry.text) != whitespaceCollapsed(fragment.text) else { return }

        let movesForward = canMoveForward(index, in: ledger, sequence: sequence)
        ledger.update(index) {
            $0.text = fragment.text
            $0.lastWriteSequence = sequence
        }
        rewriteRows(entry: index, ledger: ledger, movesForward: movesForward,
                    task: task, run: run, modelContext: modelContext, cap: state.messageRowCap)
        if !state.hasUnkeyedText(for: run) {
            run.setOutput(ledger.joinedText)
        }
        task.updatedAt = Date()
        TaskThreadChangeNotifier.post(taskID: task.id, source: "assistant_message_final")
    }

    /// A row may move to "now" only while it is the newest thing recorded for
    /// the run; otherwise it would jump past later tool events. The incremental
    /// transcript reader only refetches rows at or after its cursor, so a row
    /// updated in place without moving shows its new text on the next full read.
    private static func canMoveForward(_ index: Int, in ledger: AssistantMessageLedger, sequence: Int) -> Bool {
        index == ledger.entries.count - 1 && ledger.entries[index].lastWriteSequence == sequence
    }

    private static func appendToRows(
        _ text: String,
        entry index: Int,
        ledger: AssistantMessageLedger,
        movesForward: Bool,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        cap: Int
    ) {
        // With a secret registered, an addition cannot be redacted on its own
        // or against the rows: a secret can span a row boundary or several
        // rows, and the rows already hide its leading fragment, so the rest of
        // it, arriving later, matches nothing there. Only the entry's raw text
        // still holds it whole, so the rows are rebuilt from that text,
        // redacted in one pass.
        guard RunSecretRedactionScope.secrets(for: task.id).isEmpty else {
            syncRedactedRows(entry: index, ledger: ledger, movesForward: movesForward,
                             task: task, run: run, modelContext: modelContext, cap: cap)
            return
        }
        if let row = ledger.entries[index].rows.last, row.payload.count + text.count <= cap {
            row.payload += text
            if movesForward {
                row.timestamp = Date()
            }
            task.updatedAt = Date()
            TaskThreadChangeNotifier.post(taskID: task.id, source: "assistant_message_delta")
            return
        }
        for chunk in chunks(of: text, cap: cap) {
            let row = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.agentResponse, payload: chunk, run: run)
            TaskEventInsertionService.insert(row, into: modelContext)
            ledger.update(index) { $0.rows.append(row) }
        }
    }

    /// Rows cut from the entry's whole text, redacted in one pass. Only rows
    /// whose piece changed are written, so a delta usually touches the last
    /// row and any it adds; only the row the text continues may move to "now".
    private static func syncRedactedRows(
        entry index: Int,
        ledger: AssistantMessageLedger,
        movesForward: Bool,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        cap: Int
    ) {
        let redacted = RunSecretRedactionScope.redact(ledger.entries[index].text, taskID: task.id)
        let pieces = chunks(of: redacted, cap: cap)
        var rows = ledger.entries[index].rows
        let continuedRow = rows.count - 1
        var changedInPlace = false
        for (offset, piece) in pieces.enumerated() {
            if offset < rows.count {
                guard rows[offset].payload != piece else { continue }
                rows[offset].payload = piece
                if movesForward, offset == continuedRow {
                    rows[offset].timestamp = Date()
                }
                changedInPlace = true
            } else {
                let row = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.agentResponse, payload: piece, run: run)
                TaskEventInsertionService.insert(row, into: modelContext)
                rows.append(row)
            }
        }
        for row in rows.dropFirst(pieces.count) {
            modelContext.delete(row)
            changedInPlace = true
        }
        let kept = Array(rows.prefix(pieces.count))
        ledger.update(index) { $0.rows = kept }
        if changedInPlace {
            task.updatedAt = Date()
            TaskThreadChangeNotifier.post(taskID: task.id, source: "assistant_message_delta")
        }
    }

    private static func rewriteRows(
        entry index: Int,
        ledger: AssistantMessageLedger,
        movesForward: Bool,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        cap: Int
    ) {
        // Redact the whole text before splitting, so a secret cannot hide
        // across a row boundary.
        let redacted = RunSecretRedactionScope.redact(ledger.entries[index].text, taskID: task.id)
        let pieces = chunks(of: redacted, cap: cap)
        var rows = ledger.entries[index].rows
        for (offset, piece) in pieces.enumerated() {
            if offset < rows.count {
                rows[offset].payload = piece
                if movesForward {
                    rows[offset].timestamp = Date()
                }
            } else {
                let row = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.agentResponse, payload: piece, run: run)
                TaskEventInsertionService.insert(row, into: modelContext)
                rows.append(row)
            }
        }
        for row in rows.dropFirst(pieces.count) {
            modelContext.delete(row)
        }
        let kept = Array(rows.prefix(pieces.count))
        ledger.update(index) { $0.rows = kept }
    }

    private static func chunks(of text: String, cap: Int) -> [String] {
        guard text.count > cap, cap > 0 else { return [text] }
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(cap)))
            rest = rest.dropFirst(cap)
        }
        return pieces
    }

    private static func whitespaceCollapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
