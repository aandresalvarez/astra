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
/// back is skipped and logged rather than guessed at; one with a run in progress is
/// left for the next launch.
@MainActor
enum CodexSessionUsageCorrectionService {
    static let correctedEventType = "astra.provider_session_usage_corrected"
    /// A reset marker the replay found spurious keeps its evidence under this type, which
    /// `ProviderSessionUsageEpoch` does not read as an epoch start.
    static let supersededResetEventType = "astra.provider_session_usage_reset.superseded"

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
        var recordedTotal: Int? = nil
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
        /// Sessions that can never be corrected: a run's report is gone.
        var sessionsSkipped = 0
        /// Sessions with a run in progress, corrected on a later pass.
        var sessionsDeferred = 0
        /// False when the pass failed or deferred a session, so the gate stays open.
        var completed = false
    }

    /// Build-gated like the other startup repairs. Importing a workspace that brings Codex
    /// session runs clears the gate (`WorkspaceConfigManager`), since an older export can
    /// hold running totals; new turns record their own share and need no re-run. Each
    /// re-run finds corrected sessions unchanged.
    @discardableResult
    static func correctIfNeeded(
        modelContext: ModelContext,
        currentBuild: String,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        let key = AppStorageKeys.completedCodexSessionUsageCorrectionBuild
        guard defaults.string(forKey: key) != currentBuild else { return false }
        // The pass yields, and an import in the meantime clears the gate. Completion is recorded
        // only over this pass's own pending mark, so that clearing is never overwritten.
        let pending = "\(currentBuild):pending:\(UUID().uuidString)"
        defaults.set(pending, forKey: key)
        guard await correct(modelContext: modelContext).completed,
              defaults.string(forKey: key) == pending else { return false }
        defaults.set(currentBuild, forKey: key)
        return true
    }

    private static var codexSessionRuns: FetchDescriptor<TaskRun> {
        let codex: String? = AgentRuntimeID.codexCLI.rawValue
        return FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.runtimeID == codex && $0.providerSessionId != nil }
        )
    }

    /// Runs are read in bounded pages, with a yield between tasks and between pages, so a
    /// store with many Codex runs never materializes them all on the main actor at once.
    nonisolated static let batchSize = 200

    @discardableResult
    static func correct(
        modelContext: ModelContext,
        batchSize: Int = CodexSessionUsageCorrectionService.batchSize
    ) async -> Outcome {
        guard batchSize > 0 else { return Outcome() }
        // Keyset paging on `startedAt`: an offset would skip or repeat rows when the context
        // holds unsaved changes, which a fetch merges in ahead of the stored rows. Runs added
        // during the pass start after the cursor.
        let codex: String? = AgentRuntimeID.codexCLI.rawValue
        var cursor: Date?
        var strictlyAfterCursor = false
        var seenAtCursor = Set<UUID>()
        var visited = Set<UUID>()
        var outcome = Outcome()
        while true {
            var descriptor = codexSessionRuns
            if let start = cursor {
                descriptor.predicate = strictlyAfterCursor
                    ? #Predicate<TaskRun> { $0.runtimeID == codex && $0.providerSessionId != nil && $0.startedAt > start }
                    : #Predicate<TaskRun> { $0.runtimeID == codex && $0.providerSessionId != nil && $0.startedAt >= start }
            }
            descriptor.sortBy = [SortDescriptor(\TaskRun.startedAt)]
            descriptor.fetchLimit = batchSize
            let page: [TaskRun]
            do {
                page = try modelContext.fetch(descriptor)
            } catch {
                log(stage: "fetch_failed", outcome: outcome, error: error)
                return outcome
            }
            var fresh = page.filter { $0.startedAt != cursor || !seenAtCursor.contains($0.id) }
            if fresh.isEmpty {
                guard page.count == batchSize, let start = cursor else { break }
                // More than a page of runs share the cursor's start time, so `>=` keeps returning
                // the same page. Read that one group whole, then continue after it.
                let group = FetchDescriptor<TaskRun>(predicate: #Predicate<TaskRun> {
                    $0.runtimeID == codex && $0.providerSessionId != nil && $0.startedAt == start
                })
                do {
                    fresh = try modelContext.fetch(group).filter { !seenAtCursor.contains($0.id) }
                } catch {
                    log(stage: "fetch_failed", outcome: outcome, error: error)
                    return outcome
                }
                strictlyAfterCursor = true
            } else {
                strictlyAfterCursor = false
                if let last = fresh.last?.startedAt {
                    if last != cursor { seenAtCursor = [] }
                    cursor = last
                    seenAtCursor.formUnion(fresh.filter { $0.startedAt == last }.map(\.id))
                }
            }
            // A task is corrected whole, from whichever of its runs a page reaches first.
            let tasks = fresh.compactMap(\.task).filter { visited.insert($0.id).inserted }
            for task in tasks {
                let result: TaskResult
                do {
                    result = try correct(task: task, modelContext: modelContext)
                } catch {
                    log(stage: "task_failed", outcome: outcome, error: error)
                    return outcome
                }
                outcome.sessionsSkipped += result.sessionsSkipped
                outcome.sessionsDeferred += result.sessionsDeferred
                if result.runsCorrected > 0 {
                    outcome.tasksCorrected += 1
                    outcome.runsCorrected += result.runsCorrected
                }
                await Task.yield()
            }
            await Task.yield()
        }
        outcome.completed = outcome.sessionsDeferred == 0
        if outcome.tasksCorrected > 0 || outcome.sessionsSkipped > 0 || outcome.sessionsDeferred > 0 {
            log(stage: "completed", outcome: outcome, error: nil)
        }
        return outcome
    }

    /// Import is an explicit repair boundary, scoped to the imported workspace.
    /// Startup still covers restored stores and previously deferred tasks.
    static func correct(workspace: Workspace, modelContext: ModelContext) {
        for task in workspace.tasks {
            do { _ = try correct(task: task, modelContext: modelContext) }
            catch { log(stage: "import_task_failed", outcome: Outcome(), error: error) }
        }
    }

    private struct TaskResult {
        var runsCorrected = 0
        var sessionsSkipped = 0
        var sessionsDeferred = 0
    }

    /// What a task's correction changed, so a failed save can put it back without rolling
    /// back the whole context (which would discard unrelated unsaved work).
    private struct Journal {
        var taskTokensUsed: Int
        var taskUpdatedAt: Date
        var runs: [(run: TaskRun, input: Int, output: Int, total: Int)] = []
        var retypedMarkers: [TaskEvent] = []
        var insertedEvents: [TaskEvent] = []

        func revert(task: AgentTask, modelContext: ModelContext) {
            for entry in runs {
                entry.run.inputTokens = entry.input
                entry.run.outputTokens = entry.output
                entry.run.tokensUsed = entry.total
            }
            retypedMarkers.forEach { $0.type = ProviderSessionUsageEpoch.resetEventType }
            insertedEvents.forEach(modelContext.delete)
            task.tokensUsed = taskTokensUsed
            task.updatedAt = taskUpdatedAt
        }
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
        guard Set(codexRuns.map(\.id)).count == codexRuns.count else {
            logSkip(task: task, sessionPrefix: "", reason: "duplicate_run_identity", runID: nil)
            return TaskResult(sessionsSkipped: sessions.count)
        }
        if task.events.contains(where: { $0.type == CodexUsageHistory.incompleteEventType }) {
            logSkip(task: task, sessionPrefix: "", reason: "history_incomplete", runID: nil)
            return TaskResult(sessionsSkipped: sessions.count)
        }
        let lease: RuntimeExecutionOwnerStore.Lease
        do { lease = try CodexSessionUsageCorrectionAdmission.acquire(task: task, context: modelContext) }
        catch {
            logSkip(task: task, sessionPrefix: "", reason: "execution_unverified_or_active", runID: nil)
            return TaskResult(sessionsDeferred: sessions.count)
        }
        defer { withExtendedLifetime(lease) {} }

        let taskID = task.id
        let stats = TaskEventTypes.Task.stats.rawValue
        let reset = ProviderSessionUsageEpoch.resetEventType
        let events = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.task?.id == taskID && ($0.type == stats || $0.type == reset) },
            sortBy: [SortDescriptor(\TaskEvent.timestamp)]
        ))
        let evidence = reportEvidence(events)
        let reports = evidence.reports
        var resetMarkers: [UUID: [TaskEvent]] = [:]
        for event in events {
            guard let runID = event.run?.id else { continue }
            if event.type == reset {
                resetMarkers[runID, default: []].append(event)
            }
        }

        var result = TaskResult()
        var changes: [SessionChange] = []
        var journal = Journal(taskTokensUsed: task.tokensUsed, taskUpdatedAt: task.updatedAt)
        for (session, runs) in sessions.sorted(by: { $0.key < $1.key }) {
            let prefix = String(session.prefix(8))
            guard Set(runs.map(\.id)).count == runs.count,
                  Set(runs.map(\.startedAt)).count == runs.count,
                  !runs.contains(where: { evidence.invalid.contains($0.id) }) else {
                result.sessionsSkipped += 1
                logSkip(task: task, sessionPrefix: prefix, reason: "history_ambiguous_or_invalid", runID: nil)
                continue
            }
            let ordered = runs.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            let replayed = replay(ordered.map { run in
                SessionRun(
                    id: run.id,
                    recorded: Report(input: run.inputTokens, output: run.outputTokens),
                    report: reports[run.id], recordedTotal: run.tokensUsed
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
            guard let totals = sessionTotals(runs: runsByID, corrected: corrected, taskTokens: task.tokensUsed) else {
                result.sessionsSkipped += 1
                logSkip(task: task, sessionPrefix: prefix, reason: "usage_totals_invalid", runID: nil)
                continue
            }
            var change = SessionChange(
                sessionIDPrefix: prefix, runsCorrected: 0,
                inputBefore: totals.inputBefore, inputAfter: totals.inputAfter,
                outputBefore: totals.outputBefore, outputAfter: totals.outputAfter,
                resetMarkersAdded: 0, resetMarkersRemoved: 0
            )
            for entry in corrected {
                guard let run = runsByID[entry.id] else { continue }
                let total = entry.share.input + entry.share.output
                if run.inputTokens != entry.share.input || run.outputTokens != entry.share.output || run.tokensUsed != total {
                    journal.runs.append((run, run.inputTokens, run.outputTokens, run.tokensUsed))
                    run.inputTokens = entry.share.input
                    run.outputTokens = entry.share.output
                    run.tokensUsed = total
                    change.runsCorrected += 1
                }
                let markers = resetMarkers[entry.id] ?? []
                if entry.isReset, markers.isEmpty {
                    journal.insertedEvents.append(
                        insertResetMarker(for: run, report: reports[entry.id], task: task, modelContext: modelContext)
                    )
                    change.resetMarkersAdded += 1
                } else if !entry.isReset, !markers.isEmpty {
                    // Left by a report measured against inflated legacy runs, it would start the
                    // session's next epoch at this run and count the runs before it twice.
                    markers.forEach { $0.type = supersededResetEventType }
                    journal.retypedMarkers += markers
                    change.resetMarkersRemoved += markers.count
                }
            }
            task.tokensUsed = totals.taskAfter
            guard change.runsCorrected > 0 || change.resetMarkersAdded > 0 || change.resetMarkersRemoved > 0 else {
                continue
            }
            result.runsCorrected += change.runsCorrected
            changes.append(change)
        }
        guard !changes.isEmpty else { return result }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = (try? encoder.encode(changes)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let corrected = TaskEvent(task: task, type: correctedEventType, payload: payload)
        modelContext.insert(corrected)
        journal.insertedEvents.append(corrected)
        // A history repair is not activity: inserting events stamps the task as just updated,
        // which would float every corrected task to the top of recency-ordered lists.
        task.updatedAt = journal.taskUpdatedAt
        do {
            // Run usage mirrors into the workspace JSON, so the corrected values are exported too.
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "codex_session_usage_correction"]
            )
        } catch {
            journal.revert(task: task, modelContext: modelContext)
            throw error
        }
        for change in changes {
            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "source": "codex_session_usage_correction",
                "session_id_prefix": change.sessionIDPrefix,
                "runs_corrected": String(change.runsCorrected),
                "input_before": String(change.inputBefore),
                "input_after": String(change.inputAfter),
                "output_before": String(change.outputBefore),
                "output_after": String(change.outputAfter),
                "reset_markers_added": String(change.resetMarkersAdded),
                "reset_markers_removed": String(change.resetMarkersRemoved)
            ])
        }
        return result
    }

    private static func insertResetMarker(
        for run: TaskRun, report: Report?, task: AgentTask, modelContext: ModelContext
    ) -> TaskEvent {
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
        return marker
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
            "sessions_skipped": String(outcome.sessionsSkipped),
            "sessions_deferred": String(outcome.sessionsDeferred)
        ]
        if let error {
            fields["error_type"] = String(describing: type(of: error))
        }
        AppLogger.audit(.dataStoreRecovered, category: "Persistence", fields: fields, level: error == nil ? .info : .error)
    }
}
