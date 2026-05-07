import Foundation

struct LogDiagnosticsIssue: Equatable, Identifiable {
    let id: String
    let title: String
    let severity: LogLevel
    let signal: String
    let count: Int
    let affectedTasks: [String]
    let evidence: [String]
    let analysis: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let freshness: LogDiagnosticsFreshness
}

struct LogDiagnosticsNotice: Equatable, Identifiable {
    let id: String
    let title: String
    let signal: String
    let count: Int
    let evidence: [String]
    let analysis: String
    let firstSeenAt: Date
    let lastSeenAt: Date
}

struct LogDiagnosticsReport: Equatable {
    let generatedAt: Date
    let scope: LogDiagnosticsScope
    let analysisStart: Date?
    let analysisEnd: Date?
    let previousGeneratedAt: Date?
    let entryCount: Int
    let errorCount: Int
    let warningCount: Int
    let issueCount: Int
    let issueFingerprints: [String]
    let issues: [LogDiagnosticsIssue]
    let notices: [LogDiagnosticsNotice]
    let markdown: String
}

enum LogDiagnosticsFreshness: String, Codable, Equatable {
    case new
    case recurring
    case old

    var label: String { rawValue }
}

enum LogDiagnosticsScope: String, Codable, CaseIterable, Identifiable {
    case sinceLastReport
    case last15Minutes
    case lastHour
    case today
    case allRetained

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sinceLastReport: "Since last report"
        case .last15Minutes: "Last 15 minutes"
        case .lastHour: "Last hour"
        case .today: "Today"
        case .allRetained: "All retained logs"
        }
    }
}

struct LogDiagnosticsHistory: Equatable {
    var lastGeneratedAt: Date?
    var knownIssueFingerprints: Set<String>

    static let empty = LogDiagnosticsHistory(lastGeneratedAt: nil, knownIssueFingerprints: [])
}

enum LogDiagnosticsService {
    static let maxIssueGroups = 12
    static let maxEvidenceLinesPerIssue = 14
    static let maxMainLogLines = 5_000
    static let maxTaskLogLines = 300
    static let maxTaskLogFiles = 30
    private static let permissionWarningQuietThreshold: TimeInterval = 5 * 60
    private static let historyLastGeneratedAtKey = "astra.diagnostics.history.lastGeneratedAt.v1"
    private static let historyKnownFingerprintsKey = "astra.diagnostics.history.knownFingerprints.v1"

    static func collectCurrentEntries(
        inMemoryEntries: [LogEntry] = AppLogger.entries,
        logDirectory: URL = AppLogger.mainLogFile.deletingLastPathComponent()
    ) -> [LogEntry] {
        var collected = inMemoryEntries
        var seen = Set(inMemoryEntries.map(entrySignature))

        for file in diagnosticLogFiles(in: logDirectory) {
            let isAppLog = isAppLogFile(file)
            if isAppLog, !inMemoryEntries.isEmpty {
                continue
            }
            let maxLines = file.lastPathComponent.hasPrefix("task-") ? maxTaskLogLines : maxMainLogLines
            for line in tailLines(from: file, maxLines: maxLines) {
                guard let entry = parseLogLine(line, dateAnchor: modificationDate(file)) else { continue }
                let signature = entrySignature(entry)
                guard !seen.contains(signature) else { continue }
                seen.insert(signature)
                collected.append(entry)
            }
        }
        return collected
    }

    static func makeReport(
        entries: [LogEntry],
        generatedAt: Date = Date(),
        scope: LogDiagnosticsScope = .allRetained,
        history: LogDiagnosticsHistory = .empty
    ) -> LogDiagnosticsReport {
        let orderedEntries = filteredEntries(
            entries,
            scope: scope,
            generatedAt: generatedAt,
            previousGeneratedAt: history.lastGeneratedAt
        ).sorted { $0.timestamp < $1.timestamp }
        let issueGroups = buildIssueGroups(
            from: orderedEntries,
            generatedAt: generatedAt,
            previousGeneratedAt: history.lastGeneratedAt,
            knownIssueFingerprints: history.knownIssueFingerprints
        )
        let visibleIssues = Array(issueGroups.prefix(maxIssueGroups))
        let notices = buildNotices(from: orderedEntries)
        let markdown = renderMarkdown(
            entries: orderedEntries,
            generatedAt: generatedAt,
            scope: scope,
            previousGeneratedAt: history.lastGeneratedAt,
            issues: visibleIssues,
            notices: notices,
            omittedIssueCount: max(0, issueGroups.count - visibleIssues.count)
        )

        return LogDiagnosticsReport(
            generatedAt: generatedAt,
            scope: scope,
            analysisStart: orderedEntries.first?.timestamp,
            analysisEnd: orderedEntries.last?.timestamp,
            previousGeneratedAt: history.lastGeneratedAt,
            entryCount: orderedEntries.count,
            errorCount: orderedEntries.filter { $0.logLevel == .error }.count,
            warningCount: orderedEntries.filter { $0.logLevel == .warning }.count,
            issueCount: issueGroups.count,
            issueFingerprints: issueGroups.map(\.id).sorted(),
            issues: visibleIssues,
            notices: notices,
            markdown: markdown
        )
    }

    static func filteredEntries(
        _ entries: [LogEntry],
        scope: LogDiagnosticsScope,
        generatedAt: Date = Date(),
        previousGeneratedAt: Date? = nil,
        calendar: Calendar = .current
    ) -> [LogEntry] {
        let start: Date?
        switch scope {
        case .sinceLastReport:
            start = previousGeneratedAt
        case .last15Minutes:
            start = generatedAt.addingTimeInterval(-15 * 60)
        case .lastHour:
            start = generatedAt.addingTimeInterval(-60 * 60)
        case .today:
            start = calendar.startOfDay(for: generatedAt)
        case .allRetained:
            start = nil
        }

        guard let start else { return entries }
        return entries.filter { $0.timestamp >= start && $0.timestamp <= generatedAt }
    }

    static func writeReport(
        _ report: LogDiagnosticsReport,
        directory: URL = defaultDiagnosticsDirectory()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let url = directory.appendingPathComponent("ASTRA-Diagnostics-\(fileTimestamp(report.generatedAt)).md")
        try report.markdown.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func loadHistory(defaults: UserDefaults = .standard) -> LogDiagnosticsHistory {
        let timestamp = defaults.object(forKey: historyLastGeneratedAtKey) as? Double
        let known = defaults.stringArray(forKey: historyKnownFingerprintsKey) ?? []
        return LogDiagnosticsHistory(
            lastGeneratedAt: timestamp.map(Date.init(timeIntervalSince1970:)),
            knownIssueFingerprints: Set(known)
        )
    }

    static func saveHistory(from report: LogDiagnosticsReport, defaults: UserDefaults = .standard) {
        let known = Set(defaults.stringArray(forKey: historyKnownFingerprintsKey) ?? [])
            .union(report.issueFingerprints)
        defaults.set(report.generatedAt.timeIntervalSince1970, forKey: historyLastGeneratedAtKey)
        defaults.set(Array(known).sorted(), forKey: historyKnownFingerprintsKey)
    }

    static func defaultDiagnosticsDirectory() -> URL {
        AppLogger.mainLogFile
            .deletingLastPathComponent()
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private struct IssueBucket {
        let key: String
        var title: String
        var severity: LogLevel
        var signal: String
        var indexes: [Int]
        var affectedTasks: Set<String>
        var analysis: String
    }

    private struct NoticeBucket {
        let key: String
        var title: String
        var signal: String
        var indexes: [Int]
        var analysis: String
    }

    private static func buildIssueGroups(
        from entries: [LogEntry],
        generatedAt: Date,
        previousGeneratedAt: Date?,
        knownIssueFingerprints: Set<String>
    ) -> [LogDiagnosticsIssue] {
        var buckets: [String: IssueBucket] = [:]
        var seenIssueEvents: Set<String> = []

        for (index, entry) in entries.enumerated() {
            if isRecoveredOrPendingPermissionWarning(entry, entries: entries, generatedAt: generatedAt) {
                continue
            }
            if isResolvedPlanBlocker(entry, entries: entries) {
                continue
            }
            if isGenericRuntimeWarningCoveredBySpecificFailure(entry, entries: entries) {
                continue
            }
            if classifyNotice(entry) != nil {
                continue
            }
            guard let classification = classifyConnectorCredentialRegression(
                entry,
                index: index,
                entries: entries
            ) ?? classify(entry) else { continue }
            let signature = diagnosticEventSignature(for: entry, classificationKey: classification.key)
            guard seenIssueEvents.insert(signature).inserted else { continue }
            let task = taskIdentifier(for: entry)
            var bucket = buckets[classification.key] ?? IssueBucket(
                key: classification.key,
                title: classification.title,
                severity: classification.severity,
                signal: classification.signal,
                indexes: [],
                affectedTasks: [],
                analysis: classification.analysis
            )
            bucket.severity = maxSeverity(bucket.severity, classification.severity)
            bucket.indexes.append(index)
            if let task { bucket.affectedTasks.insert(task) }
            buckets[classification.key] = bucket
        }

        return buckets.values
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.indexes.count != rhs.indexes.count { return lhs.indexes.count > rhs.indexes.count }
                return lhs.title < rhs.title
            }
            .map { bucket in
                let firstSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.min() ?? Date(timeIntervalSince1970: 0)
                let lastSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.max() ?? firstSeenAt
                return LogDiagnosticsIssue(
                    id: bucket.key,
                    title: bucket.title,
                    severity: bucket.severity,
                    signal: bucket.signal,
                    count: bucket.indexes.count,
                    affectedTasks: bucket.affectedTasks.sorted(),
                    evidence: evidenceLines(for: bucket.indexes, entries: entries),
                    analysis: issueAnalysis(for: bucket, entries: entries),
                    firstSeenAt: firstSeenAt,
                    lastSeenAt: lastSeenAt,
                    freshness: freshness(
                        key: bucket.key,
                        firstSeenAt: firstSeenAt,
                        lastSeenAt: lastSeenAt,
                        previousGeneratedAt: previousGeneratedAt,
                        knownIssueFingerprints: knownIssueFingerprints
                    )
                )
            }
    }

    private static func buildNotices(from entries: [LogEntry]) -> [LogDiagnosticsNotice] {
        var buckets: [String: NoticeBucket] = [:]
        var seenNoticeEvents: Set<String> = []

        for (index, entry) in entries.enumerated() {
            guard let classification = classifyNotice(entry) else { continue }
            let signature = diagnosticEventSignature(for: entry, classificationKey: classification.key)
            guard seenNoticeEvents.insert(signature).inserted else { continue }
            var bucket = buckets[classification.key] ?? NoticeBucket(
                key: classification.key,
                title: classification.title,
                signal: classification.signal,
                indexes: [],
                analysis: classification.analysis
            )
            bucket.indexes.append(index)
            buckets[classification.key] = bucket
        }

        return buckets.values
            .sorted { lhs, rhs in
                guard lhs.indexes.count == rhs.indexes.count else {
                    return lhs.indexes.count > rhs.indexes.count
                }
                return lhs.title < rhs.title
            }
            .map { bucket in
                let firstSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.min() ?? Date(timeIntervalSince1970: 0)
                let lastSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.max() ?? firstSeenAt
                return LogDiagnosticsNotice(
                    id: bucket.key,
                    title: bucket.title,
                    signal: bucket.signal,
                    count: bucket.indexes.count,
                    evidence: evidenceLines(for: bucket.indexes, entries: entries),
                    analysis: bucket.analysis,
                    firstSeenAt: firstSeenAt,
                    lastSeenAt: lastSeenAt
                )
            }
    }

    private static func freshness(
        key: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        previousGeneratedAt: Date?,
        knownIssueFingerprints: Set<String>
    ) -> LogDiagnosticsFreshness {
        guard let previousGeneratedAt else { return .new }
        if lastSeenAt <= previousGeneratedAt { return .old }
        if firstSeenAt <= previousGeneratedAt || knownIssueFingerprints.contains(key) {
            return .recurring
        }
        return .new
    }

    private static func issueAnalysis(for bucket: IssueBucket, entries: [LogEntry]) -> String {
        guard bucket.key == "worker.budget_exceeded" else {
            return bucket.analysis
        }

        let relatedEntries = entriesForTasks(bucket.affectedTasks, in: entries)
        let persistenceEntries = uniqueEntries(relatedEntries.filter { entry in
            let lower = entry.message.lowercased()
            return lower.contains(AuditEvent.runtimePersistenceSummary.rawValue)
                && field("run_status", in: entry.message) == "budget_exceeded"
        })

        let outputChars = sumIntField("run_output_chars", in: persistenceEntries)
        let fileChanges = sumIntField("file_changes", in: persistenceEntries)
        let savedState = persistenceEntries.contains {
            $0.message.lowercased().contains("result=swiftdata_save_succeeded")
        }

        guard outputChars > 0 || fileChanges > 0 || savedState else {
            return bucket.analysis
        }

        let outputText = outputChars > 0 ? "\(outputChars) visible output character\(outputChars == 1 ? "" : "s")" : "visible output"
        let fileText = fileChanges > 0 ? " and \(fileChanges) file change\(fileChanges == 1 ? "" : "s")" : ""
        let saveText = savedState ? " ASTRA saved the run state successfully." : ""
        return "The task reached its configured budget after producing \(outputText)\(fileText).\(saveText) Resume with a narrower prompt, split the work into smaller tasks, or increase the budget when the broader run is intentional."
    }

    private static func classifyConnectorCredentialRegression(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> (
        key: String,
        title: String,
        severity: LogLevel,
        signal: String,
        analysis: String
    )? {
        let message = entry.message
        let lower = message.lowercased()
        guard lower.contains(AuditEvent.connectorTested.rawValue) else { return nil }
        guard lower.contains("credential_state=rejected")
                || lower.contains("result=auth_failed")
                || lower.contains("http_status=401")
        else { return nil }
        guard let evidenceKey = connectorEvidenceKey(for: entry) else { return nil }
        guard entries.indices.contains(index), index > entries.startIndex else { return nil }

        let hadEarlierAuth = entries[..<index].contains { prior in
            guard connectorEvidenceKey(for: prior) == evidenceKey else { return false }
            let priorLower = prior.message.lowercased()
            guard priorLower.contains(AuditEvent.connectorTested.rawValue) else { return false }
            return priorLower.contains("credential_state=authenticated")
                || priorLower.contains("auth_verified=true")
                || priorLower.contains("result=authenticated")
                || priorLower.contains("result=success")
        }
        guard hadEarlierAuth else { return nil }

        let service = field("service_type", in: message) ?? "connector"
        return (
            key: "connector.tested.auth_regressed.\(evidenceKey)",
            title: "Connector credentials stopped authenticating",
            severity: .error,
            signal: "connector.tested credential_state changed authenticated_to_rejected",
            analysis: "This \(service) connector previously authenticated in the retained logs but later had its credentials rejected. The external token, account access, or auth policy likely changed; rotate or re-enter the credentials and then re-run the connector test."
        )
    }

    private static func connectorEvidenceKey(for entry: LogEntry) -> String? {
        let message = entry.message
        if let connectorID = field("connector_id", in: message), !connectorID.isEmpty {
            return "id:\(connectorID)"
        }
        if let serviceType = field("service_type", in: message), !serviceType.isEmpty {
            return "service:\(serviceType)"
        }
        return nil
    }

    private static func entriesForTasks(_ tasks: Set<String>, in entries: [LogEntry]) -> [LogEntry] {
        guard !tasks.isEmpty else { return [] }
        return entries.filter { entry in
            guard let task = taskIdentifier(for: entry) else { return false }
            return tasks.contains(task)
        }
    }

    private static func uniqueEntries(_ entries: [LogEntry]) -> [LogEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            seen.insert(diagnosticEventSignature(for: entry, classificationKey: "related")).inserted
        }
    }

    private static func sumIntField(_ name: String, in entries: [LogEntry]) -> Int {
        entries.reduce(0) { partial, entry in
            partial + (Int(field(name, in: entry.message) ?? "0") ?? 0)
        }
    }

    private static func isRecoveredOrPendingPermissionWarning(
        _ entry: LogEntry,
        entries: [LogEntry],
        generatedAt: Date
    ) -> Bool {
        let lower = entry.message.lowercased()
        guard lower.contains(AuditEvent.workerPermissionDenied.rawValue) else {
            return false
        }

        guard generatedAt.timeIntervalSince(entry.timestamp) >= permissionWarningQuietThreshold else {
            return true
        }

        guard let task = taskIdentifier(for: entry) else {
            return false
        }

        if entries.contains(where: { candidate in
            candidate.timestamp > entry.timestamp
                && taskIdentifier(for: candidate) == task
                && candidate.message.lowercased().contains(AuditEvent.runtimeProgressState.rawValue)
                && candidate.message.lowercased().contains("state=possibly_stalled")
        }) {
            return true
        }

        return entries.contains { candidate in
            candidate.timestamp > entry.timestamp
                && taskIdentifier(for: candidate) == task
                && isTaskProgressOrCompletionEntry(candidate)
        }
    }

    private static func isTaskProgressOrCompletionEntry(_ entry: LogEntry) -> Bool {
        let lower = entry.message.lowercased()
        if lower.contains(AuditEvent.taskCompleted.rawValue) {
            return true
        }
        if lower.contains(AuditEvent.workerExited.rawValue),
           lower.contains("exit_code=0") {
            return true
        }
        if lower.contains(AuditEvent.runtimePersistenceSummary.rawValue),
           (lower.contains("run_status=completed") || lower.contains("task_status=completed")) {
            return true
        }
        if lower.contains(AuditEvent.runtimeStreamSummary.rawValue) {
            if let outputChars = Int(field("run_output_chars", in: entry.message) ?? "0"), outputChars > 0 {
                return true
            }
            if let textEvents = Int(field("text_events", in: entry.message) ?? "0"), textEvents > 0 {
                return true
            }
            if let toolResults = Int(field("tool_result_events", in: entry.message) ?? "0"), toolResults > 0 {
                return true
            }
        }
        if lower.contains(AuditEvent.taskStats.rawValue) {
            return true
        }
        if lower.contains(AuditEvent.runtimeProgressState.rawValue),
           (lower.contains("state=active") || lower.contains("state=recovered_warning")) {
            return true
        }
        return false
    }

    private static func isResolvedPlanBlocker(_ entry: LogEntry, entries: [LogEntry]) -> Bool {
        let lower = entry.message.lowercased()
        guard lower.contains(AuditEvent.planStepBlocked.rawValue) else {
            return false
        }

        guard let task = taskIdentifier(for: entry) else {
            return false
        }

        let planID = field("plan_id", in: entry.message)
        let stepID = field("step_id", in: entry.message)

        return entries.contains { candidate in
            guard candidate.timestamp > entry.timestamp,
                  taskIdentifier(for: candidate) == task else {
                return false
            }

            let candidateLower = candidate.message.lowercased()
            if candidateLower.contains(AuditEvent.planCancelled.rawValue) ||
                candidateLower.contains(AuditEvent.planExecutionCompleted.rawValue) ||
                candidateLower.contains(AuditEvent.planExecutionFailed.rawValue) ||
                candidateLower.contains(AuditEvent.taskCompleted.rawValue) {
                return samePlan(candidate, planID: planID)
            }

            guard candidateLower.contains(AuditEvent.planStepStateChanged.rawValue) ||
                    candidateLower.contains(TaskPlanEventTypes.stepCompleted) ||
                    candidateLower.contains(TaskPlanEventTypes.stepSkipped) ||
                    candidateLower.contains(TaskPlanEventTypes.stepStarted) else {
                return false
            }

            guard samePlan(candidate, planID: planID), sameStep(candidate, stepID: stepID) else {
                return false
            }

            guard let status = field("step_status", in: candidate.message)
                ?? field("status", in: candidate.message)
            else {
                return false
            }
            return ["done", "skipped", "running"].contains(status)
        }
    }

    private static func isGenericRuntimeWarningCoveredBySpecificFailure(_ entry: LogEntry, entries: [LogEntry]) -> Bool {
        guard entry.logLevel == .warning else { return false }
        let lower = entry.message.lowercased()
        guard lower.contains(AuditEvent.workerExited.rawValue) else { return false }
        guard let task = taskIdentifier(for: entry) else { return false }

        return entries.contains { candidate in
            guard taskIdentifier(for: candidate) == task else { return false }
            let candidateLower = candidate.message.lowercased()
            return candidateLower.contains(AuditEvent.runtimeFailureDiagnostic.rawValue) ||
                candidateLower.contains(AuditEvent.workerTimeout.rawValue) ||
                candidateLower.contains(AuditEvent.workerBudgetExceeded.rawValue)
        }
    }

    private static func samePlan(_ entry: LogEntry, planID: String?) -> Bool {
        guard let planID, !planID.isEmpty else { return true }
        return field("plan_id", in: entry.message) == planID
    }

    private static func sameStep(_ entry: LogEntry, stepID: String?) -> Bool {
        guard let stepID, !stepID.isEmpty else { return true }
        return field("step_id", in: entry.message) == stepID
    }

    private static func classifyNotice(_ entry: LogEntry) -> (
        key: String,
        title: String,
        signal: String,
        analysis: String
    )? {
        let message = entry.message
        let lower = message.lowercased()

        guard lower.contains(AuditEvent.taskInterrupted.rawValue),
              let source = field("source", in: message) else {
            return nil
        }

        switch source {
        case TaskRunInterruptionSource.appRestart.auditSource:
            return (
                key: "task.interrupted.startup_recovery",
                title: "Startup recovered stale running runs",
                signal: "task.interrupted source=startup_recovery",
                analysis: "ASTRA found run records left marked as running from a previous app session and marked those runs interrupted during startup recovery. This is expected after app restarts or local app updates and is not actionable unless paired with new task failures."
            )
        case TaskRunInterruptionSource.supersededByNewRun.auditSource:
            return (
                key: "task.interrupted.superseded_by_new_run",
                title: "Previous run was superseded",
                signal: "task.interrupted source=superseded_by_new_run",
                analysis: "ASTRA interrupted an older run because the user retried or continued the task. This is an expected lifecycle transition and does not indicate a runtime failure by itself."
            )
        default:
            return nil
        }
    }

    private static func classify(_ entry: LogEntry) -> (
        key: String,
        title: String,
        severity: LogLevel,
        signal: String,
        analysis: String
    )? {
        let message = entry.message
        let lower = message.lowercased()

        if lower.contains(AuditEvent.runtimeFailureDiagnostic.rawValue) {
            let category = field("failure_category", in: message) ?? "unknown"
            return (
                key: "runtime.failure_diagnostic.\(category)",
                title: runtimeFailureTitle(category),
                severity: .error,
                signal: "runtime.failure_diagnostic failure_category=\(category)",
                analysis: runtimeFailureAnalysis(category)
            )
        }

        if lower.contains(AuditEvent.runtimeProgressState.rawValue),
           lower.contains("state=possibly_stalled") {
            return (
                key: "runtime.progress_state.possibly_stalled",
                title: "Running task may be stalled",
                severity: .warning,
                signal: "runtime.progress_state state=possibly_stalled",
                analysis: "ASTRA still sees the task as running, but no output, tool result, or file-change progress arrived after a permission warning for at least five minutes. Check whether the provider is waiting for input or a tool permission change."
            )
        }

        if lower.contains(AuditEvent.workerPermissionDenied.rawValue) {
            let tool = field("tool", in: message) ?? "unknown"
            return (
                key: "worker.permission_denied.\(tool)",
                title: "Runtime permission warning needs follow-up",
                severity: .warning,
                signal: "worker.permission_denied tool=\(tool)",
                analysis: "A tool permission warning was emitted and no later progress or completion signal was found in the analyzed window after the five-minute quiet threshold. Review the task log to see whether the agent is waiting for approval or should be retried with different tools."
            )
        }

        if lower.contains(AuditEvent.planStepBlocked.rawValue) {
            let stepID = field("step_id", in: message) ?? "unknown"
            return (
                key: "plan.step.blocked.\(stepID)",
                title: "Plan execution is blocked",
                severity: .warning,
                signal: "plan.step.blocked step_id=\(stepID)",
                analysis: "A plan step reported a blocker and no later step progress, plan cancellation, or task completion resolved it in the analyzed window. Review the plan panel for the blocked step and decide whether to approve, edit, skip, or cancel the remaining work."
            )
        }

        if lower.contains(AuditEvent.runtimeEmptyOutput.rawValue) {
            return (
                key: "runtime.empty_output",
                title: "Runtime returned no visible response",
                severity: .warning,
                signal: AuditEvent.runtimeEmptyOutput.rawValue,
                analysis: "The runtime exited successfully or produced stream events, but ASTRA did not receive visible assistant text. Check provider event parsing, output format flags, and the raw stream counters nearby."
            )
        }

        if lower.contains(AuditEvent.runtimeUnknownEvent.rawValue) {
            let eventType = field("event_type", in: message) ?? "unknown"
            return (
                key: "runtime.unknown_event.\(eventType)",
                title: "Unparsed provider stream event",
                severity: .warning,
                signal: "runtime.unknown_event event_type=\(eventType)",
                analysis: "The provider emitted a stream event shape ASTRA did not fully understand. Update the runtime parser if this event carries visible output, tool activity, usage, or failure details."
            )
        }

        if lower.contains(AuditEvent.diagnosticsGenerated.rawValue) {
            return nil
        }

        if lower.contains(AuditEvent.diagnosticsGenerationFailed.rawValue) {
            return (
                key: "diagnostics.generation_failed",
                title: "Diagnostics report generation failed",
                severity: .error,
                signal: AuditEvent.diagnosticsGenerationFailed.rawValue,
                analysis: "The diagnostics report could not be written or revealed. Check the sanitized error field and the app log directory permissions."
            )
        }

        if lower.contains(AuditEvent.workspaceExported.rawValue),
           lower.contains("auto_export_failed") {
            let reason = field("reason", in: message)
            return (
                key: "workspace.export.auto_export_failed.\(reason ?? "write_failed")",
                title: "Workspace auto-export failed",
                severity: .error,
                signal: "workspace.exported result=auto_export_failed",
                analysis: "ASTRA saved workspace state in SwiftData but could not write the recovery config file into the workspace folder. Check the parent path, write permissions, and the error_domain/error_code fields in the extract."
            )
        }

        if lower.contains(AuditEvent.connectorTested.rawValue) {
            if lower.contains("result=preflight_failed") {
                return (
                    key: "connector.tested.preflight_failed",
                    title: "Connector preflight blocked task launch",
                    severity: .error,
                    signal: "connector.tested result=preflight_failed",
                    analysis: "ASTRA stopped the task before launching the agent because a required connector did not pass its own auth or permission check. Fix the connector configuration, then retry the task."
                )
            }
            if lower.contains("missing_count=") {
                return (
                    key: "connector.tested.missing_credentials",
                    title: "Connector configuration is incomplete",
                    severity: .warning,
                    signal: "connector.tested missing_count",
                    analysis: "A configured connector was tested before all required credential fields were available. The user needs to complete the connector configuration before this capability can be used."
                )
            }
            if lower.contains("result=project_not_visible") {
                return (
                    key: "connector.tested.jira_project_not_visible",
                    title: "Jira project is not visible",
                    severity: .warning,
                    signal: "connector.tested result=project_not_visible",
                    analysis: "Jira accepted the connector credentials, but at least one configured project was not visible or the project key is wrong. Check project membership, Browse Projects permission, and the configured project keys."
                )
            }
            if lower.contains("result=missing_permission") {
                let permission = field("permission", in: message) ?? "required permission"
                return (
                    key: "connector.tested.missing_permission.\(permission)",
                    title: "Connector authenticated but lacks permission",
                    severity: .warning,
                    signal: "connector.tested result=missing_permission",
                    analysis: "The connector authenticated successfully, but the account lacks \(permission). Grant the permission in the external service instead of rotating the token."
                )
            }
            if lower.contains("result=endpoint_scope_failure") {
                return (
                    key: "connector.tested.endpoint_scope_failure",
                    title: "Connector auth probe needs scope or endpoint review",
                    severity: .warning,
                    signal: "connector.tested result=endpoint_scope_failure",
                    analysis: "A connector credential probe was rejected, but the evidence is not enough to call the token invalid. Check scoped-token support, service-account auth mode, gateway URL requirements, and endpoint-specific scopes."
                )
            }
            if lower.contains("http_status=401") || lower.contains("unauthorized") {
                return (
                    key: "connector.tested.unauthorized",
                    title: "Connector credentials were rejected",
                    severity: .warning,
                    signal: "connector.tested http_status=401",
                    analysis: "A connector reached its service, but the service rejected the credentials. Re-enter or refresh the token for the affected connector."
                )
            }
        }

        if lower.contains(AuditEvent.workspaceStoreBackedUp.rawValue) {
            if lower.contains("result=failed") {
                return (
                    key: "workspace.store_backup.failed",
                    title: "Workspace store backup failed",
                    severity: .error,
                    signal: AuditEvent.workspaceStoreBackedUp.rawValue,
                    analysis: "ASTRA attempted to back up the SwiftData store during recovery but could not move one or more store files. Check the error fields and application support directory permissions."
                )
            }
            return nil
        }

        if lower.contains(AuditEvent.workspaceRecovered.rawValue) {
            return nil
        }

        if lower.contains(AuditEvent.workspaceRecoveryFailed.rawValue) {
            return (
                key: "workspace.recovery.failed",
                title: "Workspace recovery failed",
                severity: .error,
                signal: AuditEvent.workspaceRecoveryFailed.rawValue,
                analysis: "ASTRA found a workspace recovery config but could not import or save it. Check the config filename and error fields in the nearby log extract."
            )
        }

        if lower.contains(AuditEvent.dataStoreRecovered.rawValue) {
            if lower.contains("stage=") {
                return (
                    key: "data_store.recovered",
                    title: "SwiftData store was recovered",
                    severity: entry.logLevel,
                    signal: AuditEvent.dataStoreRecovered.rawValue,
                    analysis: "The initial SwiftData container open failed, so ASTRA backed up the old store and recreated the model container. Confirm the recovered workspaces and inspect the captured error fields."
                )
            }
            return nil
        }

        if lower.contains(AuditEvent.specExtractionFailed.rawValue),
           lower.contains("operation=title_generation") {
            guard entry.logLevel != .debug,
                  field("result", in: message) != "candidate_failed" else {
                return nil
            }
            return (
                key: "spec.title_generation.failed",
                title: "Thread title generation failed",
                severity: entry.logLevel,
                signal: "spec.extraction_failed operation=title_generation",
                analysis: "The optional title-generation helper failed after trying its model candidates. The task can still run, but check the model and error_summary fields if title backfill keeps failing."
            )
        }

        let isRuntimePersistenceTimeout = lower.contains(AuditEvent.runtimePersistenceSummary.rawValue)
            && (field("run_status", in: message) == "timeout"
                || field("run_stop_reason", in: message)?.contains("timeout") == true)
        if lower.contains(AuditEvent.workerTimeout.rawValue) || isRuntimePersistenceTimeout {
            return (
                key: "worker.timeout",
                title: "Runtime timeout",
                severity: entry.logLevel == .error ? .error : .warning,
                signal: "timeout",
                analysis: "The task stopped after a timeout or network wait. Check whether the provider produced output before the idle timeout and whether the workspace command hung."
            )
        }

        if lower.contains(AuditEvent.workerBudgetExceeded.rawValue) || lower.contains("budget.exceeded") {
            return (
                key: "worker.budget_exceeded",
                title: "Task budget exceeded",
                severity: .warning,
                signal: "budget_exceeded",
                analysis: "The task exceeded a configured token, turn, or repetition budget. This is usually a guardrail trigger rather than a crash."
            )
        }

        if lower.contains(AuditEvent.isolationFailed.rawValue) {
            return (
                key: "isolation.failed",
                title: "Workspace isolation failed",
                severity: .error,
                signal: AuditEvent.isolationFailed.rawValue,
                analysis: "ASTRA could not prepare the requested execution workspace. Check source paths, permissions, and isolation strategy."
            )
        }

        if lower.contains("keychain.") && lower.contains("failed") {
            return (
                key: "keychain.failed",
                title: "Keychain operation failed",
                severity: .error,
                signal: "keychain.failed",
                analysis: "A credential save/delete/read path failed. Check macOS Keychain access, app channel identity, and whether the credential item is locked or malformed."
            )
        }

        if lower.contains(AuditEvent.appUpdateBlocked.rawValue) {
            return (
                key: "app_update.blocked",
                title: "App update was blocked",
                severity: .warning,
                signal: AuditEvent.appUpdateBlocked.rawValue,
                analysis: "The updater refused to install because safety checks were not satisfied. Check the blocked reason and update channel/build metadata."
            )
        }

        if lower.contains(AuditEvent.taskFailed.rawValue) {
            return (
                key: "task.failed",
                title: "Task failed",
                severity: maxSeverity(entry.logLevel, .warning),
                signal: AuditEvent.taskFailed.rawValue,
                analysis: "A task entered a failed state. Check the same task ID for runtime, workspace, capability, and persistence events immediately before this line."
            )
        }

        if entry.logLevel == .error {
            return (
                key: "error.\(messagePrefix(message))",
                title: "Application error",
                severity: .error,
                signal: messagePrefix(message),
                analysis: "A generic error-level log was emitted. Review the surrounding context for the failing subsystem and task ID."
            )
        }

        if entry.logLevel == .warning {
            return (
                key: "warning.\(messagePrefix(message))",
                title: "Application warning",
                severity: .warning,
                signal: messagePrefix(message),
                analysis: "A warning-level log was emitted. Review whether it corresponds to a recoverable condition or a user-visible behavior."
            )
        }

        return nil
    }

    private static func evidenceLines(for indexes: [Int], entries: [LogEntry]) -> [String] {
        var selected = Set<Int>()
        for index in indexes.prefix(5) {
            guard entries.indices.contains(index) else { continue }
            let issueTask = taskIdentifier(for: entries[index])
            let issueCategory = entries[index].category
            for offset in -2...2 {
                let candidate = index + offset
                guard entries.indices.contains(candidate) else { continue }
                if let issueTask {
                    guard taskIdentifier(for: entries[candidate]) == issueTask else { continue }
                } else if entries[candidate].category != issueCategory {
                    continue
                }
                selected.insert(candidate)
            }
        }
        var seenLines: Set<String> = []
        return selected
            .sorted()
            .prefix(maxEvidenceLinesPerIssue)
            .compactMap { index in
                let entry = entries[index]
                let signature = diagnosticEventSignature(for: entry, classificationKey: "evidence")
                guard seenLines.insert(signature).inserted else { return nil }
                return sanitizedLine(entry)
            }
    }

    private static func renderMarkdown(
        entries: [LogEntry],
        generatedAt: Date,
        scope: LogDiagnosticsScope,
        previousGeneratedAt: Date?,
        issues: [LogDiagnosticsIssue],
        notices: [LogDiagnosticsNotice],
        omittedIssueCount: Int
    ) -> String {
        let errors = entries.filter { $0.logLevel == .error }.count
        let warnings = entries.filter { $0.logLevel == .warning }.count
        let tasksSeen = Set(entries.compactMap(taskIdentifier(for:))).sorted()
        let issueTaskIDs = Set(issues.flatMap(\.affectedTasks)).sorted()
        let otherTaskIDs = tasksSeen.filter { !issueTaskIDs.contains($0) }
        let categories = Dictionary(grouping: entries, by: \.category)
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(10)
            .map { "- \($0.key): \($0.value)" }
            .joined(separator: "\n")

        var lines: [String] = [
            "# ASTRA Diagnostics Report",
            "",
            "Generated: \(displayTimestamp(generatedAt))",
            "App channel: \(AppChannel.current.displayName)",
            "Log directory: \(LogSanitizer.sanitize(AppLogger.mainLogFile.deletingLastPathComponent().path))",
            "Scope: \(scope.label)",
            "Previous diagnostics: \(previousGeneratedAt.map(displayTimestamp) ?? "none")",
            "Analyzed window: \(analysisWindow(entries: entries))",
            "",
            "## Summary",
            "",
            "- Entries analyzed: \(entries.count)",
            "- Errors: \(errors)",
            "- Warnings: \(warnings)",
            "- Issue groups: \(issues.count + omittedIssueCount)",
            "- Resolved / non-actionable events: \(notices.count)",
            "- Tasks with issues: \(issueTaskIDs.isEmpty ? "none" : issueTaskIDs.joined(separator: ", "))",
            "- Other tasks seen: \(otherTaskIDs.isEmpty ? "none" : otherTaskIDs.joined(separator: ", "))",
            "",
            "## Category Counts",
            "",
            categories.isEmpty ? "- none" : categories,
            "",
            "## Issues"
        ]

        if issues.isEmpty {
            lines += [
                "",
                "No actionable issue signals were found in the analyzed log buffer."
            ]
            appendNotices(notices, to: &lines)
            lines += [
                "",
                "## Developer Notes",
                "",
                warnings > 0 || errors > 0
                    ? "The report contains warning/error log lines, but diagnostics classified them as resolved or non-actionable for this scope."
                    : "The generated report is still useful as a point-in-time summary, but it did not detect actionable issue signals."
            ]
            return lines.joined(separator: "\n") + "\n"
        }

        for (index, issue) in issues.enumerated() {
            lines += [
                "",
                "### \(index + 1). \(issue.title)",
                "",
                "- Severity: \(issue.severity.rawValue)",
                "- Signal: `\(issue.signal)`",
                "- Freshness: \(issue.freshness.label)",
                "- Count: \(issue.count)",
                "- First seen in window: \(displayTimestamp(issue.firstSeenAt))",
                "- Last seen in window: \(displayTimestamp(issue.lastSeenAt))",
                "- Affected tasks: \(issue.affectedTasks.isEmpty ? "none" : issue.affectedTasks.joined(separator: ", "))",
                "",
                "Analysis: \(issue.analysis)",
                "",
                "Relevant log extract:",
                "",
                "```text"
            ]
            lines += issue.evidence
            lines += ["```"]
        }

        if omittedIssueCount > 0 {
            lines += [
                "",
                "Additional issue groups omitted from this report: \(omittedIssueCount). Narrow logs by task ID or time window if more detail is needed."
            ]
        }

        appendNotices(notices, to: &lines)

        lines += [
            "",
            "## Developer Checklist",
            "",
            "- Start with `runtime.failure_diagnostic` entries when present; they include classified provider failures and redacted stderr summaries.",
            "- Use the affected task IDs to open the matching `task-*.log` file for complete task-local context.",
            "- If `runtime.unknown_event` appears, compare the sample shape against the runtime parser before assuming the provider returned no output.",
            "- If the report shows no provider error summary, verify pipe-drain behavior and whether the CLI wrote errors outside stderr/stdout."
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendNotices(_ notices: [LogDiagnosticsNotice], to lines: inout [String]) {
        guard !notices.isEmpty else { return }
        lines += [
            "",
            "## Resolved / Non-Actionable Events"
        ]
        for notice in notices {
            lines += [
                "",
                "### \(notice.title)",
                "",
                "- Signal: `\(notice.signal)`",
                "- Count: \(notice.count)",
                "- First seen in window: \(displayTimestamp(notice.firstSeenAt))",
                "- Last seen in window: \(displayTimestamp(notice.lastSeenAt))",
                "",
                "Analysis: \(notice.analysis)",
                "",
                "Relevant log extract:",
                "",
                "```text"
            ]
            lines += notice.evidence
            lines += ["```"]
        }
    }

    private static func analysisWindow(entries: [LogEntry]) -> String {
        guard let first = entries.first?.timestamp, let last = entries.last?.timestamp else {
            return "no matching log entries"
        }
        return "\(displayTimestamp(first)) to \(displayTimestamp(last))"
    }

    private static func runtimeFailureTitle(_ category: String) -> String {
        switch category {
        case "authentication_failed": "Runtime authentication failed"
        case "model_unavailable": "Selected model unavailable"
        case "quota_exceeded": "Provider quota exceeded"
        case "rate_limited": "Provider rate limited the request"
        case "provider_configuration_invalid": "Provider configuration invalid"
        case "permission_denied": "Runtime permission approval blocked"
        case "unsupported_output_format": "Runtime output format unsupported"
        case "network_failed": "Provider network failure"
        case "runtime_timed_out": "Runtime timed out"
        case "budget_exceeded": "Runtime budget exceeded"
        case "no_visible_output": "Runtime returned no visible output"
        default: "Runtime provider failed"
        }
    }

    private static func runtimeFailureAnalysis(_ category: String) -> String {
        switch category {
        case "model_unavailable":
            "The runtime launched, but the selected model was rejected or unavailable for the user's account, organization policy, CLI version, quota tier, or provider configuration. This is not evidence that the model is globally invalid."
        case "authentication_failed":
            "The runtime could not authenticate with the provider. Re-run the provider login flow or verify configured tokens for this app channel."
        case "provider_configuration_invalid":
            "The provider path is configured but incomplete or invalid. Check BYOK/base URL/deployment/API key settings without exposing secret values."
        case "permission_denied":
            "The runtime was blocked by provider policy, organization policy, or an interactive CLI approval prompt. Check the redacted error summary for denied tools or workspace paths; this should surface quickly instead of waiting for the idle timeout."
        case "quota_exceeded", "rate_limited":
            "The provider accepted the runtime request path but refused service due to account limits. Retrying with the same model may continue to fail until the limit resets or billing/config changes."
        case "unsupported_output_format":
            "The CLI did not accept the flags ASTRA uses to stream structured output. Check CLI version and capability detection."
        case "no_visible_output":
            "The provider process produced no visible assistant response. Check stderr summary, raw stream counters, and unknown event samples."
        default:
            "The provider process failed. Use the redacted error summary and surrounding stream counters to identify whether this is auth, model, quota, parser, or process-level failure."
        }
    }

    private static func field(_ name: String, in message: String) -> String? {
        let prefix = "\(name)="
        guard let range = message.range(of: prefix) else { return nil }
        let remainder = message[range.upperBound...]
        let value = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        return value.map(String.init)
    }

    private static func taskIdentifier(for entry: LogEntry) -> String? {
        if let taskID = entry.taskID {
            return String(taskID.uuidString.prefix(8))
        }
        return field("task_short", in: entry.message)
    }

    private static func diagnosticEventSignature(for entry: LogEntry, classificationKey: String) -> String {
        let timestampSecond = Int(entry.timestamp.timeIntervalSince1970)
        let task = taskIdentifier(for: entry) ?? "none"
        return [
            classificationKey,
            entry.logLevel.rawValue,
            entry.category,
            task,
            String(timestampSecond),
            canonicalMessage(entry.message)
        ].joined(separator: "|")
    }

    private static func canonicalMessage(_ message: String) -> String {
        let withoutTaskPrefix: Substring
        if message.hasPrefix("task_short=") {
            let pieces = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            withoutTaskPrefix = pieces.count > 1 ? pieces[1] : ""
        } else {
            withoutTaskPrefix = Substring(message)
        }
        return withoutTaskPrefix
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func messagePrefix(_ message: String) -> String {
        let normalized: Substring
        if message.hasPrefix("task_short=") {
            let pieces = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            normalized = pieces.count > 1 ? pieces[1] : ""
        } else {
            normalized = Substring(message)
        }
        let first = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        return first.map(String.init) ?? "unknown"
    }

    static func parseLogLine(_ line: String, dateAnchor: Date = Date()) -> LogEntry? {
        let pattern = #"^\[([0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?)\]\s+\[([A-Z]+)\]\s+\[([^\]]+)\]\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              match.numberOfRanges == 5,
              let timestampRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let categoryRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line) else {
            return nil
        }

        let timestamp = logTimestamp(String(line[timestampRange]), anchoredTo: dateAnchor)
        let levelText = String(line[levelRange]).lowercased()
        let level = LogLevel(rawValue: levelText) ?? .info
        let categoryParts = String(line[categoryRange]).split(separator: " ")
        let category = categoryParts.first.map(String.init) ?? "General"
        let taskShort = categoryParts
            .first { $0.hasPrefix("task:") }
            .map { String($0.dropFirst("task:".count)) }
        let message = String(line[messageRange])
        let messageWithTask = taskShort.map { "task_short=\($0) \(message)" } ?? message
        return LogEntry(
            level: level,
            category: category,
            message: messageWithTask,
            timestamp: timestamp
        )
    }

    private static func diagnosticLogFiles(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }

        let mainLogs = files
            .filter { file in
                let name = file.lastPathComponent
                return name == "astra.log" || (name.hasPrefix("astra.") && name.hasSuffix(".log"))
            }
            .sorted { modificationDate($0) > modificationDate($1) }

        let taskLogs = files
            .filter { $0.lastPathComponent.hasPrefix("task-") && $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }
            .prefix(maxTaskLogFiles)

        return mainLogs + Array(taskLogs)
    }

    private static func isAppLogFile(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        return name == "astra.log" || (name.hasPrefix("astra.") && name.hasSuffix(".log"))
    }

    private static func tailLines(from url: URL, maxLines: Int) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return lines }
        return Array(lines.suffix(maxLines))
    }

    private static func entrySignature(_ entry: LogEntry) -> String {
        "\(entry.level)|\(entry.category)|\(entry.taskID?.uuidString ?? "none")|\(entry.message)"
    }

    private static func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private static func logTimestamp(_ timeText: String, anchoredTo date: Date) -> Date {
        let pieces = timeText.split(separator: ":")
        guard pieces.count == 3,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]) else {
            return date
        }

        let secondPieces = pieces[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let second = Int(secondPieces[0]) else { return date }
        let milliseconds = secondPieces.count > 1 ? Int(secondPieces[1].prefix(3)) ?? 0 : 0

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = milliseconds * 1_000_000
        return Calendar.current.date(from: components) ?? date
    }

    private static func sanitizedLine(_ entry: LogEntry) -> String {
        let task = entry.taskID.map { " task:\(String($0.uuidString.prefix(8)))" } ?? ""
        let line = "[\(displayTimestamp(entry.timestamp))] [\(entry.level.uppercased())] [\(entry.category)\(task)] \(entry.message)"
        return LogSanitizer.sanitize(line, maxLength: 1_000)
    }

    private static func maxSeverity(_ lhs: LogLevel, _ rhs: LogLevel) -> LogLevel {
        lhs > rhs ? lhs : rhs
    }

    private static func displayTimestamp(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        fileFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
