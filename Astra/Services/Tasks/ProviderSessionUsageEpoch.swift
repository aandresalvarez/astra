import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

/// The usage a resumed provider session's cumulative report already contains: what earlier runs of the
/// same session recorded since its counters last restarted.
struct ProviderSessionUsageBaseline: Equatable, Sendable {
    var input = 0
    var output = 0
    var cost = 0.0
    /// Non-nil only when the ledger also contains estimated historical usage.
    var reportedInput: Int? = nil
    var reportedOutput: Int? = nil
    var reconciliationPending = false
    var costIsConfirmed = true

    var budgetBaseline: Self { .init(input: reportedInput ?? input, output: reportedOutput ?? output, cost: cost) }

    static let zero = ProviderSessionUsageBaseline()

    /// A report below what earlier runs already recorded means the provider restarted its counters
    /// (compaction or a counter reset), so the report covers only usage since then.
    func isReset(input: Int, output: Int) -> Bool {
        (input > 0 && input < (reportedInput ?? self.input)) || (output > 0 && output < (reportedOutput ?? self.output))
    }

    /// This run's share of a cumulative report: all of it after a reset, otherwise what it adds to the baseline.
    func runShare(input: Int, output: Int) -> (input: Int, output: Int) {
        isReset(input: input, output: output)
            ? (input, output)
            : (max(0, input - self.input), max(0, output - self.output))
    }
}

/// Accounting epochs of a provider session whose resumed launches report cumulative usage. A run whose
/// report shows the counters restarted is marked with a durable event; later runs of the session measure
/// their reports against the runs since that mark instead of the session's whole history.
enum ProviderSessionUsageEpoch {
    static let resetEventType = "astra.provider_session_usage_reset"

    /// Zero unless the run's runtime reports cumulative session usage and earlier runs of its session
    /// recorded usage in the current epoch.
    @MainActor
    static func baseline(for run: TaskRun, in task: AgentTask) -> ProviderSessionUsageBaseline {
        guard let runtime = run.runtimeID.flatMap(AgentRuntimeID.init(rawValue:)),
              AgentRuntimeAdapterRegistry.adapter(for: runtime).descriptor.reportsCumulativeSessionUsage,
              let session = run.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty else { return .zero }
        if runtime == .claudeCode {
            if TaskHistoryRead.events(for: task, ofTypes: [resetEventType]).contains(where: { $0.run?.id == run.id }) { return .zero }
            return ClaudeSessionUsageEvidence.baseline(for: run, task: task)
        }
        let earlier = task.runs.filter { $0.id != run.id && $0.runtimeID == run.runtimeID
            && $0.providerSessionId == session && $0.startedAt < run.startedAt }
        guard !earlier.isEmpty else { return .zero }
        let resetRunIDs = Set(TaskHistoryRead.events(for: task, ofTypes: [resetEventType]).compactMap { $0.run?.id })
        guard !resetRunIDs.contains(run.id) else { return .zero }
        let epochStart = earlier.filter { resetRunIDs.contains($0.id) }.map(\.startedAt).max()
        let epoch = epochStart.map { start in earlier.filter { $0.startedAt >= start } } ?? earlier
        let measured = ProviderUsageEvidence.measuredBaseline(runs: epoch, task: task)
        return ProviderSessionUsageBaseline(
            input: epoch.reduce(0) { RuntimeUsageArithmetic.adding($0, $1.inputTokens) },
            output: epoch.reduce(0) { RuntimeUsageArithmetic.adding($0, $1.outputTokens) },
            cost: epoch.reduce(0) { $0 + $1.costUSD },
            reportedInput: measured?.input, reportedOutput: measured?.output
        )
    }

    /// The baseline a cumulative report is measured against. A report showing the counters restarted
    /// starts a new epoch at this run, so it counts in full rather than being clamped to nothing.
    @MainActor
    static func baseline(
        forReport input: Int,
        output: Int,
        run: TaskRun,
        task: AgentTask,
        modelContext: ModelContext
    ) -> ProviderSessionUsageBaseline {
        let baseline = baseline(for: run, in: task)
        if baseline.reconciliationPending { ClaudeSessionUsageEvidence.markUnconfirmed(task: task, run: run, context: modelContext) }
        if baseline.reportedInput != nil, input < baseline.input || output < baseline.output {
            let message = "Usage remains approximate because earlier turns have estimates rather than provider reports. ASTRA kept conservative historical totals; this request's limit uses the confirmed usage baseline."
            if !TaskHistoryRead.events(for: task, ofTypes: [TaskEventTypes.System.info.rawValue]).contains(where: { $0.run?.id == run.id && $0.payload == message }) {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: message, run: run))
            }
        }
        let nativeZeroReset = run.runtimeID == AgentRuntimeID.claudeCode.rawValue
            && (input < baseline.input || output < baseline.output)
            && TaskHistoryRead.events(for: task, ofTypes: [ClaudeSessionUsageEvidence.eventType]).contains { event in
                guard let snapshot = ClaudeSessionUsageEvidence.snapshot(event: event, run: run) else { return false }
                return snapshot.input == input && snapshot.output == output
            }
        guard baseline.isReset(input: input, output: output) || nativeZeroReset else { return baseline }
        let payload: [String: String] = [
            "session_id_prefix": String((run.providerSessionId ?? "").prefix(8)),
            "reported_input": String(input),
            "reported_output": String(output),
            "baseline_input": String(baseline.input),
            "baseline_output": String(baseline.output)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        modelContext.insert(TaskEvent(task: task, type: resetEventType, payload: json, run: run))
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: payload.merging([
            "source": "provider_session_usage_reset",
            "runtime": run.runtimeID ?? "unknown"
        ]) { current, _ in current })
        return .zero
    }
}
