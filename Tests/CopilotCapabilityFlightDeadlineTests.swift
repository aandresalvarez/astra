import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Copilot shared flight deadlines")
struct CopilotCapabilityFlightDeadlineTests {
    private actor QuerySequence {
        var calls = 0
        var first: CheckedContinuation<RunResult, Never>?
        func run() async -> RunResult {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { first = $0 } }
            return .exited(code: 0, stdout: "Usage: copilot --output-format=FORMAT", stderr: "")
        }
        func expireOldFlight() {
            first?.resume(returning: .timedOut(stdout: "", stderr: "", elapsedTime: 60))
            first = nil
        }
    }

    @Test("An old subprocess timeout renews the shared flight for an unexpired subscriber")
    func lateConsumerKeepsOwnBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("copilot").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let sequence = QuerySequence()
        let service = CopilotCapabilityProbe(query: { _ in await sequence.run() })
        let first = Task { try await service.answer(executablePath: path, timeout: 60) }
        defer { first.cancel(); Task { await sequence.expireOldFlight() } }
        for _ in 0..<2_400 {
            if await sequence.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(await sequence.calls == 1)
        let late = Task { try await service.answer(executablePath: path, timeout: 60) }
        defer { late.cancel() }
        for _ in 0..<2_400 {
            if await service.waiterCount(executablePath: path) == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(await service.waiterCount(executablePath: path) == 2)
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled consumer returned") }
        catch { #expect(error is CancellationError) }
        // Model the original process reaching its hang breaker after the new
        // subscriber joined. No sleep or machine-speed assertion is involved.
        await sequence.expireOldFlight()
        #expect(try await late.value.supportsOutputFormatJSON)
        #expect(await sequence.calls == 2)
    }
}
