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
}
