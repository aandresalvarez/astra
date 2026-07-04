import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Antigravity CLI Runtime")
struct AntigravityCLIRuntimeTests {
    @Test("Restricted command runs print mode in sandbox")
    func restrictedCommandRunsPrintModeInSandbox() {
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: ["/workspace", "/tmp/context", "/tmp/context", ""],
            permissionPolicy: .restricted,
            timeoutSeconds: 45,
            taskEnvironment: ["ASTRA_TEST_ENV": "1"],
            pathPrefix: ["/tmp/astra-shim", "/tmp/astra-shim"],
            includeAstraToolsPath: true,
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted)
        )

        #expect(plan.executablePath == "/bin/agy")
        #expect(plan.arguments.starts(with: ["--print", "hello", "--print-timeout", "45s"]))
        #expect(plan.arguments.contains("--sandbox"))
        #expect(plan.arguments.contains("--dangerously-skip-permissions") == false)
        #expect(plan.arguments.filter { $0 == "--add-dir" }.count == 1)
        #expect(plan.arguments.contains("/tmp/context"))
        #expect(plan.parsesJSONLines == false)
        #expect(plan.environment["ASTRA_TEST_ENV"] == "1")
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["AGY_CLI_HIDE_ACCOUNT_INFO"] == "1")
        #expect(plan.environment["PATH"]?.contains("/tmp/astra-shim") == true)
        #expect(plan.environment["PATH"]?.contains(RuntimePathResolver.astraToolsPath) == true)
    }

    @Test("Provider home redirects HOME for settings consistency")
    func providerHomeRedirectsHomeForSettingsConsistency() {
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 30,
            taskEnvironment: ["HOME": "/tmp/task-home"],
            providerHomeDirectory: "/tmp/provider-home",
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted)
        )

        #expect(plan.environment["HOME"] == "/tmp/provider-home")
        #expect(AntigravityCLIRuntime.settingsURL(providerHomeDirectory: "/tmp/provider-home").path == "/tmp/provider-home/.gemini/antigravity-cli/settings.json")
    }

    @Test("Version summary is deferred to readiness checks")
    func versionSummaryIsDeferredToReadinessChecks() {
        #expect(AntigravityCLIRuntime.versionSummary(executablePath: "/bin/agy") == nil)
    }

    @Test("Autonomous command uses Antigravity broad permission flag")
    func autonomousCommandUsesBroadPermissionFlag() {
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "finish the task",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            timeoutSeconds: 30,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .autonomous)
        )

        #expect(plan.arguments.contains("--dangerously-skip-permissions"))
        #expect(plan.arguments.contains("--sandbox") == false)
    }

    @Test("Command includes diagnostic log when configured")
    func commandIncludesDiagnosticLogWhenConfigured() {
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 30,
            taskEnvironment: [:],
            diagnosticLogPath: "/workspace/.astra/tasks/TASK/diagnostics/antigravity-run.log",
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted)
        )

        #expect(plan.arguments.contains("--log-file"))
        #expect(plan.arguments.contains("/workspace/.astra/tasks/TASK/diagnostics/antigravity-run.log"))
        #expect(plan.diagnosticLogPath == "/workspace/.astra/tasks/TASK/diagnostics/antigravity-run.log")
    }

    @Test("Diagnostic summary classifies hidden Antigravity failures")
    func diagnosticSummaryClassifiesHiddenFailures() throws {
        let log = """
        W0531 server_oauth.go:99] Account ineligible: Your current account is not eligible for Antigravity.
        E0531 log.go:398] RESOURCE_EXHAUSTED (code 429): You have exhausted your capacity on this model. Your quota will reset after 91h11m50s.
        E0531 discovery.go:383] Failed to load JSON config file /Users/alvaro1/.gemini/config/mcp_config.json: unexpected end of JSON input
        """

        let summary = try #require(AntigravityCLIRuntime.diagnosticSummary(
            logText: log,
            logPath: "/tmp/antigravity.log"
        ))

        #expect(summary.primaryCode == "quota_exhausted")
        #expect(summary.findings.contains("account_ineligible"))
        #expect(summary.findings.contains("malformed_mcp_config"))
        #expect(!summary.findings.contains("auth_required"))
        #expect(summary.message.contains("quota is exhausted"))
        #expect(summary.message.contains("Quota will reset after 91h11m50s"))
        #expect(summary.message.contains("Additional findings"))
        #expect(summary.auditFields["provider_diagnostic_log"] == "/tmp/antigravity.log")
    }

    @Test("Diagnostic summary ignores quotaProject and successful silent auth noise")
    func diagnosticSummaryIgnoresQuotaProjectAndSuccessfulSilentAuthNoise() throws {
        let log = """
        I0531 server_oauth.go:212] applyAuthResult: email=alvaro@example.com, authMethod=consumer, quotaProject=
        E0531 log.go:398] Failed to poll ListExperiments: error getting token source: You are not logged into Antigravity.
        I0531 auth.go:114] ChainedAuth: authenticated via keyring (effective: keyring)
        I0531 server_oauth.go:217] OAuth: authenticated successfully as alvaro@example.com
        I0531 printmode.go:166] Print mode: silent auth succeeded
        E0531 log.go:398] RESOURCE_EXHAUSTED (code 429): You have exhausted your capacity on this model. Your quota will reset after 90h59m32s.
        """

        let summary = try #require(AntigravityCLIRuntime.diagnosticSummary(
            logText: log,
            logPath: "/tmp/antigravity.log"
        ))

        #expect(summary.primaryCode == "quota_exhausted")
        #expect(summary.findings == ["quota_exhausted"])
        #expect(summary.evidence.contains("RESOURCE_EXHAUSTED"))
        #expect(!summary.evidence.contains("quotaProject"))
        #expect(summary.message.contains("Quota will reset after 90h59m32s"))
    }

    @Test("Plain text parser keeps assistant text and surfaces permission prompts")
    func plainTextParserKeepsTextAndPermissionPrompts() {
        let textEvents = AntigravityCLIRuntime.parsePlainTextAgentEvents(
            line: "hello from agy",
            appendingNewline: true
        )
        #expect(textEvents == [.text(text: "hello from agy\n")])

        let promptEvents = AntigravityCLIRuntime.parsePlainTextAgentEvents(
            line: "Allow access to these paths? (y/n):"
        )
        #expect(promptEvents == [.permissionRequested(
            tool: "WorkspaceAccess",
            reason: "Allow access to these paths? (y/n):"
        )])
        #expect(AntigravityCLIRuntime.blockingPlainTextMessage(
            line: "Allow access to these paths? (y/n):"
        ) != nil)
    }

    @Test("Model list parser keeps agy models lines verbatim")
    func modelListParserKeepsAgyModelsLinesVerbatim() {
        let output = """
        Gemini 3.5 Flash (Medium)
        Gemini 3.5 Flash (High)

        Claude Opus 4.6 (Thinking)
        GPT-OSS 120B (Medium)
        Claude Opus 4.6 (Thinking)
        Tip: use --model to switch.
        """

        #expect(AntigravityCLIRuntime.parseModelNames(output) == [
            "Gemini 3.5 Flash (Medium)",
            "Gemini 3.5 Flash (High)",
            "Claude Opus 4.6 (Thinking)",
            "GPT-OSS 120B (Medium)"
        ])
        #expect(AntigravityCLIRuntime.parseModelNames("") == [])
        #expect(AntigravityCLIRuntime.parseModelNames("Available models\n") == [])
    }

    @Test("Model settings expose configured and bundled model choices")
    func modelSettingsExposeConfiguredAndBundledModelChoices() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-antigravity-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
        defer {
            try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"model":"Local Experimental Model","enableTelemetry":false}"#.utf8)
            .write(to: settingsURL)

        #expect(AntigravityCLIRuntime.configuredModel(settingsURL: settingsURL) == "Local Experimental Model")
        #expect(AntigravityCLIRuntime.defaultModelName(settingsURL: settingsURL) == "Local Experimental Model")
        #expect(AntigravityCLIRuntime.availableModelNames(settingsURL: settingsURL).starts(with: [
            "Local Experimental Model",
            "Gemini 3.5 Flash (Low)"
        ]))
        #expect(AntigravityCLIRuntime.resolvedModelName("default", settingsURL: settingsURL) == "Local Experimental Model")

        #expect(AntigravityCLIRuntime.applySelectedModel(
            "Claude Sonnet 4.6 (Thinking)",
            settingsURL: settingsURL
        ))
        let data = try Data(contentsOf: settingsURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "Claude Sonnet 4.6 (Thinking)")
        #expect(object["enableTelemetry"] as? Bool == false)
    }

    @Test("Policy render is honest about Antigravity permission granularity")
    func policyRenderIsHonestAboutPermissionGranularity() {
        let adapter = AntigravityPolicyAdapter()
        let context = PolicyRenderContext(
            runtimeID: .antigravityCLI,
            model: "default",
            workspacePath: "/workspace",
            additionalPaths: [],
            requestedAllowedTools: ["Read", "Write"],
            localToolCommands: [],
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )

        let review = adapter.render(policy: .preset(.review), context: context)
        #expect(review.cliArgumentsSummary == ["--sandbox"])
        #expect(review.generatedConfigPreview == "--sandbox")
        #expect(review.usesBroadProviderPermissions == false)
        #expect(review.diagnostics.contains { $0.id == "antigravity.fine-grained-provider-native-gap" })
        #expect(adapter.providerGrantStrings(for: [.tool(name: "Write")]) == ["Write"])
        #expect(adapter.providerGrantStrings(for: [.shellCommand(executable: "gh", pattern: "pr list *")]) == [
            "shell(gh:pr list *)"
        ])

        let autonomous = adapter.render(policy: .preset(.autonomous), context: context)
        #expect(autonomous.cliArgumentsSummary == ["--dangerously-skip-permissions"])
        #expect(autonomous.allowedTools == ["*"])
        #expect(autonomous.usesBroadProviderPermissions)
    }

    @Test("Credential redaction gap warns instead of blocking Antigravity launch")
    func credentialRedactionGapWarnsInsteadOfBlockingAntigravityLaunch() {
        let adapter = AntigravityPolicyAdapter()
        let context = PolicyRenderContext(
            runtimeID: .antigravityCLI,
            model: "default",
            workspacePath: "/workspace",
            additionalPaths: [],
            requestedAllowedTools: [],
            localToolCommands: [],
            environmentKeyNames: ["JIRA_API_TOKEN"],
            credentialLabels: ["JIRA_API_TOKEN"],
            providerFeatures: adapter.supportedFeatures
        )

        let render = adapter.render(policy: .preset(.autonomous), context: context)
        let redactionDiagnostic = render.diagnostics.first {
            $0.id == "antigravity_cli.secret-redaction-unsupported"
        }

        #expect(render.diagnostics.contains { $0.severity == .blocked } == false)
        #expect(redactionDiagnostic?.severity == .warning)
        #expect(redactionDiagnostic?.title == "Credential redaction is ASTRA-managed")
    }
}
