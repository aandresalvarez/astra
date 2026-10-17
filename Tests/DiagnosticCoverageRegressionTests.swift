import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Diagnostic evidence coverage")
struct DiagnosticCoverageRegressionTests {
    @Test("Retained feedback logs deduplicate sub-millisecond app and task copies after persistence",
          arguments: [0.123456, 0.99991])
    func retainedCopiesUsePersistedPrecision(fraction: Double) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date(timeIntervalSince1970: 1_800_000_000 + fraction)
        let taskID = UUID(uuidString: "AABBCCDD-1234-4234-8234-123456789ABC")!
        let app = LogEntry(level: .warning, category: "App", message: "older-evidence=kept", timestamp: time)
        let task = LogEntry(level: .error, category: "Worker", message: "worker.timeout reference=終",
            taskID: taskID, timestamp: time)
        try [app, task].map(\.persistedFormatted).joined(separator: "\n")
            .write(to: root.appendingPathComponent("astra.log"), atomically: true, encoding: .utf8)
        try task.persistedFormatted.write(to: root.appendingPathComponent("task-AABBCCDD.log"), atomically: true, encoding: .utf8)
        let retained = FeedbackReportEvidenceSourceReader.retainedLogEntries(inMemoryEntries: [app, task], logDirectory: root)
        #expect(retained.count == 2)
        #expect(retained.map(\.id) == [app.id, task.id], "Prefer complete in-memory records over their persisted copies")
    }

    @Test("Collection preserves distinct milliseconds, messages and task identities")
    func genuineRepeatedEventsRemainEvidence() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date(timeIntervalSince1970: 1_800_000_000.123456)
        let first = LogEntry(level: .error, category: "Worker", message: "worker.timeout",
            taskID: UUID(uuidString: "AABBCCDD-1234-4234-8234-123456789ABC")!, timestamp: time)
        let later = LogEntry(level: .error, category: "Worker", message: first.message, taskID: first.taskID,
            timestamp: time.addingTimeInterval(0.002))
        let otherMessage = LogEntry(level: .error, category: "Worker", message: "worker.failed", taskID: first.taskID, timestamp: time)
        let otherTask = LogEntry(level: .error, category: "Worker", message: first.message,
            taskID: UUID(uuidString: "11223344-1234-4234-8234-123456789ABC")!, timestamp: time)
        try [first, later, otherMessage, otherTask].map(\.persistedFormatted).joined(separator: "\n")
            .write(to: root.appendingPathComponent("astra.log"), atomically: true, encoding: .utf8)
        let result = LogDiagnosticsCollector.collect(inMemory: [first], directory: root, includeAppLogs: true)
        #expect(result.entries.count == 4)
    }

    @Test("Collection covers more than 5000 main lines and more than 30 task logs")
    func collectionDoesNotSilentlyDropOlderSignals() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (0..<6_010).map { "[2026-10-16T20:00:00.000Z] [INFO] [App] sample=\($0)" }
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("astra.log"), atomically: true, encoding: .utf8)
        for index in 0..<35 {
            try "[2026-10-16T20:00:00.000Z] [WARNING] [Worker] task_sample=\(index)"
                .write(to: root.appendingPathComponent("task-\(index).log"), atomically: true, encoding: .utf8)
        }
        let collection = LogDiagnosticsCollector.collect(inMemory: [], directory: root, includeAppLogs: true)
        #expect(collection.entries.count == 6_045)
        #expect(collection.coverage.availableFiles == 36)
        #expect(collection.coverage.sampledFiles == 36)
        #expect(collection.coverage.omittedFiles == 0)
        #expect(collection.coverage.truncatedFiles == 0)
        let report = LogDiagnosticsService.makeReport(entries: [], coverage: collection.coverage)
        #expect(report.markdown.contains("Evidence coverage"))
        #expect(report.markdown.contains("sampled: 36"))
    }

    @Test("An oversized log reports its bounded, incomplete coverage")
    func oversizedLogReportsTruncation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: LogDiagnosticsCollector.maximumFileBytes + 1_024)
            .write(to: root.appendingPathComponent("astra.log"))
        let collection = LogDiagnosticsCollector.collect(inMemory: [], directory: root, includeAppLogs: true)
        #expect(collection.coverage.truncatedFiles == 1)
        #expect(collection.coverage.bytesRead <= LogDiagnosticsCollector.maximumTotalBytes)
        #expect(collection.coverage.markdown.contains("not proof"))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-diagnostics-coverage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
