import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Diagnostic evidence coverage")
struct DiagnosticCoverageRegressionTests {
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
