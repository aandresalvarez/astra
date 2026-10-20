import Foundation
import SwiftData
import ASTRAModels
import ASTRACore
import ASTRAPersistence

/// Rewrites Codex runs recorded before Codex declared cumulative session usage.
///
/// Codex's `turn.completed.usage` is the thread's running total, and until Codex set
/// `reportsCumulativeSessionUsage` each resumed run stored that total as its own usage
/// (prod task E0F780F8: six runs summing to 20.9M input against 7.9M real). The first
/// run after the fix measured its report against those inflated runs, so it either read
/// as a counter reset (counting the whole total once, behind a spurious reset marker) or
/// came out short.
///
/// Each run's `task.stats` event keeps the raw report the provider sent, whichever build
/// recorded it. The correction replays `ProviderSessionUsageEpoch`'s accounting over
/// those reports, so every session ends up exactly as the fixed recorder would have
/// stored it: per-run shares, reset markers only where the counters really went down.
/// Records already in that state are left alone, which makes the pass idempotent and
/// safe to re-run after each update. A session with a run whose report cannot be read
/// back is skipped and logged rather than guessed at.
@MainActor
enum CodexSessionUsageCorrectionService {
    static let correctedEventType = "astra.provider_session_usage_corrected"

    /// A provider usage report: the input and output tokens a `task.stats` event recorded.
    struct Report: Equatable, Sendable {
        var input: Int
        var output: Int
    }

    /// One run of a session as the replay sees it.
    struct SessionRun: Equatable, Sendable {
        var id: UUID
        var recorded: Report
        /// Nil when the run recorded no provider report.
        var report: Report?
    }

    /// What the fixed recorder stores for one run of the session.
    struct CorrectedRun: Equatable, Sendable {
        var id: UUID
        var share: Report
        var isReset: Bool
    }

    enum SessionReplay: Equatable, Sendable {
        case corrected([CorrectedRun])
        /// A run recorded usage but no readable report, so its raw total is unknown.
        case unreconstructable(runID: UUID)
    }

    struct Outcome: Equatable {
        var tasksCorrected = 0
        var runsCorrected = 0
        var sessionsSkipped = 0
        var completed = false
    }

    /// Build-gated like the other startup repairs: re-running after an update, or on a
    /// store imported since, finds already-corrected sessions unchanged.
    @discardableResult
    static func correctIfNeeded(
        modelContext: ModelContext,
        currentBuild: String,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard defaults.string(forKey: AppStorageKeys.completedCodexSessionUsageCorrectionBuild) != currentBuild else {
            return false
        }
        guard await correct(modelContext: modelContext).completed else { return false }
        defaults.set(currentBuild, forKey: AppStorageKeys.completedCodexSessionUsageCorrectionBuild)
        return true
    }

    @discardableResult
    static func correct(modelContext: ModelContext) async -> Outcome {
        let codex: String? = AgentRuntimeID.codexCLI.rawValue
        let descriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.runtimeID == codex && $0.providerSessionId != nil }
        )
        let tasks: [AgentTask]
        do {
            var seen = Set<UUID>()
            tasks = try modelContext.fetch(descriptor).compactMap(\.task).filter { seen.insert($0.id).inserted }
        } catch {
            log(stage: "fetch_failed", outcome: Outcome(), error: error)
            return Outcome()
        }

        var outcome = Outcome()
        for task in tasks {
            let result: TaskResult
            do {
                result = try correct(task: task, modelContext: modelContext)
            } catch {
                log(stage: "task_failed", outcome: outcome, error: error)
                return outcome
            }
            outcome.sessionsSkipped += result.sessionsSkipped
            if result.runsCorrected > 0 {
                outcome.tasksCorrected += 1
                outcome.runsCorrected += result.runsCorrected
            }
            await Task.yield()
        }
        outcome.completed = true
        if outcome.tasksCorrected > 0 || outcome.sessionsSkipped > 0 {
            log(stage: "completed", outcome: outcome, error: nil)
        }
        return outcome
    }

    /// Replays the fixed recorder over one session's reports, in run order. A run with no
    /// report and no recorded usage (a launch that failed before Codex answered) adds
    /// nothing to the session's totals, so it is left out of the replay.
    nonisolated static func replay(_ runs: [SessionRun]) -> SessionReplay {
        var corrected: [CorrectedRun] = []
        var epoch = ProviderSessionUsageBaseline.zero
        for run in runs {
            guard let report = run.report else {
                guard run.recorded.input + run.recorded.output == 0 else { return .unreconstructable(runID: run.id) }
                continue
            }
            let isReset = epoch.isReset(input: report.input, output: report.output)
            let share = epoch.runShare(input: report.input, output: report.output)
            epoch = isReset ? .zero : epoch
            epoch.input += share.input
            epoch.output += share.output
            corrected.append(CorrectedRun(
                id: run.id, share: Report(input: share.input, output: share.output), isReset: isReset
            ))
        }
        return .corrected(corrected)
    }

    /// The report a `task.stats` payload records, as the recorder writes it:
    /// `tokens: <total> (in: <input>, out: <output>) | …`. An estimate is not a report.
    nonisolated static func report(fromStatsPayload payload: String) -> Report? {
        guard payload.hasPrefix("tokens: "),
              let open = payload.range(of: "(in: "),
              let separator = payload.range(of: ", out: ", range: open.upperBound..<payload.endIndex),
              let close = payload.range(of: ")", range: separator.upperBound..<payload.endIndex),
              let input = Int(payload[open.upperBound..<separator.lowerBound]),
              let output = Int(payload[separator.upperBound..<close.lowerBound]) else { return nil }
        return Report(input: input, output: output)
    }

    private struct TaskResult {
        var runsCorrected = 0
        var sessionsSkipped = 0
    }

    private struct SessionChange: Encodable {
        var sessionIDPrefix: String
        var runsCorrected: Int
        var inputBefore: Int
        var inputAfter: Int
        var outputBefore: Int
        var outputAfter: Int
        var resetMarkersAdded: Int
        var resetMarkersRemoved: Int

        enum CodingKeys: String, CodingKey {
            case sessionIDPrefix = "session_id_prefix"
            case runsCorrected = "runs_corrected"
            case inputBefore = "input_before"
            case inputAfter = "input_after"
            case outputBefore = "output_before"
            case outputAfter = "output_after"
            case resetMarkersAdded = "reset_markers_added"
            case resetMarkersRemoved = "reset_markers_removed"
        }
    }

    private static func correct(task: AgentTask, modelContext: ModelContext) throws -> TaskResult {
        let codexRuns = task.runs.filter { $0.runtimeID == AgentRuntimeID.codexCLI.rawValue }
        let sessions = Dictionary(grouping: codexRuns) {
            $0.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.filter { !$0.key.isEmpty && $0.value.count > 1 }
        guard !sessions.isEmpty else { return TaskResult() }

        let taskID = task.id
        let stats = TaskEventTypes.Task.stats.rawValue
        let reset = ProviderSessionUsageEpoch.resetEventType
        let events = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.task?.id == taskID && ($0.type == stats || $0.type == reset) },
            sortBy: [SortDescriptor(\TaskEvent.timestamp)]
        ))
        // The last report of a run is its final cumulative total.
        var reports: [UUID: Report] = [:]
        var resetMarkers: [UUID: [TaskEvent]] = [:]
        for event in events {
            guard let runID = event.run?.id else { continue }
            if event.type == reset {
                resetMarkers[runID, default: []].append(event)
            } else if let parsed = report(fromStatsPayload: event.payload) {
                reports[runID] = parsed
            }
        }

        var result = TaskResult()
        var changes: [SessionChange] = []
        for (session, runs) in sessions.sorted(by: { $0.key < $1.key }) {
            let prefix = String(session.prefix(8))
            guard !runs.contains(where: { $0.status == .running }) else {
                result.sessionsSkipped += 1
                logSkip(task: task, sessionPrefix: prefix, reason: "run_in_progress", runID: nil)
                continue
            }
            let ordered = runs.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            let replayed = replay(ordered.map { run in
                SessionRun(
                    id: run.id,
                    recorded: Report(input: run.inputTokens, output: run.outputTokens),
                    report: reports[run.id]
                )
            })
            guard case .corrected(let corrected) = replayed else {
                if case .unreconstructable(let runID) = replayed {
                    result.sessionsSkipped += 1
                    logSkip(task: task, sessionPrefix: prefix, reason: "report_missing", runID: runID)
                }
                continue
            }
            let runsByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
            var change = SessionChange(
                sessionIDPrefix: prefix, runsCorrected: 0,
                inputBefore: 0, inputAfter: 0, outputBefore: 0, outputAfter: 0,
                resetMarkersAdded: 0, resetMarkersRemoved: 0
            )
            for entry in corrected {
                guard let run = runsByID[entry.id] else { continue }
                change.inputBefore += run.inputTokens
                change.outputBefore += run.outputTokens
                change.inputAfter += entry.share.input
                change.outputAfter += entry.share.output
                let total = entry.share.input + entry.share.output
                if run.inputTokens != entry.share.input || run.outputTokens != entry.share.output || run.tokensUsed != total {
                    task.tokensUsed = max(0, task.tokensUsed + total - run.tokensUsed)
                    run.inputTokens = entry.share.input
                    run.outputTokens = entry.share.output
                    run.tokensUsed = total
                    change.runsCorrected += 1
                }
                let markers = resetMarkers[entry.id] ?? []
                if entry.isReset, markers.isEmpty {
                    insertResetMarker(for: run, report: reports[entry.id], task: task, modelContext: modelContext)
                    change.resetMarkersAdded += 1
                } else if !entry.isReset, !markers.isEmpty {
                    // Left by a report measured against inflated legacy runs, it would start the
                    // session's next epoch at this run and count the runs before it twice.
                    markers.forEach(modelContext.delete)
                    change.resetMarkersRemoved += markers.count
                }
            }
            guard change.runsCorrected > 0 || change.resetMarkersAdded > 0 || change.resetMarkersRemoved > 0 else {
                continue
            }
            result.runsCorrected += change.runsCorrected
            changes.append(change)
            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "source": "codex_session_usage_correction",
                "session_id_prefix": prefix,
                "runs_corrected": String(change.runsCorrected),
                "input_before": String(change.inputBefore),
                "input_after": String(change.inputAfter),
                "output_before": String(change.outputBefore),
                "output_after": String(change.outputAfter),
                "reset_markers_added": String(change.resetMarkersAdded),
                "reset_markers_removed": String(change.resetMarkersRemoved)
            ])
        }
        guard !changes.isEmpty else { return result }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = (try? encoder.encode(changes)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        modelContext.insert(TaskEvent(task: task, type: correctedEventType, payload: payload))
        // Run usage mirrors into the workspace JSON, so the corrected values are exported too.
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "codex_session_usage_correction"]
        )
        return result
    }

    private static func insertResetMarker(for run: TaskRun, report: Report?, task: AgentTask, modelContext: ModelContext) {
        let payload: [String: String] = [
            "session_id_prefix": String((run.providerSessionId ?? "").prefix(8)),
            "reported_input": String(report?.input ?? run.inputTokens),
            "reported_output": String(report?.output ?? run.outputTokens),
            "source": "codex_session_usage_correction"
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let marker = TaskEvent(task: task, type: ProviderSessionUsageEpoch.resetEventType, payload: json, run: run)
        marker.timestamp = run.completedAt ?? run.startedAt
        modelContext.insert(marker)
    }

    private static func logSkip(task: AgentTask, sessionPrefix: String, reason: String, runID: UUID?) {
        var fields = [
            "source": "codex_session_usage_correction",
            "session_id_prefix": sessionPrefix,
            "skipped": reason
        ]
        if let runID { fields["run_id"] = String(runID.uuidString.prefix(8)) }
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: fields, level: .warning)
    }

    private static func log(stage: String, outcome: Outcome, error: Error?) {
        var fields = [
            "migration": "codex_session_usage_correction",
            "stage": stage,
            "tasks_corrected": String(outcome.tasksCorrected),
            "runs_corrected": String(outcome.runsCorrected),
            "sessions_skipped": String(outcome.sessionsSkipped)
        ]
        if let error {
            fields["error_type"] = String(describing: type(of: error))
        }
        AppLogger.audit(.dataStoreRecovered, category: "Persistence", fields: fields, level: error == nil ? .info : .error)
    }
}
