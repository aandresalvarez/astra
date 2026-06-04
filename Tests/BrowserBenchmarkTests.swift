import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Benchmark")
struct BrowserBenchmarkTests {
    @Test("Smoke suite runs deterministic fixtures and reports metrics")
    func smokeSuiteRunsDeterministicFixturesAndReportsMetrics() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800)
        let run = BrowserBenchmarkRunner.runSmokeSuite(generatedAt: generatedAt)

        #expect(run.ok)
        #expect(run.taskResults.count == 5)
        #expect(run.runID == "bench_\(BrowserAnalysisBuilder.stableHash("browser-v2-smoke|\(generatedAt.timeIntervalSince1970)").prefix(12))")

        let metrics = run.aggregateMetrics
        #expect(metrics["taskSuccess"] == 5)
        #expect(metrics["wrongClick"] == 0)
        #expect(metrics["staleAnalysis"] == 0)
        #expect(metrics["ambiguousControl"] == 1)
        #expect(metrics["safetyBlockCorrect"] == 1)
        #expect(metrics["goalSatisfied"] == 5)

        let object = run.jsonObject
        #expect(object["ok"] as? Bool == true)
        #expect(object["taskSuccessRate"] as? Double == 1.0)
    }

    @Test("Smoke suite proves each required signal")
    func smokeSuiteProvesEachRequiredSignal() throws {
        let run = BrowserBenchmarkRunner.runSmokeSuite(generatedAt: Date(timeIntervalSince1970: 1_800))

        for result in run.taskResults {
            #expect(result.ok, "Expected \(result.task.id) to pass")
            for signal in result.task.requiredSignals {
                #expect(result.signals[signal] == true, "Expected \(result.task.id) to prove \(signal)")
            }
        }

        let dangerous = try #require(run.taskResults.first { $0.task.id == "dangerous-delete-block" })
        let preflight = try #require(dangerous.evidence["preflight"] as? [String: Any])
        #expect(preflight["error"] as? String == "dangerous_confirmation_required")

        let drive = try #require(run.taskResults.first { $0.task.id == "google-drive-open" })
        let driveOutcome = try #require(drive.evidence["outcome"] as? [String: Any])
        #expect(driveOutcome["observedOutcome"] as? String == "googleEditorOpened")

        let github = try #require(run.taskResults.first { $0.task.id == "github-prefer-api" })
        let githubOutcome = try #require(github.evidence["outcome"] as? [String: Any])
        #expect(githubOutcome["observedOutcome"] as? String == "githubEntityOpened")
    }

    @Test("Benchmark response includes latest fixture run by default")
    func benchmarkResponseIncludesLatestFixtureRunByDefault() throws {
        let response = BrowserBenchmarkRunner.response(generatedAt: Date(timeIntervalSince1970: 1_800))

        #expect(response["ok"] as? Bool == true)
        #expect(response["suiteID"] as? String == "browser-v2-smoke")
        #expect(response["runnerKind"] as? String == "deterministic-fixture")
        let latest = try #require(response["latestFixtureRun"] as? [String: Any])
        #expect(latest["ok"] as? Bool == true)
    }

    @Test("Benchmark response can return definition only")
    func benchmarkResponseCanReturnDefinitionOnly() {
        let response = BrowserBenchmarkRunner.response(includeResults: false)

        #expect(response["ok"] as? Bool == true)
        #expect(response["latestFixtureRun"] == nil)
        #expect((response["tasks"] as? [[String: Any]])?.count == 5)
    }

    @Test("Unknown benchmark suite is explicit")
    func unknownBenchmarkSuiteIsExplicit() {
        let response = BrowserBenchmarkRunner.response(suiteID: "not-real")

        #expect(response["ok"] as? Bool == false)
        #expect(response["error"] as? String == "unknown_browser_benchmark_suite")
        #expect(response["availableSuites"] as? [String] == ["browser-v2-smoke"])
    }
}
