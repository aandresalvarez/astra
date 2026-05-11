import Foundation
import Testing
@testable import ASTRA
import ASTRACore

private actor CapabilityDetectorStubRunner: BinaryRunner {
    private var responses: [String: RunResult] = [:]

    func setResponse(_ result: RunResult, for path: String, args: [String]) {
        responses["\(path) \(args.joined(separator: " "))"] = result
    }

    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await response(path: path, args: args)
    }

    private func response(path: String, args: [String]) -> RunResult {
        responses["\(path) \(args.joined(separator: " "))"] ??
        RunResult(outcome: .exited(code: 1), stdout: "", stderr: "")
    }
}

@Suite("Capability Tool Detector")
struct CapabilityToolDetectorTests {
    @Test("known CLI candidate creates a local tool")
    @MainActor
    func knownCandidateCreatesLocalTool() throws {
        let candidate = try #require(CapabilityToolDetector.knownCandidates.first { $0.id == "bq" })

        let tool = CapabilityToolDetector.makeTool(for: candidate)

        #expect(tool.name == "bq - BigQuery CLI")
        #expect(tool.toolType == "cli")
        #expect(tool.command == "bq")
        #expect(tool.icon == "terminal")
    }

    @Test("detect reports healthy and missing CLI candidates")
    func detectKnownCandidates() async throws {
        let runner = CapabilityDetectorStubRunner()
        await runner.setResponse(
            RunResult(outcome: .exited(code: 0), stdout: "/opt/bin/bq\n", stderr: ""),
            for: "/usr/bin/env",
            args: ["which", "bq"]
        )
        await runner.setResponse(
            RunResult(outcome: .exited(code: 0), stdout: "BigQuery CLI 2.0\n", stderr: ""),
            for: "/opt/bin/bq",
            args: ["version"]
        )

        let bq = try #require(CapabilityToolDetector.knownCandidates.first { $0.id == "bq" })
        let gh = try #require(CapabilityToolDetector.knownCandidates.first { $0.id == "gh" })
        let checker = EnvironmentHealthChecker(runner: runner, fallbackDirectories: [])
        let detector = CapabilityToolDetector(checker: checker)

        let statuses = await detector.detect([bq, gh])

        guard case .healthy(let path, let version) = statuses["bq"] else {
            Issue.record("Expected bq to be healthy")
            return
        }
        #expect(path == "/opt/bin/bq")
        #expect(version == "BigQuery CLI 2.0")
        #expect(statuses["gh"] == .missingBinary)
    }

    @Test("known command maps to prerequisite")
    func knownCommandMapsToPrerequisite() throws {
        let prereq = try #require(CapabilityToolDetector.prerequisite(forCommand: "gcloud"))

        #expect(prereq.binary == "gcloud")
        #expect(CapabilityToolDetector.prerequisite(forCommand: "unknown-tool") == nil)
    }
}
