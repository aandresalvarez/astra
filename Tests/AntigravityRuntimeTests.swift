import Foundation
import Testing
@testable import ASTRA
import ASTRACore
import ASTRAModels

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
        // Unprobed binary: plain text until the readiness check confirms the
        // flag exists.
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

    @Test("ADC auth mode exports AGY_ADC_AUTH; consumer mode does not")
    func adcAuthModeExportsEnvVar() {
        let defaults = InMemoryDefaults()

        #expect(AntigravityCLIRuntime.authEnvironment(defaults: defaults).isEmpty)

        defaults.set(AntigravityAuthMode.adc.rawValue, forKey: AppStorageKeys.antigravityAuthMode)
        #expect(AntigravityCLIRuntime.authEnvironment(defaults: defaults) == ["AGY_ADC_AUTH": "true"])

        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 30,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted),
            defaults: defaults
        )
        #expect(plan.environment["AGY_ADC_AUTH"] == "true")
    }

    @Test("Structured output is used only once the binary is known to support it")
    func structuredOutputRequiresAProbedBinary() {
        let defaults = InMemoryDefaults()

        func plan() -> AntigravityCLICommandPlan {
            AntigravityCLIRuntime.buildCommand(
                executablePath: "/bin/agy",
                prompt: "hello",
                workspacePath: "/workspace",
                additionalPaths: [],
                permissionPolicy: .restricted,
                timeoutSeconds: 30,
                taskEnvironment: [:],
                permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted),
                defaults: defaults
            )
        }

        // Unknown means plain text: an older agy rejects `--output-format`
        // outright, and losing a run is worse than losing its token counts.
        #expect(!AntigravityCLIRuntime.structuredOutputSupported(executablePath: "/bin/agy", defaults: defaults))
        #expect(plan().arguments.contains("--output-format") == false)
        #expect(plan().parsesJSONLines == false)

        AntigravityCLIRuntime.cacheStructuredOutputSupport(true, executablePath: "/bin/agy", defaults: defaults)
        #expect(AntigravityCLIRuntime.structuredOutputSupported(executablePath: "/bin/agy", defaults: defaults))
        #expect(plan().arguments.starts(with: [
            "--print", "hello", "--output-format", "stream-json", "--print-timeout", "30s"
        ]))
        #expect(plan().parsesJSONLines)

        // A probe that said no keeps the run on plain text.
        AntigravityCLIRuntime.cacheStructuredOutputSupport(false, executablePath: "/bin/agy", defaults: defaults)
        #expect(plan().arguments.contains("--output-format") == false)

        // The verdict belongs to one binary: a different executable has not
        // been probed, whatever the cache holds for the old one.
        AntigravityCLIRuntime.cacheStructuredOutputSupport(true, executablePath: "/bin/agy", defaults: defaults)
        #expect(!AntigravityCLIRuntime.structuredOutputSupported(executablePath: "/opt/other-agy", defaults: defaults))

        #expect(AntigravityCLIRuntime.parseStructuredOutputSupport(
            "  --output-format  Output format for print mode (text, json, stream-json)"
        ))
        #expect(!AntigravityCLIRuntime.parseStructuredOutputSupport("  --print  Run a single prompt"))
    }

    // All four frames below were captured from agy 1.2.2 run with
    // `--output-format stream-json`.

    @Test("The structured stream carries the session id, deltas, and tool calls")
    func structuredStreamMapsProgressFrames() {
        let initFrame = #"""
        {"event":"init","conversation_id":"65eba0b4-5486-4ffb-9fa7-b50133da39da","init":{"cwd":"/tmp","tools":["run_command"],"permission_mode":"always-proceed"}}
        """#
        if case .started(let sessionID, _) = AntigravityCLIRuntime.parseAgentEvents(line: initFrame, parsesJSONLines: true).first {
            #expect(sessionID == "65eba0b4-5486-4ffb-9fa7-b50133da39da")
        } else {
            Issue.record("Expected the init frame to carry the conversation id")
        }

        // An assistant delta is visible progress and must never be terminal:
        // mistaking a mid-turn message for the end of the run is what had the
        // monitor killing Codex and Copilot runs that were still working.
        let delta = #"""
        {"event":"step_update","step_update":{"step_index":5,"state":"ACTIVE","step_type":"agent_response","text_delta":"DONE"}}
        """#
        let deltaEvents = AntigravityCLIRuntime.parseEvents(line: delta, parsesJSONLines: true)
        if case .text(let text) = deltaEvents.first {
            #expect(text == "DONE")
        } else {
            Issue.record("Expected an assistant delta to parse as visible text")
        }
        #expect(!deltaEvents.contains { if case .result = $0 { true } else { false } })

        let toolStart = #"""
        {"event":"step_update","step_update":{"step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello-from-agy"}}}}
        """#
        if case .toolUse(let name, let id, let summary) = AntigravityCLIRuntime.parseAgentEvents(line: toolStart, parsesJSONLines: true).first {
            #expect(name == "run_command")
            #expect(id == "step-4")
            #expect(summary == #"{"CommandLine":"echo hello-from-agy"}"#)
        } else {
            Issue.record("Expected a tool start to parse as a tool use")
        }

        let toolDone = #"""
        {"event":"step_update","step_update":{"step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"output":"hello-from-agy\n"}}}
        """#
        if case .toolResult(let id, let content, let isError) = AntigravityCLIRuntime.parseAgentEvents(line: toolDone, parsesJSONLines: true).first {
            #expect(id == "step-4", "the step index pairs a result back to its use")
            #expect(content == "hello-from-agy\n")
            #expect(!isError)
        } else {
            Issue.record("Expected a finished tool to parse as a tool result")
        }

        // A denied tool now arrives typed, instead of being recognised by
        // matching prose.
        let toolError = #"""
        {"event":"step_update","step_update":{"step_index":2,"state":"ERROR","step_type":"tool","tool_name":"list_dir","tool_info":{"error":{"type":"TOOL_ERROR","message":"permission check failed for read_file"}}}}
        """#
        if case .toolResult(_, let content, let isError) = AntigravityCLIRuntime.parseAgentEvents(line: toolError, parsesJSONLines: true).first {
            #expect(content == "permission check failed for read_file")
            #expect(isError)
        } else {
            Issue.record("Expected a failed tool to parse as an errored tool result")
        }
    }

    @Test("Only the result frame ends an Antigravity run, and it reports usage")
    func structuredStreamResultFrameIsTerminal() {
        let result = #"""
        {"event":"result","result":{"conversation_id":"65eba0b4","status":"SUCCESS","response":"DONE\n","duration_seconds":9.827644,"num_turns":1,"usage":{"input_tokens":20532,"output_tokens":1339,"thinking_tokens":1185,"cache_read_tokens":7296,"total_tokens":21871}}}
        """#

        let parsed = AntigravityCLIRuntime.parseEvents(line: result, parsesJSONLines: true)
        #expect(parsed.count == 1, "one terminal event per run, not one per payload field")
        if case .result(let text, let cost, let input, let output, let duration, let turns, let isError) = parsed.first {
            #expect(text == "DONE\n")
            // Cached reads still occupied the context window, so they count as
            // input; `thinking_tokens` is already part of the output total.
            #expect(input == 27_828)
            #expect(output == 1339)
            #expect(duration == 9827)
            #expect(turns == 1)
            #expect(!isError)
            #expect(cost == nil, "Antigravity bills by subscription, so there is no per-run cost")
        } else {
            Issue.record("Expected the result frame to be the terminal event")
        }

        // The recorder still gets a completion for run output plus the stats
        // that give the run its token totals.
        let agentEvents = AntigravityCLIRuntime.parseAgentEvents(line: result, parsesJSONLines: true)
        #expect(agentEvents.contains { if case .completed(let summary) = $0 { summary == "DONE\n" } else { false } })
        #expect(agentEvents.contains { if case .stats = $0 { true } else { false } })

        let failure = #"""
        {"event":"result","result":{"status":"ERROR","response":"model refused the request","num_turns":1}}
        """#
        if case .result(_, _, _, _, _, _, let isError) = AntigravityCLIRuntime.parseEvents(line: failure, parsesJSONLines: true).first {
            #expect(isError)
        } else {
            Issue.record("Expected a non-SUCCESS status to parse as a failed run")
        }
    }

    @Test("Prose still falls back to the plain-text parser in stream-json mode")
    func structuredStreamFallsBackToPlainTextForProse() {
        // agy prints banners and auth notices outside the JSON stream, and the
        // plain-text path still owns recognising them.
        let prompt = "Allow access to these paths? (y/n)"
        #expect(AntigravityCLIRuntime.blockingPlainTextMessage(line: prompt) != nil)

        let events = AntigravityCLIRuntime.parseAgentEvents(line: "checking workspace trust...", parsesJSONLines: true)
        #expect(events.contains { if case .text = $0 { true } else { false } })
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

    @Test("Plain text parser preserves blank lines as paragraph boundaries")
    func plainTextParserPreservesBlankLinesAsParagraphBoundaries() {
        let recordingEvents = AntigravityCLIRuntime.parsePlainTextAgentEvents(
            line: "",
            appendingNewline: true
        )
        #expect(recordingEvents == [.text(text: "\n")])

        // The monitor path never appends newlines and must keep ignoring blanks.
        #expect(AntigravityCLIRuntime.parsePlainTextAgentEvents(line: "   ") == [])
    }

    @Test("Model list parser splits agy's tab-separated id/name pairs and drops the fetching status line")
    func modelListParserSplitsIDAndDisplayName() {
        // Captured verbatim from the installed `agy models`: stdout is
        // tab-separated `<id>\t<display name>` lines; `runProbe` appends
        // stderr (a "Fetching available models..." progress line) after a
        // blank line, which must not be mistaken for a model.
        let output = """
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        gemini-3.1-pro-high\tGemini 3.1 Pro (High)
        gemini-3.1-pro-low\tGemini 3.1 Pro (Low)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)

        Fetching available models...
        """

        let options = AntigravityCLIRuntime.parseModelOptions(output)
        #expect(options == [
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-low", displayName: "Gemini 3.8 Flash (Low)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.1-pro-high", displayName: "Gemini 3.1 Pro (High)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.1-pro-low", displayName: "Gemini 3.1 Pro (Low)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6 (Thinking)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 (Thinking)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B (Medium)"),
        ])
        #expect(AntigravityCLIRuntime.parseModelNames(output) == options.map(\.id))
        #expect(AntigravityCLIRuntime.parseModelOptions("") == [])
        #expect(AntigravityCLIRuntime.parseModelOptions("Available models\nTip: use --model to switch.\nFetching available models...\n") == [])

        // A bare line with no tab (the static `bundledModelNames` shape) keeps
        // its text as both id and display name instead of being dropped.
        #expect(AntigravityCLIRuntime.parseModelOptions("Local Experimental Model") == [
            AntigravityCLIRuntime.AntigravityModelOption(id: "Local Experimental Model", displayName: "Local Experimental Model")
        ])
    }

    @Test("Model options group into base models with shared reasoning-effort SKUs")
    func modelOptionsGroupByBaseAndEffort() throws {
        let options = [
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-low", displayName: "Gemini 3.8 Flash (Low)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.1-pro-high", displayName: "Gemini 3.1 Pro (High)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.1-pro-low", displayName: "Gemini 3.1 Pro (Low)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6 (Thinking)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 (Thinking)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B (Medium)"),
        ]

        let groups = AntigravityCLIRuntime.groupModelOptions(options)
        #expect(groups.map(\.baseID) == [
            "gemini-3.8-flash",
            "gemini-3.1-pro",
            "claude-sonnet-4-6",
            "claude-opus-4-6-thinking",
            "gpt-oss-120b",
        ])

        let flash = try #require(groups.first { $0.baseID == "gemini-3.8-flash" })
        #expect(flash.baseDisplayName == "Gemini 3.8 Flash")
        #expect(flash.sortedEfforts == ["low", "medium", "high"])
        #expect(flash.efforts == [
            "high": "gemini-3.8-flash-high",
            "medium": "gemini-3.8-flash-medium",
            "low": "gemini-3.8-flash-low",
        ])
        #expect(flash.preferredDefaultEffort == "medium")

        // No medium SKU exists for this family — the preferred default falls
        // through to high rather than picking low by array order.
        let pro = try #require(groups.first { $0.baseID == "gemini-3.1-pro" })
        #expect(pro.sortedEfforts == ["low", "high"])
        #expect(pro.preferredDefaultEffort == "high")

        // Claude's ids take no `--effort`, so they group as their own
        // single-entry, effort-less base — the composer's Effort menu
        // stays hidden for them.
        let sonnet = try #require(groups.first { $0.baseID == "claude-sonnet-4-6" })
        #expect(sonnet.sortedEfforts.isEmpty)
        #expect(sonnet.baseDisplayName == "Claude Sonnet 4.6 (Thinking)")
        #expect(sonnet.preferredDefaultEffort == nil)
    }

    @Test("fullModelID resolves a base+effort choice back to a real SKU, and falls back safely")
    func fullModelIDResolvesOrFallsBack() {
        let groups = AntigravityCLIRuntime.groupModelOptions([
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)"),
            AntigravityCLIRuntime.AntigravityModelOption(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6 (Thinking)"),
        ])

        #expect(AntigravityCLIRuntime.fullModelID(base: "gemini-3.8-flash", effort: "medium", groups: groups) == "gemini-3.8-flash-medium")
        // No effort chosen yet: falls back to the base string rather than guessing a SKU.
        #expect(AntigravityCLIRuntime.fullModelID(base: "gemini-3.8-flash", effort: nil, groups: groups) == "gemini-3.8-flash")
        // An effort that doesn't exist for this base (e.g. carried over from switching models) is ignored.
        #expect(AntigravityCLIRuntime.fullModelID(base: "claude-sonnet-4-6", effort: "high", groups: groups) == "claude-sonnet-4-6")
        // A flattened id persisted before this grouping existed passes through unchanged.
        #expect(AntigravityCLIRuntime.fullModelID(base: "gemini-3.8-flash-high", effort: "medium", groups: groups) == "gemini-3.8-flash-high")

        let flashMedium = AntigravityCLIRuntime.currentSelection(model: "gemini-3.8-flash-medium", groups: groups)
        #expect(flashMedium.baseID == "gemini-3.8-flash")
        #expect(flashMedium.effort == "medium")

        let sonnet = AntigravityCLIRuntime.currentSelection(model: "claude-sonnet-4-6", groups: groups)
        #expect(sonnet.baseID == "claude-sonnet-4-6")
        #expect(sonnet.effort == nil)

        // An unrecognized/custom model string is echoed back as its own base with no effort.
        let custom = AntigravityCLIRuntime.currentSelection(model: "some-custom-model", groups: groups)
        #expect(custom.baseID == "some-custom-model")
        #expect(custom.effort == nil)
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
            providerFeatures: adapter.supportedFeatures,
            launchResourceContractAvailable: true,
            providerEnvironmentSecretResourceLabels: ["JIRA_API_TOKEN"]
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
