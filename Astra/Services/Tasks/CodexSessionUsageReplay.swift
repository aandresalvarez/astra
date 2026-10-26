import Foundation
import ASTRAModels

extension CodexSessionUsageCorrectionService {
    /// Reject invalid imported arithmetic instead of saturating or guessing a
    /// historical total. Saturation is suitable for a live limit, not a repair.
    nonisolated static func sum(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= 0, rhs >= 0 else { return nil }
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    nonisolated static func replay(_ runs: [SessionRun]) -> SessionReplay {
        var corrected: [CorrectedRun] = []
        var epoch = ProviderSessionUsageBaseline.zero
        for run in runs {
            guard let recorded = sum(run.recorded.input, run.recorded.output),
                  (run.recordedTotal ?? recorded) >= 0 else { return .unreconstructable(runID: run.id) }
            guard let report = run.report else {
                guard recorded == 0, (run.recordedTotal ?? 0) == 0 else { return .unreconstructable(runID: run.id) }
                continue
            }
            guard sum(report.input, report.output) != nil else { return .unreconstructable(runID: run.id) }
            // Older imports predate the completeness marker. A retained share
            // cannot establish the session's initial cumulative baseline, even
            // if a later export claims to include every remaining row.
            guard !corrected.isEmpty || run.recorded == report else {
                return .unreconstructable(runID: run.id)
            }
            let reset = epoch.isReset(input: report.input, output: report.output)
            let share = epoch.runShare(input: report.input, output: report.output)
            epoch = reset ? .zero : epoch
            // A valid cumulative report bounds each component of its epoch.
            epoch.input = max(epoch.input, report.input)
            epoch.output = max(epoch.output, report.output)
            corrected.append(.init(id: run.id, share: .init(input: share.input, output: share.output), isReset: reset))
        }
        return .corrected(corrected)
    }

    nonisolated static func report(fromStatsPayload payload: String) -> Report? {
        guard let report = ProviderUsageEvidence.Report(payload: payload) else { return nil }
        return Report(input: report.input, output: report.output)
    }

    @MainActor
    static func reportEvidence(_ events: [TaskEvent]) -> (reports: [UUID: Report], invalid: Set<UUID>) {
        var reports: [UUID: Report] = [:]
        var dates: [UUID: Date] = [:]
        var invalid: Set<UUID> = []
        for event in events where event.type == "task.stats" && event.payload.hasPrefix("tokens: ") {
            guard let id = event.run?.id else { continue }
            guard let value = report(fromStatsPayload: event.payload) else { invalid.insert(id); continue }
            if let date = dates[id], event.timestamp == date, reports[id] != value {
                invalid.insert(id) // UUID order cannot establish which report came last.
            }
            if dates[id] == nil || event.timestamp > dates[id]! {
                dates[id] = event.timestamp
                reports[id] = value
            }
        }
        return (reports, invalid)
    }

    struct SessionTotals {
        var inputBefore = 0
        var outputBefore = 0
        var inputAfter = 0
        var outputAfter = 0
        var taskAfter = 0
    }

    @MainActor
    static func sessionTotals(runs: [UUID: TaskRun], corrected: [CorrectedRun], taskTokens: Int) -> SessionTotals? {
        var totals = SessionTotals()
        var before = 0
        var after = 0
        for entry in corrected {
            guard let run = runs[entry.id],
                  let inputBefore = sum(totals.inputBefore, run.inputTokens),
                  let outputBefore = sum(totals.outputBefore, run.outputTokens),
                  let inputAfter = sum(totals.inputAfter, entry.share.input),
                  let outputAfter = sum(totals.outputAfter, entry.share.output),
                  let oldTotal = sum(before, run.tokensUsed),
                  let share = sum(entry.share.input, entry.share.output),
                  let newTotal = sum(after, share) else { return nil }
            totals.inputBefore = inputBefore; totals.outputBefore = outputBefore
            totals.inputAfter = inputAfter; totals.outputAfter = outputAfter
            before = oldTotal; after = newTotal
        }
        guard taskTokens >= before, let total = sum(taskTokens - before, after) else { return nil }
        totals.taskAfter = total
        return totals
    }
}
