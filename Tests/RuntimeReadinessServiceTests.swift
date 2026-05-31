import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("RuntimeReadinessService")
struct RuntimeReadinessServiceTests {
    @Test("Vertex readiness checks CLI, auth, config, and ADC without exposing tokens")
    func vertexReadinessRedactsCredentialOutput() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/claude --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.2.3\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/claude auth status",
            result: RunResult(
                outcome: .exited(code: 0),
                stdout: #"{"loggedIn":true,"authMethod":"third_party","apiProvider":"vertex"}"#,
                stderr: ""
            )
        )
        await runner.setResponse(
            forKey: "/opt/gcloud --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "Google Cloud SDK 999.0.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default print-access-token --quiet",
            result: RunResult(outcome: .exited(code: 0), stdout: "ya29.secret-token-value\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in
                switch binary {
                case "claude": "/opt/claude"
                case "gcloud": "/opt/gcloud"
                default: ""
                }
            },
            isExecutable: { !$0.isEmpty }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .claudeCode,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .vertex,
            vertexProjectID: "project-1",
            vertexRegion: "global",
            vertexOpusModel: "claude-opus-4-6@default",
            vertexSonnetModel: "claude-sonnet-4-6@default",
            vertexHaikuModel: "claude-haiku-4-5@20251001"
        ))

        #expect(report.state == .ready)
        #expect(report.checks.contains { $0.id == "vertex-adc" && $0.state == .ready })
        #expect(!report.checks.map(\.detail).joined(separator: "\n").contains("ya29.secret-token-value"))
    }

    @Test("Vertex missing aliases block readiness")
    func missingVertexAliasesBlockReadiness() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/claude --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.2.3\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/claude auth status",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"loggedIn":true}"#, stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/gcloud --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "Google Cloud SDK 999.0.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default print-access-token --quiet",
            result: RunResult(outcome: .exited(code: 0), stdout: "token\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in binary == "gcloud" ? "/opt/gcloud" : "/opt/claude" },
            isExecutable: { !$0.isEmpty }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .claudeCode,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .vertex,
            vertexProjectID: "project-1",
            vertexRegion: "global",
            vertexOpusModel: "",
            vertexSonnetModel: "claude-sonnet-4-6@default",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .blocked)
        let aliases = report.checks.first { $0.id == "vertex-model-aliases" }
        #expect(aliases?.state == .blocked)
        #expect(aliases?.detail.contains("Opus") == true)
        #expect(aliases?.detail.contains("Haiku") == true)
    }

    @Test("Configured Claude path is used before detection")
    func configuredClaudePathWins() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/custom/bin/claude --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.2.3\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/custom/bin/claude auth status",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"loggedIn":true}"#, stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "/detected/claude" },
            isExecutable: { $0 == "/custom/bin/claude" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .claudeCode,
            claudePath: "/custom/bin/claude",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .ready)
        let calls = await runner.recordedCalls()
        #expect(calls.contains { $0.path == "/custom/bin/claude" && $0.args == ["--version"] })
        #expect(!calls.contains { $0.path == "/detected/claude" })
    }

    @Test("Copilot readiness does not warn when only auth status is unknown")
    func copilotReadinessDefersAccountValidation() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "0.0.342\nCommit: abc123\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in binary == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .copilotCLI,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .ready)
        #expect(report.checks.contains { $0.id == "copilot-cli" && $0.state == .ready })
        let account = report.checks.first { $0.id == "copilot-account" }
        #expect(account?.state == .ready)
        #expect(account?.remediation == nil)
        #expect(account?.detail.contains("account validation happens when a task starts") == true)

        let calls = await runner.recordedCalls()
        #expect(calls == [
            StubBinaryRunner.Call(path: "/opt/homebrew/bin/copilot", args: ["--version"])
        ])
    }

    @Test("Configured Copilot path is used before detection")
    func configuredCopilotPathWins() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/custom/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "copilot 1.0\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "/detected/copilot" },
            isExecutable: { $0 == "/custom/bin/copilot" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .copilotCLI,
            claudePath: "",
            copilotPath: "/custom/bin/copilot",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .ready)
        let calls = await runner.recordedCalls()
        #expect(calls.contains { $0.path == "/custom/bin/copilot" && $0.args == ["--version"] })
        #expect(!calls.contains { $0.path == "/detected/copilot" })
    }

    @Test("Provider-keyed readiness settings choose configured executable")
    func providerKeyedReadinessSettingsChooseConfiguredExecutable() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/provider-map/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "copilot 1.0\n", stderr: "")
        )

        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/provider-map/bin/copilot", for: .copilotCLI)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "/detected/copilot" },
            isExecutable: { $0 == "/provider-map/bin/copilot" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .copilotCLI,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .ready)
        let calls = await runner.recordedCalls()
        #expect(calls.contains { $0.path == "/provider-map/bin/copilot" && $0.args == ["--version"] })
        #expect(!calls.contains { $0.path == "/detected/copilot" })
    }

    @Test("Missing Copilot CLI blocks readiness before account validation")
    func missingCopilotBlocksReadiness() async {
        let runner = StubBinaryRunner()
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { _ in false }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .copilotCLI,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .blocked)
        #expect(report.checks.count == 1)
        #expect(report.checks.first?.id == "copilot-cli")
        #expect(report.checks.first?.state == .blocked)
    }

    @Test("Antigravity diagnostic readiness runs a live noninteractive check")
    func antigravityDiagnosticReadinessRunsLivePrintCheck() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/agy --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.2\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/agy --print Reply with ASTRA_READY only. --print-timeout 30s --sandbox",
            result: RunResult(outcome: .exited(code: 0), stdout: "ASTRA_READY\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in binary == "agy" ? "/opt/agy" : "" },
            isExecutable: { $0 == "/opt/agy" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .antigravityCLI,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .ready)
        let account = report.checks.first { $0.id == "antigravity-account" }
        #expect(account?.state == .ready)
        #expect(account?.detail.contains("agy --print --sandbox") == true)
        #expect(await runner.recordedCalls() == [
            StubBinaryRunner.Call(path: "/opt/agy", args: ["--version"]),
            StubBinaryRunner.Call(
                path: "/opt/agy",
                args: ["--print", "Reply with ASTRA_READY only.", "--print-timeout", "30s", "--sandbox"]
            )
        ])
    }

    @Test("Antigravity diagnostic readiness blocks on live auth failure without leaking credentials")
    func antigravityDiagnosticReadinessBlocksOnLiveAuthFailure() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/agy --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.2\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/agy --print Reply with ASTRA_READY only. --print-timeout 30s --sandbox",
            result: RunResult(
                outcome: .exited(code: 1),
                stdout: "",
                stderr: "Authentication required for alvaro@example.com token ya29.secret-token-value\n"
            )
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in binary == "agy" ? "/opt/agy" : "" },
            isExecutable: { $0 == "/opt/agy" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .antigravityCLI,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .blocked)
        let account = report.checks.first { $0.id == "antigravity-account" }
        #expect(account?.state == .blocked)
        #expect(account?.remediation?.contains("Run `agy` in Terminal") == true)
        #expect(account?.detail.contains("[redacted-email]") == true)
        #expect(account?.detail.contains("[redacted-token]") == true)
        #expect(account?.detail.contains("alvaro@example.com") == false)
        #expect(account?.detail.contains("ya29.secret-token-value") == false)
    }

    @Test("Readiness redactor is shared by generic and Antigravity failures")
    func readinessRedactorIsSharedByGenericAndAntigravityFailures() {
        let raw = "user alvaro@example.com token ya29.secret-token-value key sk-test-secret"
        let redacted = RuntimeReadinessRedactor.redacted(raw)

        #expect(redacted.contains("[redacted-email]"))
        #expect(redacted.contains("[redacted-token]"))
        #expect(redacted.contains("[redacted-key]"))
        #expect(!redacted.contains("alvaro@example.com"))
        #expect(!redacted.contains("ya29.secret-token-value"))
        #expect(!redacted.contains("sk-test-secret"))
    }

    @Test("Antigravity availability readiness remains lightweight")
    func antigravityAvailabilityReadinessDoesNotSpendLiveProviderCall() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/agy --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.2\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in binary == "agy" ? "/opt/agy" : "" },
            isExecutable: { $0 == "/opt/agy" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .antigravityCLI,
            scope: .availability,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.state == .ready)
        let account = report.checks.first { $0.id == "antigravity-account" }
        #expect(account?.detail.contains("live non-interactive account check") == true)
        #expect(await runner.recordedCalls() == [
            StubBinaryRunner.Call(path: "/opt/agy", args: ["--version"])
        ])
    }

    @Test("states covers all registered runtimes even when all CLIs are missing")
    func statesCoversAllRegisteredRuntimes() async {
        // All CLIs absent — states must still carry an entry per runtime (all blocked).
        // This verifies the invariant that callers rely on: if states.count ==
        // AgentRuntimeAdapterRegistry.runtimeIDs.count the result is complete, not partial.
        let service = RuntimeProviderAvailabilityService(
            readinessService: RuntimeReadinessService(
                runner: StubBinaryRunner(),
                detectExecutable: { _ in "" },
                isExecutable: { _ in false }
            )
        )

        let states = await service.states(configuration: RuntimeProviderAvailabilityConfiguration(
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(states.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
        #expect(states.values.allSatisfy { $0 == .blocked })
    }

    @Test("readyRuntimes with partial states excludes providers missing from the dict")
    func readyRuntimesWithPartialStatesExcludesMissingProviders() {
        // Simulates what happens when withTaskGroup's for-await exits early after task
        // cancellation: only the checks that completed before cancellation appear in the dict.
        let partialStates: [AgentRuntimeID: RuntimeReadinessState] = [
            .claudeCode: .ready
            // copilotCLI and antigravityCLI absent — as if the task was cancelled before
            // their subprocess checks returned.
        ]

        let ready = RuntimeProviderAvailabilityService.readyRuntimes(from: partialStates)
        #expect(ready == [.claudeCode])

        // The count-based guard in refreshRuntimeAvailability detects this as a partial result
        // and rejects it, preventing the incomplete list from reaching runtimeReadinessStates.
        #expect(partialStates.count != AgentRuntimeAdapterRegistry.runtimeIDs.count)
    }

    @Test("Provider availability exposes only ready runtimes")
    func providerAvailabilityExposesOnlyReadyRuntimes() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "copilot 1.0\n", stderr: "")
        )

        let readiness = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in
                switch binary {
                case "claude": "/opt/claude"
                case "copilot": "/opt/copilot"
                default: ""
                }
            },
            isExecutable: { $0 == "/opt/copilot" }
        )
        let service = RuntimeProviderAvailabilityService(readinessService: readiness)

        let states = await service.states(configuration: RuntimeProviderAvailabilityConfiguration(
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(states[.claudeCode] == .blocked)
        #expect(states[.copilotCLI] == .ready)
        #expect(RuntimeProviderAvailabilityService.readyRuntimes(from: states) == [.copilotCLI])
    }
}
