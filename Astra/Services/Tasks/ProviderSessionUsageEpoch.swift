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

    static let zero = ProviderSessionUsageBaseline()

    /// A report below what earlier runs already recorded means the provider restarted its counters
    /// (compaction or a counter reset), so the report covers only usage since then.
    func isReset(input: Int, output: Int) -> Bool {
        (input > 0 && input < self.input) || (output > 0 && output < self.output)
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
        let earlier = task.runs.filter { $0.id != run.id && $0.providerSessionId == session }
        guard !earlier.isEmpty else { return .zero }
        let resetRunIDs = Set(task.events.filter { $0.type == resetEventType }.compactMap { $0.run?.id })
        guard !resetRunIDs.contains(run.id) else { return .zero }
        let epochStart = earlier.filter { resetRunIDs.contains($0.id) }.map(\.startedAt).max()
        let epoch = epochStart.map { start in earlier.filter { $0.startedAt >= start } } ?? earlier
        return ProviderSessionUsageBaseline(
            input: epoch.reduce(0) { $0 + $1.inputTokens },
            output: epoch.reduce(0) { $0 + $1.outputTokens },
            cost: epoch.reduce(0) { $0 + $1.costUSD }
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
        guard baseline.isReset(input: input, output: output) else { return baseline }
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
