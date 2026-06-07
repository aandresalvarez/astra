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
