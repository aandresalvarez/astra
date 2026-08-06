import Foundation
import Testing

@Suite("RunBroker reconciliation architecture")
struct RunBrokerReconciliationArchitectureTests {
    @Test("orchestrator rebuilds journal state through the execution index")
    func orchestratorUsesIndexedObservationHistory() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("RunBrokerService/RunBrokerOrchestrator.swift"),
            encoding: .utf8
        )
        let journalState = try #require(source.range(
            of: "private func journalState(executionID: RunBrokerExecutionID)"
        ))
        let nextMethod = try #require(source.range(
            of: "private func observation(",
            range: journalState.upperBound..<source.endIndex
        ))
        let implementation = source[journalState.lowerBound..<nextMethod.lowerBound]

        #expect(implementation.contains("ledger.supervisorObservations(for: executionID)"))
        #expect(!implementation.contains("ledger.events(after:"))
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Package.swift").path
            ), FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Astra").path
            ) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw RunBrokerReconciliationArchitectureError.repositoryRootNotFound
            }
            candidate = parent
        }
    }
}

private enum RunBrokerReconciliationArchitectureError: Error {
    case repositoryRootNotFound
}
