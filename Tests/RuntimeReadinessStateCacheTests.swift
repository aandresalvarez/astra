import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("Runtime readiness state cache")
struct RuntimeReadinessStateCacheTests {
    @Test("Independent home inspections overlap on availability misses and cache hits", arguments: [false, true])
    func homeChecksOverlap(cacheHit: Bool) async {
        let cache = RuntimeReadinessStateCache()
        let configuration = configuration()
        if cacheHit {
            var states = Dictionary(uniqueKeysWithValues: AgentRuntimeAdapterRegistry.runtimeIDs.map { ($0, RuntimeReadinessState.ready) })
            states[.claudeCode] = .blocked
            states[.copilotCLI] = .warning
            await cache.store(states, for: configuration)
        }
        let inspections = OverlappingHomeInspections()
        // Only a deadlock escape for the old serial implementation. Success
        // depends on all inspections entering the barrier, never elapsed time.
        let escape = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await inspections.release()
        }
        defer { escape.cancel() }
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/opt/codex --version", result: .exited(code: 0, stdout: "codex-cli 0.130.0", stderr: ""))
        let service = RuntimeProviderAvailabilityService(readinessService: RuntimeReadinessService(
            runner: runner, detectExecutable: { "/opt/" + $0 }, isExecutable: { $0 == "/opt/codex" },
            homeAccessCheck: { await inspections.check($0) }
        ))
        let states = await service.states(configuration: configuration, cache: cache)
        #expect(await inspections.allEnteredBeforeRelease)
        let cached = await cache.states(for: configuration, maxAge: 300)
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            #expect(await inspections.count(runtime) == 1)
            let base = cached?[runtime]
            #expect(base != nil)
            let expected: RuntimeReadinessState? = base == .blocked ? .blocked
                : ([.codexCLI, .antigravityCLI].contains(runtime) ? .warning : base)
            #expect(states[runtime] == expected)
        }
        #expect(cached?[.codexCLI] == .ready)
        #expect(states[.codexCLI] == .warning)
    }

    @Test("An availability miss and a cache hit each inspect provider homes exactly once")
    func homeChecksRunOncePerAnswer() async {
        let cache = RuntimeReadinessStateCache()
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/opt/codex --version", result: .exited(code: 0, stdout: "codex-cli 0.130.0", stderr: ""))
        let probe = HomeInspectionCounter()
        let service = RuntimeProviderAvailabilityService(readinessService: RuntimeReadinessService(
            runner: runner, detectExecutable: { "/opt/" + $0 }, isExecutable: { $0 == "/opt/codex" },
            homeAccessCheck: { await probe.check($0) }
        ))
        let first = await service.states(configuration: configuration(), cache: cache)
        #expect(first[.codexCLI] == .warning)
        #expect(await cache.states(for: configuration(), maxAge: 300)?[.codexCLI] == .ready)
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs { #expect(await probe.count(runtime) == 1) }
        await probe.repair()
        let second = await service.states(configuration: configuration(), cache: cache)
        #expect(second[.codexCLI] == .ready)
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs { #expect(await probe.count(runtime) == 2) }
    }

    actor HomeInspectionCounter {
        private var counts: [AgentRuntimeID: Int] = [:]
        private var blocked = true
        func count(_ runtime: AgentRuntimeID) -> Int { counts[runtime, default: 0] }
        func repair() { blocked = false }
        func check(_ request: RuntimeHomeAccessRequest) -> RuntimeReadinessCheck? {
            counts[request.runtime, default: 0] += 1
            guard request.runtime == .codexCLI, blocked else { return nil }
            return .init(id: RuntimeHomeAccessService.checkID(for: request.runtime), title: "QA", detail: "QA", state: .blocked, remediation: nil)
        }
    }

    private func configuration(claudePath: String = "/opt/claude") -> RuntimeProviderAvailabilityConfiguration {
        RuntimeProviderAvailabilityConfiguration(
            claudePath: claudePath,
            copilotPath: "/opt/copilot",
            claudeProvider: .vertex,
            vertexProjectID: "project-1",
            vertexRegion: "global",
            vertexOpusModel: "claude-opus-4-6@default",
            vertexSonnetModel: "claude-sonnet-4-6@default",
            vertexHaikuModel: "claude-haiku-4-5@20251001"
        )
    }

    /// Opening a task must show its provider immediately: the answer for the
    /// same settings is served until it ages out or the settings change.
    @Test("Cached readiness is served for the same settings until it ages out")
    func cacheServesSameSettingsUntilExpiry() async {
        let cache = RuntimeReadinessStateCache()
        let states: [AgentRuntimeID: RuntimeReadinessState] = [.claudeCode: .ready, .copilotCLI: .blocked]
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        await cache.store(states, for: configuration(), now: checkedAt)

        let fresh = await cache.states(for: configuration(), maxAge: 300, now: checkedAt.addingTimeInterval(299))
        #expect(fresh == states)
        let expired = await cache.states(for: configuration(), maxAge: 300, now: checkedAt.addingTimeInterval(301))
        #expect(expired == nil)
        let otherSettings = await cache.states(
            for: configuration(claudePath: "/usr/local/bin/claude"),
            maxAge: 300,
            now: checkedAt
        )
        #expect(otherSettings == nil)
    }

    /// The service consults the cache before probing, and a probe result is
    /// what fills it — so the second open of a task never re-runs the CLIs.
    @Test("Availability service answers from the cache before probing")
    func serviceAnswersFromCacheBeforeProbing() async {
        let cache = RuntimeReadinessStateCache()
        let service = RuntimeProviderAvailabilityService(
            readinessService: RuntimeReadinessService(
                runner: StubBinaryRunner(),
                detectExecutable: { _ in "" },
                isExecutable: { _ in false }
            )
        )

        let probed = await service.states(configuration: configuration(), cache: cache)
        #expect(probed.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
        #expect(await cache.states(for: configuration(), maxAge: 300) == probed)

        let remembered: [AgentRuntimeID: RuntimeReadinessState] = [.claudeCode: .ready]
        await cache.store(remembered, for: configuration())
        let served = await service.states(configuration: configuration(), cache: cache)
        #expect(served == remembered)

        let bypassed = await service.states(configuration: configuration(), cache: nil)
        #expect(bypassed == probed)
    }

    /// The default must stay uncached. A cache keyed only by configuration
    /// cannot tell two differently-probed services apart, so a shared default
    /// made one caller's verdict answer for another's — it broke
    /// `RuntimeReadinessServiceTests` the moment both ran in one process.
    @Test("Availability service does not cache unless the caller passes one")
    func serviceDoesNotCacheByDefault() async {
        let readyEverything = RuntimeProviderAvailabilityService(
            readinessService: RuntimeReadinessService(
                runner: StubBinaryRunner(),
                detectExecutable: { _ in "" },
                isExecutable: { _ in false }
            )
        )
        let first = await readyEverything.states(configuration: configuration())
        await RuntimeReadinessStateCache.shared.store([.claudeCode: .ready], for: configuration())
        let second = await readyEverything.states(configuration: configuration())
        #expect(second == first)
        #expect(second.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
        await RuntimeReadinessStateCache.shared.removeAll()
    }

    /// Regression: a composer's `.task(id:)` is cancelled whenever the view
    /// goes away or its settings signature changes. The killed probes report
    /// `.cancelled`, every readiness check scores that as `.blocked`, and the
    /// task group still hands back one entry per runtime — so the cancelled
    /// refresh used to be cached as a complete answer, and every composer read
    /// "Needs setup" for five minutes while Settings, probing afresh, read Ready.
    @Test("A cancelled availability refresh is neither returned nor cached")
    func cancelledRefreshIsNotCached() async {
        let cache = RuntimeReadinessStateCache()
        let runner = CancellationAwaitingRunner()
        let service = RuntimeProviderAvailabilityService(
            readinessService: RuntimeReadinessService(
                runner: runner,
                detectExecutable: { "/opt/\($0)" },
                isExecutable: { _ in true }
            )
        )

        let refresh = Task { await service.states(configuration: configuration(), cache: cache) }
        await runner.waitUntilAProbeStarts()
        refresh.cancel()
        let states = await refresh.value

        #expect(states.isEmpty)
        #expect(await cache.states(for: configuration(), maxAge: 300) == nil)
    }
}

private actor OverlappingHomeInspections {
    private var counts: [AgentRuntimeID: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var allEnteredBeforeRelease = false

    func count(_ runtime: AgentRuntimeID) -> Int { counts[runtime, default: 0] }

    func release() {
        guard !released else { return }
        allEnteredBeforeRelease = counts.count == AgentRuntimeAdapterRegistry.runtimeIDs.count
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func check(_ request: RuntimeHomeAccessRequest) async -> RuntimeReadinessCheck? {
        counts[request.runtime, default: 0] += 1
        if counts.count == AgentRuntimeAdapterRegistry.runtimeIDs.count { release() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
        guard request.runtime == .codexCLI || request.runtime == .antigravityCLI else { return nil }
        return .init(id: RuntimeHomeAccessService.checkID(for: request.runtime), title: "QA", detail: "QA",
                     state: request.runtime == .codexCLI ? .blocked : .warning, remediation: nil)
    }
}

/// Holds every probe open until its task is cancelled, then answers the way
/// `ProcessBinaryRunner` does after terminating the process.
private actor CancellationAwaitingRunner: BinaryRunner {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilAProbeStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await markStarted()
        // `Task.sleep` suspends without holding a pooled thread and throws as
        // soon as the probe is cancelled.
        try? await Task.sleep(for: .seconds(600))
        return .cancelled(stdout: "", stderr: "")
    }
}
