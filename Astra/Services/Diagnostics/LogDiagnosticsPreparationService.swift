import Foundation
import ASTRACore

struct PreparedLogDiagnostics {
    let report: LogDiagnosticsReport
    let entries: [LogEntry]
    let interval: DateInterval?
    let history: LogDiagnosticsHistory
}

enum LogDiagnosticsPreparationService {
    static func prepare(entries: [LogEntry], scope: LogDiagnosticsScope, generatedAt: Date,
                        directory: URL = AppLogger.mainLogFile.deletingLastPathComponent()) async -> PreparedLogDiagnostics {
        await Task.detached(priority: .userInitiated) {
            let history = LogDiagnosticsService.loadHistory()
            let interval = LogDiagnosticsService.analysisDateInterval(scope: scope,
                generatedAt: generatedAt, previousGeneratedAt: history.lastGeneratedAt)
            let collection = LogDiagnosticsCollector.collect(inMemory: entries, directory: directory,
                includeAppLogs: true, interval: interval)
            let crashes = CrashDiagnosticsService.reports(limit: 50, modifiedIn: interval)
            let analyzed = LogDiagnosticsService.analyzedEntries(collection.entries,
                generatedAt: generatedAt, scope: scope, history: history)
            let report = LogDiagnosticsService.makeReport(entries: collection.entries,
                generatedAt: generatedAt, scope: scope, history: history,
                crashReports: crashes, coverage: collection.coverage)
            return PreparedLogDiagnostics(report: report, entries: analyzed, interval: interval, history: history)
        }.value
    }
}
