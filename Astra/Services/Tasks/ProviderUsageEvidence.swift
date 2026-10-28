import Foundation
import ASTRAModels

/// Reads usage provenance from the durable event history; estimates never prove
/// that a provider reset its counters or grant additional execution allowance.
enum ProviderUsageEvidence {
    struct Report {
        let input: Int
        let output: Int
        init?(payload: String) {
            guard payload.hasPrefix("tokens: "), let open = payload.range(of: " (in: "),
                  open.lowerBound > payload.index(payload.startIndex, offsetBy: 8),
                  let separator = payload.range(of: ", out: ", range: open.upperBound..<payload.endIndex),
                  let close = payload.range(of: ")", range: separator.upperBound..<payload.endIndex),
                  let total = Int(payload[payload.index(payload.startIndex, offsetBy: 8)..<open.lowerBound]),
                  let input = Int(payload[open.upperBound..<separator.lowerBound]),
                  let output = Int(payload[separator.upperBound..<close.lowerBound]), input >= 0, output >= 0 else { return nil }
            let sum = input.addingReportingOverflow(output)
            guard !sum.overflow, sum.partialValue == total else { return nil }
            self.input = input; self.output = output
        }
    }

    static func hasReport(run: TaskRun, task: AgentTask) -> Bool {
        TaskHistoryRead.events(for: task, ofTypes: ["task.stats"]).contains { $0.run?.id == run.id && Report(payload: $0.payload) != nil }
    }

    static func measuredBaseline(runs: [TaskRun], task: AgentTask) -> (input: Int, output: Int)? {
        let ids = Set(runs.map(\.id))
        let events = TaskHistoryRead.events(for: task, ofTypes: ["task.stats"]).filter { $0.run.map { ids.contains($0.id) } == true }
        let estimated = Set(events.filter { $0.payload.hasPrefix("estimated tokens:") }.compactMap { $0.run?.id })
        guard !estimated.isEmpty else { return nil }
        // The last raw cumulative report is a lower bound when later turns have
        // only estimates. Charging from that bound cannot refill a run's limit.
        if let report = events.sorted(by: { $0.timestamp > $1.timestamp }).compactMap({ Report(payload: $0.payload) }).first {
            return (report.input, report.output)
        }
        let known = runs.filter { !estimated.contains($0.id) }
        return (known.reduce(0) { RuntimeUsageArithmetic.adding($0, $1.inputTokens) },
                known.reduce(0) { RuntimeUsageArithmetic.adding($0, $1.outputTokens) })
    }
}
