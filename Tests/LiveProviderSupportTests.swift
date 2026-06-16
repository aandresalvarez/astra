import Testing
@testable import ASTRA

@Suite("Live provider test support")
struct LiveProviderSupportTests {
    @Test("Claude artifact model falls back to the supported Claude default")
    func claudeArtifactModelFallsBackToSupportedDefault() {
        let config = LiveProviderTestConfiguration(environment: [:])

        #expect(config.claudeModel == AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode))
        #expect(config.claudeArtifactModel == AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode))
        #expect(config.claudeArtifactModel != "claude-opus-4-6@default")
    }

    @Test("Claude artifact model honors explicit artifact override before general Claude override")
    func claudeArtifactModelHonorsOverrideOrder() {
        let config = LiveProviderTestConfiguration(environment: [
            "REAL_CLAUDE_MODEL": "claude-sonnet-override",
            "REAL_CLAUDE_ARTIFACT_MODEL": "claude-artifact-override"
        ])

        #expect(config.claudeModel == "claude-sonnet-override")
        #expect(config.claudeArtifactModel == "claude-artifact-override")
    }

    @Test("Claude artifact model falls back to general Claude override")
    func claudeArtifactModelFallsBackToGeneralOverride() {
        let config = LiveProviderTestConfiguration(environment: [
            "REAL_CLAUDE_MODEL": "claude-live-default"
        ])

        #expect(config.claudeModel == "claude-live-default")
        #expect(config.claudeArtifactModel == "claude-live-default")
    }
}

@Suite("Live provider diagnostics")
struct LiveProviderDiagnosticsTests {
    @Test("redaction removes common provider secrets")
    func redactionRemovesCommonProviderSecrets() {
        let redacted = LiveProviderDiagnostics.redacted(
            "OPENAI_API_KEY=sk-test-secret gh token gho_abcdefghijklmnop"
        )

        #expect(!redacted.contains("sk-test-secret"))
        #expect(!redacted.contains("gho_abcdefghijklmnop"))
        #expect(redacted.contains("sk-[redacted]"))
        #expect(redacted.contains("gho_[redacted]"))
    }

    @Test("summary includes redacted launch evidence")
    @MainActor
    func summaryIncludesRedactedLaunchEvidence() {
        let task = AgentTask(title: "Launch evidence", goal: "Probe runtime")
        let run = TaskRun(task: task)
        task.runs.append(run)
        task.events.append(TaskEvent(
            task: task,
            type: "astra.provider_launch_signature",
            payload: #"{"args":["--model","claude-sonnet-4-6"],"env":"OPENAI_API_KEY=sk-test-secret"}"#,
            run: run
        ))

        let summary = LiveProviderDiagnostics.summary(
            label: "probe",
            task: task,
            workspacePath: "/tmp/workspace"
        )

        #expect(summary.contains("launch_events="))
        #expect(summary.contains("claude-sonnet-4-6"))
        #expect(summary.contains("sk-[redacted]"))
        #expect(!summary.contains("sk-test-secret"))
    }
}

@Suite("Live provider readiness")
struct LiveProviderReadinessTests {
    @Test("OpenCode readiness blocks zero credentials")
    func openCodeReadinessBlocksZeroCredentials() {
        let result = LiveProviderReadiness.check(
            runtimeID: .openCodeCLI,
            executablePath: "/usr/bin/opencode",
            runCommand: { _, _ in
                LiveProviderReadiness.CommandResult(
                    exitCode: 0,
                    output: "Credentials ~/.local/share/opencode/auth.json\n0 credentials\n"
                )
            }
        )

        #expect(result?.message.contains("opencode auth login") == true)
        #expect(result?.message.contains("0 credentials") == true)
    }

    @Test("OpenCode readiness accepts configured credentials")
    func openCodeReadinessAcceptsConfiguredCredentials() {
        let result = LiveProviderReadiness.check(
            runtimeID: .openCodeCLI,
            executablePath: "/usr/bin/opencode",
            runCommand: { _, _ in
                LiveProviderReadiness.CommandResult(
                    exitCode: 0,
                    output: "Credentials ~/.local/share/opencode/auth.json\n1 credential\n"
                )
            }
        )

        #expect(result == nil)
    }
}

@Suite("Live provider runtime cases")
struct LiveProviderRuntimeCaseTests {
    @Test("Cursor tokens are expected but cost and structured tool events are optional")
    func cursorExpectationsMatchObservedAdapterTelemetry() {
        let cursor = E2ETestSupport.runtimeCases(environment: ["RUN_E2E_RUNTIME": "cursor"]).first

        #expect(cursor?.expectsUsageStats == true)
        #expect(cursor?.expectsCostUSD == false)
        #expect(cursor?.expectsStructuredToolEvents == false)
    }

    @Test("OpenCode does not require provider sessions before the adapter records them")
    func openCodeSessionExpectationIsNotAssumed() {
        let openCode = E2ETestSupport.runtimeCases(environment: ["RUN_E2E_RUNTIME": "opencode"]).first

        #expect(openCode?.expectsSessionID == false)
        #expect(openCode?.expectsStructuredToolEvents == false)
    }
}
