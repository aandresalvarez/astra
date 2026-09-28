import Testing
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeLaunchReadinessContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func readinessConfiguration(
    _ runtime: AgentRuntimeID = .antigravityCLI,
    authMode: AntigravityAuthMode = .adc,
    executablePath: String = "/opt/agy"
) -> RuntimeReadinessConfiguration {
    var settings = AgentRuntimeProviderSettings()
    settings.setExecutablePath(executablePath, for: runtime)
    return RuntimeReadinessConfiguration(
        runtime: runtime,
        providerSettings: settings,
        claudeProvider: .anthropic,
        vertexProjectID: "",
        vertexRegion: "",
        vertexOpusModel: "",
        vertexSonnetModel: "",
        vertexHaikuModel: "",
        antigravityAuthMode: authMode
    )
}

private func report(_ state: RuntimeReadinessState) -> RuntimeReadinessReport {
    RuntimeReadinessReport(checks: [
        RuntimeReadinessCheck(id: "account", title: "Account", detail: "detail", state: state, remediation: nil)
    ])
}

@Suite("Runtime launch readiness cache")
struct RuntimeLaunchReadinessCacheTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("A ready verdict is served for the same configuration until it ages out")
    func readyVerdictIsServedUntilItAgesOut() async {
        let cache = RuntimeLaunchReadinessCache()
        await cache.record(report(.ready), for: readinessConfiguration(), now: start)

        let fresh = await cache.hit(for: readinessConfiguration(), maxAge: 300, now: start.addingTimeInterval(120))
        #expect(fresh?.report == report(.ready))
        #expect(fresh?.age == 120)
        #expect(await cache.hit(for: readinessConfiguration(), maxAge: 300, now: start.addingTimeInterval(301)) == nil)
    }

    @Test("Changing the auth route, the binary, or the runtime is a miss")
    func changedInputsMiss() async {
        let cache = RuntimeLaunchReadinessCache()
        await cache.record(report(.ready), for: readinessConfiguration(), now: start)

        #expect(await cache.hit(for: readinessConfiguration(authMode: .consumer), now: start) == nil)
        #expect(await cache.hit(for: readinessConfiguration(executablePath: "/opt/other/agy"), now: start) == nil)
        #expect(await cache.hit(for: readinessConfiguration(.claudeCode), now: start) == nil)
        #expect(await cache.hit(for: readinessConfiguration(), now: start) != nil)
    }

    /// An unanswered probe is not proof and a block is a problem; replaying
    /// either, or letting an old pass outlive a newer non-pass, would hide a
    /// fix the user just made.
    @Test("Only a fully ready report is remembered, and anything else forgets the last one")
    func onlyReadyIsRemembered() async {
        let cache = RuntimeLaunchReadinessCache()

        await cache.record(report(.warning), for: readinessConfiguration(), now: start)
        #expect(await cache.hit(for: readinessConfiguration(), now: start) == nil)
        await cache.record(report(.blocked), for: readinessConfiguration(), now: start)
        #expect(await cache.hit(for: readinessConfiguration(), now: start) == nil)

        await cache.record(report(.ready), for: readinessConfiguration(), now: start)
        #expect(await cache.hit(for: readinessConfiguration(), now: start) != nil)
        await cache.record(report(.warning), for: readinessConfiguration(), now: start.addingTimeInterval(1))
        #expect(await cache.hit(for: readinessConfiguration(), now: start.addingTimeInterval(1)) == nil)
    }

    @Test("Each runtime keeps its own verdict")
    func verdictsAreKeyedPerRuntime() async {
        let cache = RuntimeLaunchReadinessCache()
        await cache.record(report(.ready), for: readinessConfiguration(.antigravityCLI), now: start)
        await cache.record(report(.blocked), for: readinessConfiguration(.claudeCode), now: start)

        #expect(await cache.hit(for: readinessConfiguration(.antigravityCLI), now: start) != nil)
        #expect(await cache.hit(for: readinessConfiguration(.claudeCode), now: start) == nil)
    }
}

/// The launch preflight is where the cache earns its keep: a follow-up turn
/// seconds after a passing one must not re-run the probe.
@Suite("Launch readiness preflight uses the verdict cache")
@MainActor
struct LaunchReadinessPreflightCacheTests {
    private struct Fixture {
        let container: ModelContainer
        let task: AgentTask
        let run: TaskRun
    }

    private func fixture() throws -> Fixture {
        let container = try makeLaunchReadinessContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Readiness", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(title: "Ask", goal: "ask", workspace: workspace, runtime: .antigravityCLI)
        task.status = .running
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        return Fixture(container: container, task: task, run: run)
    }

    /// A service whose only probe answers `--version` and the live account
    /// check, counting how many times the CLI is actually spawned.
    private func service(
        _ runner: StubBinaryRunner,
        live: RunResult = RunResult(outcome: .exited(code: 0), stdout: "ASTRA_READY\n", stderr: "")
    ) async -> RuntimeReadinessService {
        await runner.setResponse(
            forKey: "/opt/agy --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.2\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/agy --print Reply with ASTRA_READY only. --print-timeout 25s --sandbox",
            result: live
        )
        return RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "/opt/agy" },
            isExecutable: { _ in true }
        )
    }

    private func launch(
        _ fixture: Fixture,
        service: RuntimeReadinessService,
        cache: RuntimeLaunchReadinessCache?
    ) async -> Bool {
        await AgentRuntimeLaunchPreflight.preflightRuntimeReadinessBeforeLaunch(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            phase: "resume",
            configuration: readinessConfiguration(),
            readinessService: service,
            verdictCache: cache
        )
    }

    @Test("A second launch inside the window is answered from the cache without spawning the CLI")
    func secondLaunchIsServedFromCache() async throws {
        let fixture = try fixture()
        let runner = StubBinaryRunner()
        let service = await service(runner)
        let cache = RuntimeLaunchReadinessCache()

        #expect(await launch(fixture, service: service, cache: cache))
        let firstCalls = await runner.recordedCalls().count
        #expect(firstCalls == 2)

        #expect(await launch(fixture, service: service, cache: cache))
        #expect(await runner.recordedCalls().count == firstCalls)
    }

    /// The process-global-leak rule: a default must never cache, or one test
    /// inherits another's verdict for an identical configuration.
    @Test("Without a cache passed in, every launch probes")
    func noCacheMeansEveryLaunchProbes() async throws {
        let fixture = try fixture()
        let runner = StubBinaryRunner()
        let service = await service(runner)

        #expect(await launch(fixture, service: service, cache: nil))
        #expect(await launch(fixture, service: service, cache: nil))

        #expect(await runner.recordedCalls().count == 4)
    }

    @Test("A worker does not carry a cache unless production composition gives it one")
    func workerDefaultsToNoCache() {
        #expect(AgentRuntimeWorker().launchReadinessCache == nil)
    }

    /// Run 2 of the incident: the live check stalls. The task must go ahead
    /// (not fail), and because a stall proves nothing the next launch probes
    /// again instead of replaying it.
    @Test("A stalled check lets the launch proceed and is not cached")
    func stalledCheckProceedsAndIsNotCached() async throws {
        let fixture = try fixture()
        let runner = StubBinaryRunner()
        let service = await service(runner, live: RunResult(outcome: .timedOut, stdout: "", stderr: ""))
        let cache = RuntimeLaunchReadinessCache()

        #expect(await launch(fixture, service: service, cache: cache))
        #expect(fixture.task.status == .running)
        #expect(fixture.run.status != .failed)
        #expect(await cache.hit(for: readinessConfiguration()) == nil)
    }

    @Test("Preflight passes a warning report and audits the cache source")
    func warningReportPassesAndCacheSourceIsAudited() throws {
        let fixture = try fixture()
        let warning = report(.warning)

        let probed = AgentRuntimeLaunchPreflight.preflightRuntimeReadinessBeforeLaunchResult(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            phase: "resume",
            report: warning
        )
        #expect(probed.didPass)
        #expect(probed.status == .runtimeReadinessPassed)
        #expect(probed.auditFields["readiness_state"] == "warning")
        #expect(probed.auditFields["warning_check_ids"] == "account")
        #expect(probed.auditFields["readiness_source"] == nil)

        let cached = AgentRuntimeLaunchPreflight.preflightRuntimeReadinessBeforeLaunchResult(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            phase: "resume",
            report: report(.ready),
            cachedAge: 42
        )
        #expect(cached.didPass)
        #expect(cached.auditFields["readiness_source"] == "cache")
        #expect(cached.auditFields["readiness_cache_age_s"] == "42")
    }

    @Test("A definite block still fails the launch")
    func definiteBlockStillFailsTheLaunch() async throws {
        let fixture = try fixture()
        let runner = StubBinaryRunner()
        let service = await service(
            runner,
            live: RunResult(outcome: .exited(code: 1), stdout: "", stderr: "Authentication required")
        )
        let cache = RuntimeLaunchReadinessCache()

        #expect(await launch(fixture, service: service, cache: cache) == false)
        #expect(fixture.task.status == .failed)
        #expect(fixture.run.stopReason == "runtime_readiness_failed")
        #expect(await cache.hit(for: readinessConfiguration()) == nil)
    }
}
