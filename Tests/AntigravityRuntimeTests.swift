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
            includeAstraToolsPath: true
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

    @Test("Autonomous command uses Antigravity broad permission flag")
    func autonomousCommandUsesBroadPermissionFlag() {
        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "finish the task",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            timeoutSeconds: 30,
            taskEnvironment: [:]
        )

        #expect(plan.arguments.contains("--dangerously-skip-permissions"))
        #expect(plan.arguments.contains("--sandbox") == false)
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
        #expect(adapter.providerGrantStrings(for: [.tool(name: "Write")]).isEmpty)

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
