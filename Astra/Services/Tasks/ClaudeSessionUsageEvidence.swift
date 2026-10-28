import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Typed provider evidence, derived from the owned stream and persisted with its
/// run. Legacy task.stats cannot prove whether counters covered a call or session.
@MainActor
enum ClaudeSessionUsageEvidence {
    static let eventType = "astra.claude_session_usage"
    static let uncertainEventType = "astra.claude_session_usage_unconfirmed"

    static func record(_ snapshot: ClaudeSessionUsageSnapshot, task: AgentTask, run: TaskRun, context: ModelContext) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard snapshot.isValid, run.runtimeID == AgentRuntimeID.claudeCode.rawValue,
              run.providerSessionId == snapshot.sessionID,
              let data = try? encoder.encode(snapshot), let payload = String(data: data, encoding: .utf8),
              !TaskHistoryRead.events(for: task, ofTypes: [eventType]).contains(where: { $0.run?.id == run.id && $0.payload == payload }) else { return }
        context.insert(TaskEvent(task: task, type: eventType, payload: payload, run: run))
    }

    static func snapshot(event: TaskEvent, run: TaskRun) -> ClaudeSessionUsageSnapshot? {
        guard event.type == eventType, event.run?.id == run.id,
              run.runtimeID == AgentRuntimeID.claudeCode.rawValue,
              let value = try? JSONDecoder().decode(ClaudeSessionUsageSnapshot.self, from: Data(event.payload.utf8)),
              value.isValid, value.sessionID == run.providerSessionId else { return nil }
        return value
    }

    static func baseline(for run: TaskRun, task: AgentTask) -> ProviderSessionUsageBaseline {
        let earlier = task.runs.filter { $0.runtimeID == run.runtimeID && $0.providerSessionId == run.providerSessionId
            && $0.id != run.id && $0.startedAt <= run.startedAt }
        guard !earlier.isEmpty else { return .zero }
        // Imported dates can lose subsecond precision. A UUID makes display
        // ordering stable, but cannot prove which tied run owns the last total.
        let latestDate = earlier.map(\.startedAt).max()
        guard latestDate != run.startedAt, earlier.filter({ $0.startedAt == latestDate }).count == 1 else {
            return .init(reconciliationPending: true, costIsConfirmed: false)
        }
        let byID = Dictionary(uniqueKeysWithValues: earlier.map { ($0.id, $0) })
        let events = TaskHistoryRead.events(for: task, ofTypes: [eventType]).filter { $0.run.map { byID[$0.id] != nil } == true }.sorted {
            guard let lhs = $0.run, let rhs = $1.run else { return $0.id.uuidString < $1.id.uuidString }
            if lhs.id != rhs.id { return TaskRun.isChronologicallyOrdered(lhs, rhs) }
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        for event in events.reversed() {
            guard let prior = event.run, let value = snapshot(event: event, run: prior) else { continue }
            let ambiguousEventTie = events.contains { candidate in
                guard candidate.run?.id == prior.id, candidate.timestamp == event.timestamp,
                      let other = snapshot(event: candidate, run: prior) else { return false }
                return other != value
            }
            guard !ambiguousEventTie else { return .init(reconciliationPending: true, costIsConfirmed: false) }
            let hasEvidenceGap = earlier.contains { TaskRun.isChronologicallyOrdered(prior, $0) }
            guard !hasEvidenceGap else { return .init(reconciliationPending: true, costIsConfirmed: false) }
            return .init(input: value.input, output: value.output, cost: value.costUSD ?? 0,
                         reconciliationPending: value.costUSD == nil, costIsConfirmed: value.costUSD != nil)
        }
        return .init(reconciliationPending: true, costIsConfirmed: false)
    }

    static func markUnconfirmed(task: AgentTask, run: TaskRun, context: ModelContext) {
        guard !TaskHistoryRead.events(for: task, ofTypes: [uncertainEventType]).contains(where: { $0.run?.id == run.id }) else { return }
        context.insert(TaskEvent(task: task, type: uncertainEventType,
            payload: "Earlier Claude usage lacks a complete native session snapshot. This request's usage remains unconfirmed; ASTRA kept its execution allowance conservative and preserved the historical records and any unconfirmed cost.", run: run))
    }
}
