import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// A readiness probe that never got an answer (timeout, launch failure,
/// cancellation) is no evidence about the account. It must warn and let the run
/// go ahead; only a CLI that ran to completion and said "no" may block.
@Suite("Runtime readiness: an unanswered probe is not a block")
struct RuntimeReadinessInconclusiveProbeTests {
    private let agyLiveKey = "/opt/agy --print Reply with ASTRA_READY only. --print-timeout 25s --sandbox"
    private let timedOut = RunResult(outcome: .timedOut, stdout: "", stderr: "")

    private func configuration(
        _ runtime: AgentRuntimeID,
        claudeProvider: ClaudeProvider = .anthropic,
        antigravityAuthMode: AntigravityAuthMode = .consumer
    ) -> RuntimeReadinessConfiguration {
        RuntimeReadinessConfiguration(
            runtime: runtime,
            claudePath: "",
            copilotPath: "",
            claudeProvider: claudeProvider,
            vertexProjectID: "project-1",
            vertexRegion: "global",
            vertexOpusModel: "claude-opus-4-6@default",
            vertexSonnetModel: "claude-sonnet-4-6@default",
            vertexHaikuModel: "claude-haiku-4-5@20251001",
            antigravityAuthMode: antigravityAuthMode
        )
    }

    private func service(_ runner: StubBinaryRunner, binaries: [String: String]) -> RuntimeReadinessService {
        RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binaries[$0] ?? "" },
            isExecutable: { !$0.isEmpty }
        )
    }

    private func ok(_ stdout: String, stderr: String = "") -> RunResult {
        RunResult(outcome: .exited(code: 0), stdout: stdout, stderr: stderr)
    }

    private func antigravityReport(
        live: RunResult,
        authMode: AntigravityAuthMode = .consumer
    ) async -> RuntimeReadinessReport {
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/opt/agy --version", result: ok("1.0.2\n"))
        await runner.setResponse(forKey: agyLiveKey, result: live)
        return await service(runner, binaries: ["agy": "/opt/agy"]).check(
            configuration: configuration(.antigravityCLI, antigravityAuthMode: authMode)
        )
    }

    // MARK: Antigravity, the live model call

    /// The incident: the model request stalled, ASTRA killed the check at the
    /// limit, and the user was told to redo `gcloud auth application-default
    /// login` although ADC had authenticated in half a second.
    @Test("A stalled Antigravity live check warns instead of blocking, and does not blame auth")
    func stalledLiveCheckWarnsAndDoesNotBlameAuth() async throws {
        let report = await antigravityReport(live: timedOut, authMode: .adc)

        #expect(report.state == .warning)
        let account = try #require(report.checks.first { $0.id == "antigravity-account" })
        #expect(account.state == .warning)
        #expect(account.detail.contains("timed out after 30s"))
        let remediation = account.remediation ?? ""
        #expect(!remediation.contains("gcloud"))
        #expect(!remediation.contains("Google Sign-In"))
        #expect(remediation.contains("still start the run"))
    }

    /// `agy` stops waiting on the model itself and exits 0 with empty stdout
    /// and a marker on stderr; that used to fall into the empty-success block.
    @Test("agy's own print timeout warns instead of blocking")
    func agyPrintTimeoutWarns() async throws {
        let report = await antigravityReport(live: ok(
            "",
            stderr: "[agy] print timeout after 25s with turn in progress; returning partial output"
        ))

        let account = try #require(report.checks.first { $0.id == "antigravity-account" })
        #expect(account.state == .warning)
        #expect(account.detail.contains("stopped waiting for the model after 25s"))
        #expect(report.state == .warning)
    }

    @Test("An Antigravity live check that cannot start or is cancelled warns")
    func unstartedOrCancelledLiveCheckWarns() async throws {
        for live in [
            RunResult(outcome: .launchFailed("posix_spawn failed"), stdout: "", stderr: ""),
            RunResult(outcome: .cancelled, stdout: "", stderr: "")
        ] {
            let report = await antigravityReport(live: live)
            let account = try #require(report.checks.first { $0.id == "antigravity-account" })
            #expect(account.state == .warning)
        }
    }

    @Test("A definite Antigravity failure under ADC still blocks and names gcloud")
    func definiteADCFailureStillBlocks() async throws {
        let report = await antigravityReport(
            live: RunResult(outcome: .exited(code: 1), stdout: "", stderr: "Reauthentication required\n"),
            authMode: .adc
        )

        #expect(report.state == .blocked)
        let account = try #require(report.checks.first { $0.id == "antigravity-account" })
        #expect(account.state == .blocked)
        #expect(account.detail.contains("Reauthentication required"))
        #expect(account.remediation?.contains("gcloud auth application-default login") == true)
    }

    /// agy stops itself at the print timeout roughly two seconds late; the
    /// kill timer has to outlast that or the CLI's own message never wins.
    @Test("ASTRA's kill timer outlasts agy's own print timeout plus its exit lag")
    func killTimerOutlastsPrintTimeout() {
        let printTimeout = TimeInterval(AntigravityCLIRuntimeAdapter.liveCheckPrintTimeoutSeconds)
        #expect(AntigravityCLIRuntimeAdapter.liveCheckKillTimeoutSeconds >= printTimeout + 3)
    }

    // MARK: Other providers' auth probes

    @Test("A Claude auth-status timeout warns")
    func claudeAuthTimeoutWarns() async throws {
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/opt/claude --version", result: ok("1.2.3\n"))
        await runner.setResponse(forKey: "/opt/claude auth status", result: timedOut)

        let report = await service(runner, binaries: ["claude": "/opt/claude"]).check(
            configuration: configuration(.claudeCode)
        )

        let auth = try #require(report.checks.first { $0.id == "claude-auth" })
        #expect(auth.state == .warning)
        #expect(auth.detail.contains("timed out after 5s"))
        #expect(report.state == .warning)
    }

    @Test("A Vertex ADC token timeout warns, while a failing gcloud still blocks")
    func vertexADCTimeoutWarns() async throws {
        func report(token: RunResult) async -> RuntimeReadinessReport {
            let runner = StubBinaryRunner()
            await runner.setResponse(forKey: "/opt/claude --version", result: ok("1.2.3\n"))
            await runner.setResponse(
                forKey: "/opt/claude auth status",
                result: ok(#"{"loggedIn":true,"authMethod":"third_party","apiProvider":"vertex"}"#)
            )
            await runner.setResponse(forKey: "/opt/gcloud --version", result: ok("Google Cloud SDK 999.0.0\n"))
            await runner.setResponse(
                forKey: "/opt/gcloud auth application-default print-access-token --quiet",
                result: token
            )
            return await service(runner, binaries: ["claude": "/opt/claude", "gcloud": "/opt/gcloud"]).check(
                configuration: configuration(.claudeCode, claudeProvider: .vertex)
            )
        }

        let stalled = await report(token: timedOut)
        let stalledADC = try #require(stalled.checks.first { $0.id == "vertex-adc" })
        #expect(stalledADC.state == .warning)
        #expect(stalled.state == .warning)

        let refused = await report(token: RunResult(outcome: .exited(code: 1), stdout: "", stderr: "denied"))
        let refusedADC = try #require(refused.checks.first { $0.id == "vertex-adc" })
        #expect(refusedADC.state == .blocked)
        #expect(refusedADC.remediation?.contains("gcloud auth application-default login") == true)
    }

    @Test("Codex, Cursor, and OpenCode auth-probe timeouts warn")
    func otherProvidersAuthTimeoutsWarn() async throws {
        let cases: [(AgentRuntimeID, binary: String, probe: String, checkID: String)] = [
            (.codexCLI, "codex", "login status", "codex-account"),
            (.cursorCLI, "cursor-agent", "status", "cursor-account"),
            (.openCodeCLI, "opencode", "auth list", "opencode-account")
        ]
        for (runtime, binary, probe, checkID) in cases {
            let runner = StubBinaryRunner()
            await runner.setResponse(forKey: "/opt/\(binary) --version", result: ok("1.0\n"))
            await runner.setResponse(forKey: "/opt/\(binary) \(probe)", result: timedOut)

            let report = await service(runner, binaries: [binary: "/opt/\(binary)"]).check(
                configuration: configuration(runtime)
            )

            let account = try #require(report.checks.first { $0.id == checkID })
            #expect(account.state == .warning, "\(binary) auth timeout should warn")
            #expect(!report.checks.contains { $0.state == .blocked }, "\(binary) auth timeout must not block")
        }
    }

    // MARK: The CLI itself

    @Test("A CLI liveness timeout warns and does not go on to probe the account")
    func livenessTimeoutWarns() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/opt/claude --version", result: timedOut)

        let report = await service(runner, binaries: ["claude": "/opt/claude"]).check(
            configuration: configuration(.claudeCode)
        )

        #expect(report.state == .warning)
        #expect(await runner.recordedCalls() == [StubBinaryRunner.Call(path: "/opt/claude", args: ["--version"])])
    }

    @Test("A CLI that cannot be found still blocks")
    func missingCLIStillBlocks() async {
        let report = await service(StubBinaryRunner(), binaries: [:]).check(
            configuration: configuration(.claudeCode)
        )

        #expect(report.state == .blocked)
    }
}
