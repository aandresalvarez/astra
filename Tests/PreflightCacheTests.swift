import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Counting stub: returns a canned HealthStatus and records how many
/// times each binary was probed. Lets us assert cache hits prevent
/// re-probing.
actor CountingRunner: BinaryRunner {
    private var callCount = 0
    private let whichStdout: String

    init(whichStdout: String = "/opt/bin\n") {
        self.whichStdout = whichStdout
    }

    func count() -> Int { callCount }

    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await increment()
        // Return healthy-looking responses regardless of path, so the
        // checker flows through to a .healthy status. Tests care about
        // call *count*, not content.
        if args.first == "which" {
            return RunResult(outcome: .exited(code: 0), stdout: whichStdout, stderr: "")
        } else {
            return RunResult(outcome: .exited(code: 0), stdout: "v1.0.0\n", stderr: "")
        }
    }

    private func increment() {
        callCount += 1
    }
}

@Suite("PreflightCache")
struct PreflightCacheTests {

    @Test("First call probes, second call within TTL is cached")
    func cacheHitWithinTTL() async {
        let runner = CountingRunner()
        let checker = EnvironmentHealthChecker(runner: runner)
        let now = ClockStub(start: Date(timeIntervalSince1970: 1_000_000))
        let cache = PreflightCache(
            checker: checker,
            ttl: 30,
            now: { now.current() }
        )
        let prereq = CommonCLIPrerequisites.gcloud

        _ = await cache.status(for: prereq)
        #expect(await runner.count() == 2)  // which + --version

        // 5 seconds later — cached
        now.advance(by: 5)
        _ = await cache.status(for: prereq)
        #expect(await runner.count() == 2, "Second call within TTL must not probe again")
    }

    @Test("Call after TTL expiry re-probes")
    func cacheExpiresAfterTTL() async {
        let runner = CountingRunner()
        let checker = EnvironmentHealthChecker(runner: runner)
        let now = ClockStub(start: Date(timeIntervalSince1970: 1_000_000))
        let cache = PreflightCache(
            checker: checker,
            ttl: 30,
            now: { now.current() }
        )
        let prereq = CommonCLIPrerequisites.gcloud

        _ = await cache.status(for: prereq)
        #expect(await runner.count() == 2)

        now.advance(by: 60)  // past TTL
        _ = await cache.status(for: prereq)
        #expect(await runner.count() == 4, "Expired entry must trigger a re-probe")
    }

    @Test("invalidate(binary:) removes the binary's entries only")
    func invalidateSingleBinary() async {
        let runner = CountingRunner()
        let checker = EnvironmentHealthChecker(runner: runner)
        let cache = PreflightCache(checker: checker)

        _ = await cache.status(for: CommonCLIPrerequisites.gcloud)
        _ = await cache.status(for: CommonCLIPrerequisites.docker)
        #expect(await cache.cachedCount() == 2)

        await cache.invalidate(binary: "gcloud")
        #expect(await cache.cachedCount() == 1)
        #expect(await cache.cachedStatus(for: CommonCLIPrerequisites.docker) != nil)
        #expect(await cache.cachedStatus(for: CommonCLIPrerequisites.gcloud) == nil)
    }

    @Test("invalidateAll clears every entry")
    func invalidateAllClears() async {
        let runner = CountingRunner()
        let checker = EnvironmentHealthChecker(runner: runner)
        let cache = PreflightCache(checker: checker)

        _ = await cache.status(for: CommonCLIPrerequisites.gcloud)
        _ = await cache.status(for: CommonCLIPrerequisites.docker)
        await cache.invalidateAll()
        #expect(await cache.cachedCount() == 0)
    }

    @Test("Two prereqs with same binary but different args share no cache slot")
    func distinctArgsAreDistinctEntries() async {
        let runner = CountingRunner()
        let checker = EnvironmentHealthChecker(runner: runner)
        let cache = PreflightCache(checker: checker)

        _ = await cache.status(for: CommonCLIPrerequisites.gcloud)       // --version
        _ = await cache.status(for: CommonCLIPrerequisites.gcloudAuth)   // auth list
        #expect(await cache.cachedCount() == 2, "Different liveness args = different cache slots")
    }

    @Test("auth prerequisite nonzero exit is classified as unauthenticated")
    func authPrerequisiteNonzeroExitIsClassifiedAsUnauthenticated() async {
        let runner = AuthFailingRunner()
        let checker = EnvironmentHealthChecker(runner: runner)
        let cache = PreflightCache(checker: checker)

        let status = await cache.status(for: CommonCLIPrerequisites.githubAuth)

        guard case .unauthenticated(let detail) = status else {
            Issue.record("Expected unauthenticated, got \(status)")
            return
        }
        #expect(detail.contains("not logged in"))
    }

    @Test("a liveness timeout is retried once with the longer budget")
    func livenessTimeoutIsRetriedWithLongerBudget() async {
        let runner = ScriptedLivenessRunner(livenessOutcomes: [.timedOut, .exited(code: 0)])
        let cache = PreflightCache(
            checker: EnvironmentHealthChecker(runner: runner),
            probeTimeout: 3,
            slowProbeRetryTimeout: 15
        )

        let status = await cache.status(for: CommonCLIPrerequisites.gcloud)

        guard case .healthy = status else {
            Issue.record("Expected healthy after the slow retry, got \(status)")
            return
        }
        #expect(await runner.livenessTimeouts() == [3, 15])
        #expect(await cache.cachedStatus(for: CommonCLIPrerequisites.gcloud) == status)
    }

    @Test("a failure that is not a timeout is not retried")
    func nonTimeoutFailureIsNotRetried() async {
        let runner = ScriptedLivenessRunner(livenessOutcomes: [.exited(code: 2)])
        let cache = PreflightCache(checker: EnvironmentHealthChecker(runner: runner))

        let status = await cache.status(for: CommonCLIPrerequisites.gcloud)

        guard case .unresponsive = status else {
            Issue.record("Expected unresponsive, got \(status)")
            return
        }
        #expect(!status.isLivenessTimeout)
        #expect(await runner.livenessTimeouts().count == 1)
    }

    @Test("an auth probe that keeps timing out stays unresponsive, not signed out")
    func authProbeTimeoutIsNotClassifiedAsUnauthenticated() async {
        let runner = ScriptedLivenessRunner(livenessOutcomes: [.timedOut, .timedOut])
        let cache = PreflightCache(checker: EnvironmentHealthChecker(runner: runner))

        let status = await cache.status(for: CommonCLIPrerequisites.gcloudAuth)

        #expect(status.isLivenessTimeout, "Expected a liveness timeout, got \(status)")
        #expect(await runner.livenessTimeouts() == [
            PreflightCache.defaultProbeTimeout,
            PreflightCache.defaultSlowProbeRetryTimeout
        ])
    }

    @Test("concurrent callers for the same prerequisite share one probe")
    func concurrentCallersShareOneProbe() async throws {
        let runner = GatedRunner()
        let cache = PreflightCache(checker: EnvironmentHealthChecker(runner: runner))
        let prereq = CommonCLIPrerequisites.gcloud

        let first = Task { await cache.status(for: prereq) }
        await runner.waitUntilLivenessStarted()
        let second = Task { await cache.status(for: prereq) }
        // Give the second caller time to reach the cache while the first
        // probe is held open. Without coalescing it would start its own probe.
        try await Task.sleep(for: .milliseconds(100))
        await runner.release()

        let statuses = [await first.value, await second.value]
        #expect(statuses.allSatisfy { if case .healthy = $0 { true } else { false } })
        #expect(await runner.livenessCallCount() == 1)
    }
}

/// Answers `which` immediately and each liveness call with the next scripted
/// outcome, recording the timeout the checker granted it.
private actor ScriptedLivenessRunner: BinaryRunner {
    private var outcomes: [RunResult.Outcome]
    private var timeouts: [TimeInterval] = []

    init(livenessOutcomes: [RunResult.Outcome]) {
        self.outcomes = livenessOutcomes
    }

    func livenessTimeouts() -> [TimeInterval] { timeouts }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        if args.first == "which" {
            return RunResult.exited(code: 0, stdout: "/opt/bin/gcloud\n", stderr: "")
        }
        timeouts.append(timeout)
        let outcome = outcomes.isEmpty ? .exited(code: 0) : outcomes.removeFirst()
        switch outcome {
        case .timedOut:
            return RunResult.timedOut(stdout: "", stderr: "")
        case .exited(let code) where code != 0:
            return RunResult.exited(code: code, stdout: "", stderr: "boom")
        default:
            return RunResult.exited(code: 0, stdout: "account@example.com\n", stderr: "")
        }
    }
}

/// Holds every liveness call open until `release()`, without blocking a
/// thread, so a test can put a second caller in front of an in-flight probe.
private actor GatedRunner: BinaryRunner {
    private var livenessCalls = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func livenessCallCount() -> Int { livenessCalls }

    func waitUntilLivenessStarted() async {
        guard livenessCalls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        if args.first == "which" {
            return RunResult.exited(code: 0, stdout: "/opt/bin/gcloud\n", stderr: "")
        }
        livenessCalls += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return RunResult.exited(code: 0, stdout: "Google Cloud SDK 1.0.0\n", stderr: "")
    }
}

// MARK: - Clock stub

/// Controllable clock for TTL tests. Using a real Date + sleep would make
/// the test suite slow and flaky; instead we inject a `now` closure.
final class ClockStub: @unchecked Sendable {
    private var time: Date
    private let lock = NSLock()

    init(start: Date) {
        self.time = start
    }

    func current() -> Date {
        lock.lock(); defer { lock.unlock() }
        return time
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        time = time.addingTimeInterval(seconds)
    }
}

private actor AuthFailingRunner: BinaryRunner {
    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        if args.first == "which" {
            return RunResult.exited(code: 0, stdout: "/opt/bin/gh\n", stderr: "")
        }
        return RunResult.exited(code: 1, stdout: "", stderr: "not logged in")
    }
}
