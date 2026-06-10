import Testing
import Foundation
@testable import ASTRA
import ASTRACore

// MARK: - Stubs

private final class StubTerminalLauncher: TerminalCommandLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _launchedCommands: [String] = []
    private var _openedTerminal = 0
    var shouldThrow: TerminalLaunchError?

    init(shouldThrow: TerminalLaunchError? = nil) {
        self.shouldThrow = shouldThrow
    }

    var launchedCommands: [String] {
        lock.lock(); defer { lock.unlock() }
        return _launchedCommands
    }

    var openedTerminalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _openedTerminal
    }

    func launchInTerminal(command: String) throws {
        if let shouldThrow { throw shouldThrow }
        lock.lock(); defer { lock.unlock() }
        _launchedCommands.append(command)
    }

    func openTerminalApp() {
        lock.lock(); defer { lock.unlock() }
        _openedTerminal += 1
    }
}

/// Returns scripted results in order; repeats the last one when exhausted.
private actor SequencedProbeRunner: BinaryRunner {
    struct Call {
        let path: String
        let args: [String]
        let environment: [String: String]?
    }

    private var results: [RunResult]
    private(set) var calls: [Call] = []

    init(results: [RunResult]) {
        self.results = results
    }

    func recordedCalls() -> [Call] { calls }

    func run(
        path: String,
        args: [String],
        timeout _: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        calls.append(Call(path: path, args: args, environment: environment))
        if results.count > 1 {
            return results.removeFirst()
        }
        return results.first ?? .exited(code: 127, stdout: "", stderr: "exhausted")
    }
}

private let signedIn = RunResult.exited(code: 0, stdout: "Logged in as user", stderr: "")
private let signedOut = RunResult.exited(code: 1, stdout: "Not logged in", stderr: "")

private func makeRunner(
    launcher: StubTerminalLauncher,
    probe: SequencedProbeRunner,
    maxDuration: TimeInterval = 60,
    detect: @escaping @Sendable (String) -> String = { _ in "" }
) -> RuntimeAuthSessionRunner {
    var runner = RuntimeAuthSessionRunner()
    runner.launcher = launcher
    runner.probeRunner = probe
    runner.detectExecutable = detect
    runner.maxDuration = maxDuration
    runner.pollInterval = 1
    runner.requiredConsecutiveSuccesses = 2
    runner.sleep = { _ in }
    return runner
}

private func codexRequest() -> RuntimeAuthSessionRequest {
    RuntimeAuthSessionRequest(
        runtime: .codexCLI,
        executablePath: "/opt/homebrew/bin/codex",
        remediation: RuntimeRemediationCatalog.remediation(for: .codexCLI).auth
    )
}

// MARK: - Tests

@Suite("Runtime Auth Session Runner")
struct RuntimeAuthSessionRunnerTests {

    @Test("Verifies after two consecutive successful probes")
    func verifiesAfterTwoConsecutiveSuccesses() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [signedOut, signedIn, signedIn])
        let runner = makeRunner(launcher: launcher, probe: probe)

        let outcome = await runner.run(codexRequest()) { _ in }

        #expect(outcome == .verified)
        #expect(launcher.launchedCommands == ["codex login"])
        let calls = await probe.recordedCalls()
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.path == "/opt/homebrew/bin/codex" && $0.args == ["login", "status"] })
    }

    @Test("A flaky probe timeout does not reset the consecutive count")
    func indeterminateProbeDoesNotResetProgress() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [
            signedIn,
            .timedOut(stdout: "", stderr: ""),
            signedIn
        ])
        let runner = makeRunner(launcher: launcher, probe: probe)

        let outcome = await runner.run(codexRequest()) { _ in }

        #expect(outcome == .verified)
    }

    @Test("Polling stops at the time cap when the user stays signed out")
    func timesOutWhenNeverAuthenticated() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [signedOut])
        let runner = makeRunner(launcher: launcher, probe: probe, maxDuration: 3)

        let outcome = await runner.run(codexRequest()) { _ in }

        #expect(outcome == .timedOut)
        let calls = await probe.recordedCalls()
        #expect(calls.count == 3)
    }

    @Test("Deferred providers finish right after launch without probing")
    func deferredVerificationSkipsPolling() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [])
        let runner = makeRunner(launcher: launcher, probe: probe)
        let request = RuntimeAuthSessionRequest(
            runtime: .copilotCLI,
            executablePath: "/opt/homebrew/bin/copilot",
            remediation: RuntimeRemediationCatalog.remediation(for: .copilotCLI).auth
        )

        let outcome = await runner.run(request) { _ in }

        guard case .deferred = outcome else {
            Issue.record("Copilot should defer verification, got \(outcome)")
            return
        }
        let calls = await probe.recordedCalls()
        #expect(calls.isEmpty)
        #expect(launcher.launchedCommands.first?.hasPrefix("COPILOT_HOME=") == true)
    }

    @Test("Manual-recheck providers finish right after launch")
    func manualVerificationSkipsPolling() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [])
        let runner = makeRunner(launcher: launcher, probe: probe)
        let request = RuntimeAuthSessionRequest(
            runtime: .antigravityCLI,
            executablePath: "/usr/local/bin/agy",
            remediation: RuntimeRemediationCatalog.remediation(for: .antigravityCLI).auth
        )

        let outcome = await runner.run(request) { _ in }

        guard case .manual = outcome else {
            Issue.record("Antigravity should require manual verification, got \(outcome)")
            return
        }
    }

    @Test("Denied Terminal automation falls back to copy-and-open")
    func deniedAutomationFallsBackToManualCopy() async {
        let launcher = StubTerminalLauncher(shouldThrow: TerminalLaunchError(reason: "Not authorized"))
        let probe = SequencedProbeRunner(results: [signedIn, signedIn])
        let runner = makeRunner(launcher: launcher, probe: probe)

        var phases: [RuntimeAuthSessionPhase] = []
        let collector = PhaseCollector()
        let outcome = await runner.run(codexRequest()) { phase in
            await collector.append(phase)
        }
        phases = await collector.phases

        #expect(outcome == .verified)
        #expect(launcher.openedTerminalCount == 1)
        guard case .launched(.manualCopy(let reason)) = phases.first else {
            Issue.record("Expected manual-copy launch phase, got \(phases)")
            return
        }
        #expect(reason == "Not authorized")
    }

    @Test("An old CLI without the status subcommand maps to unsupported, not signed out")
    func unsupportedProbeShortCircuits() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [
            .exited(code: 2, stdout: "", stderr: "error: unrecognized subcommand 'status'\nUsage: codex …")
        ])
        let runner = makeRunner(launcher: launcher, probe: probe)

        let outcome = await runner.run(codexRequest()) { _ in }

        guard case .probeUnsupported = outcome else {
            Issue.record("Expected probeUnsupported, got \(outcome)")
            return
        }
    }

    @Test("Signed-out wording is never classified as an unsupported probe")
    func signedOutWordingIsNotUnsupported() {
        #expect(!RuntimeAuthSessionRunner.looksLikeUnsupportedProbe("Not logged in. Run codex login."))
        #expect(!RuntimeAuthSessionRunner.looksLikeUnsupportedProbe("error: login required"))
        #expect(RuntimeAuthSessionRunner.looksLikeUnsupportedProbe("error: unknown command 'auth'"))
        #expect(RuntimeAuthSessionRunner.looksLikeUnsupportedProbe("unexpected argument '--quiet'"))
    }

    @Test("Probe subprocesses run with a pinned locale")
    func probeEnvironmentPinsLocale() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [signedIn, signedIn])
        let runner = makeRunner(launcher: launcher, probe: probe)

        _ = await runner.run(codexRequest()) { _ in }

        let calls = await probe.recordedCalls()
        for call in calls {
            #expect(call.environment?["LC_ALL"] == "C")
            #expect(call.environment?["LANG"] == "C")
        }
    }

    @Test("A probe-binary override that cannot be found fails the session")
    func missingOverrideBinaryFails() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [])
        let runner = makeRunner(launcher: launcher, probe: probe, detect: { _ in "" })
        let request = RuntimeAuthSessionRequest(
            runtime: .claudeCode,
            executablePath: "/usr/local/bin/claude",
            remediation: RuntimeRemediationCatalog.remediation(for: .claudeCode, claudeProvider: .vertex).auth
        )

        let outcome = await runner.run(request) { _ in }

        guard case .failed(let detail) = outcome else {
            Issue.record("Expected failure for missing gcloud, got \(outcome)")
            return
        }
        #expect(detail.contains("gcloud"))
    }

    @Test("OpenCode verification counts configured credentials")
    func openCodeCredentialListVerifies() async {
        let launcher = StubTerminalLauncher()
        let credentials = RunResult.exited(code: 0, stdout: "2 credentials\nanthropic\nopenai", stderr: "")
        let probe = SequencedProbeRunner(results: [credentials, credentials])
        let runner = makeRunner(launcher: launcher, probe: probe)
        let request = RuntimeAuthSessionRequest(
            runtime: .openCodeCLI,
            executablePath: "/opt/homebrew/bin/opencode",
            remediation: RuntimeRemediationCatalog.remediation(for: .openCodeCLI).auth
        )

        let outcome = await runner.run(request) { _ in }

        #expect(outcome == .verified)
    }

    @Test("Cancelling the owning task ends the session as cancelled")
    func cancellationEndsSession() async {
        let launcher = StubTerminalLauncher()
        let probe = SequencedProbeRunner(results: [signedOut])
        var runner = makeRunner(launcher: launcher, probe: probe, maxDuration: 600)
        runner.sleep = { _ in
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let frozen = runner

        let task = Task { await frozen.run(codexRequest()) { _ in } }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .cancelled)
    }
}

private actor PhaseCollector {
    private(set) var phases: [RuntimeAuthSessionPhase] = []
    func append(_ phase: RuntimeAuthSessionPhase) {
        phases.append(phase)
    }
}
