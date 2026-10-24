import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Supervisor review regressions")
struct RuntimeSupervisionReviewRegressionTests {
    @Test("Raw JSON frames redact escaped credentials across chunks")
    func escapedSecrets() throws {
        let taskID = UUID()
        let secret = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC_PRIVATE_MATERIAL_123456789/\\\"\n-----END PRIVATE KEY-----"
        RunSecretRedactionScope.register(taskID: taskID, secrets: [secret])
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        let formats: [JSONEncoder.OutputFormatting] = [[], .withoutEscapingSlashes]
        for format in formats {
            let encoder = JSONEncoder()
            encoder.outputFormatting = format
            let frame = try #require(String(data: encoder.encode(["text": secret]), encoding: .utf8))
            for split in [10, 30, frame.count] {
                let transcript = RuntimeSupervisionTranscript()
                transcript.append(String(frame.prefix(split)), stderr: false, taskID: taskID)
                transcript.append("stderr interleave", stderr: true, taskID: taskID)
                transcript.append(String(frame.dropFirst(split)), stderr: false, taskID: taskID)
                #expect(!transcript.text.contains("SYNTHETIC_PRIVATE_MATERIAL"))
                #expect(transcript.text.contains("[redacted]"))
            }
        }
    }

    @Test("Secret fragments survive neither chunk seams, stream interleaving nor tail eviction")
    func transcriptRedaction() {
        let taskID = UUID()
        let secret = "TOKENHEAD_0123456789_abcdefghijklmnopqrstuvwxyz"
        RunSecretRedactionScope.register(taskID: taskID, secrets: [secret])
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        for split in [3, 10, 25] {
            let transcript = RuntimeSupervisionTranscript()
            transcript.append(String(secret.prefix(split)), stderr: false, taskID: taskID)
            transcript.append("ordinary stderr", stderr: true, taskID: taskID)
            transcript.append(String(secret.dropFirst(split)), stderr: false, taskID: taskID)
            #expect(!transcript.text.contains(String(secret.suffix(16))))
            #expect(transcript.text.contains("[redacted]"))
        }
        let transcript = RuntimeSupervisionTranscript()
        transcript.append(secret + String(repeating: "x", count: 1_180), stderr: false, taskID: taskID)
        #expect(!transcript.text.contains(String(secret.suffix(16))))
        for _ in 0..<80 { transcript.append("x", stderr: false, taskID: taskID) }
        #expect(!transcript.text.contains("uvwxyz"))
        #expect(transcript.text.count <= 1_200)
    }

    @Test("Investigation reservations preserve warning-only budgets")
    func warningBudget() {
        let warning = AgentProcessMonitor(tokenBudget: 100, budgetEnforcementMode: .warning)
        #expect(warning.reserveSupervisionTokens(16_384))
        #expect(warning.budgetWarning)
        #expect(!warning.budgetExceeded)
        #expect(!warning.processEvent(.usage(totalInputTokens: 100, totalOutputTokens: 10), process: nil))
        let hard = AgentProcessMonitor(tokenBudget: 100, budgetEnforcementMode: .hardStop)
        #expect(!hard.reserveSupervisionTokens(16_384))
        let huge = AgentProcessMonitor(tokenBudget: 100, budgetEnforcementMode: .warning)
        #expect(huge.reserveSupervisionTokens(Int.max))
        #expect(!huge.reserveSupervisionTokens(1))
    }

    @Test("Claude observation launch strips ambient customization and retains narrow auth reads")
    func observationLaunch() {
        let home = "/tmp/supervision-auth-home"
        let plan = ClaudeCodeUtilityLaunchPolicy.makePlan(prompt: "Evidence", workspacePath: "/tmp/observation",
            executable: "/tmp/claude", configuration: .init(runtime: .claudeCode), toolMode: .supervision,
            environment: ["HOME": home, "PATH": "/usr/bin:/bin", "CLAUDE_CODE_USE_VERTEX": "1",
                "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/custom-adc.json", "ANTHROPIC_API_KEY": "synthetic-auth",
                "CLAUDE_CONFIG_DIR": "/tmp/selected-work-account", "ANTHROPIC_VERTEX_BASE_URL": "https://vertex.invalid",
                "NODE_OPTIONS": "--require malicious-hook", "CLAUDE_CODE_SETTINGS": "/tmp/custom-settings.json",
                "GITHUB_TOKEN": "unrelated-secret"])
        #expect(plan.process.environment["ANTHROPIC_API_KEY"] == "synthetic-auth")
        #expect(plan.process.environment["NODE_OPTIONS"] == nil)
        #expect(plan.process.environment["CLAUDE_CODE_SETTINGS"] == nil)
        #expect(plan.process.environment["GITHUB_TOKEN"] == nil)
        #expect(plan.process.environment["CLAUDE_CODE_SAFE_MODE"] == "1")
        #expect(plan.process.environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "2048")
        #expect(plan.process.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(plan.process.environment["CLAUDE_CONFIG_DIR"] == "/tmp/selected-work-account")
        #expect(plan.process.environment["ANTHROPIC_VERTEX_BASE_URL"] == "https://vertex.invalid")
        #expect(plan.process.sandboxReadablePaths.contains("/tmp/selected-work-account"))
        #expect(plan.process.sandboxReadablePaths.contains(home + "/Library/Keychains/login.keychain-db"))
        #expect(plan.process.sandboxReadablePaths.contains(home + "/.config/gcloud/application_default_credentials.json"))
        #expect(plan.process.sandboxReadablePaths.contains("/tmp/custom-adc.json"))
        #expect(!plan.process.sandboxReadablePaths.contains(home))
        #expect(plan.process.arguments.contains("--safe-mode"))
        #expect(plan.process.arguments.contains("--strict-mcp-config"))
        #expect(plan.process.arguments.contains("mcp__*"))
        #expect(plan.process.arguments.contains(#"{"mcpServers":{}}"#))
        #expect(plan.process.arguments.contains(#"{"disableAllHooks":true}"#))
        let tools = plan.process.arguments.firstIndex(of: "--tools")
        #expect(tools.map { plan.process.arguments[$0 + 1] == "" } == true)
        let turns = plan.process.arguments.firstIndex(of: "--max-turns")
        #expect(turns.map { plan.process.arguments[$0 + 1] == "1" } == true)
        #expect(plan.process.arguments.contains("--system-prompt"))
    }

    @Test("Unsupported auth routes are rejected instead of silently switching accounts", arguments: [
        "ANTHROPIC_PROFILE", "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_CONFIG_FILE", "CLOUDSDK_CONFIG", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
        "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_FEDERATION_RULE_ID", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"
    ])
    func unsupportedAuthentication(key: String) {
        #expect(ClaudeCodeUtilityLaunchPolicy.investigationUnavailableReason(for: .claudeCode,
            environment: [key: "selected-sensitive-account"])?.contains(key) == true)
    }

    @Test("Absolute account selection is retained and relative selection fails closed")
    func accountDirectory() {
        #expect(ClaudeCodeUtilityLaunchPolicy.investigationUnavailableReason(for: .claudeCode,
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/work-account"]) == nil)
        #expect(ClaudeCodeUtilityLaunchPolicy.investigationUnavailableReason(for: .claudeCode,
            environment: ["CLAUDE_CONFIG_DIR": "work-account"]) != nil)
    }

    @Test("User settings cannot silently redirect investigation to the default saved login", arguments: ["env", "helper", "malformed", "oversized", "safe", "explicit", "discarded", "cleared", "disabled"])
    func userAuthenticationSettings(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-auth-\(UUID())")
        let settings = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A default saved login is present, but must not become a fallback when
        // an alternate settings-based auth route is suppressed by safe launch.
        try #"{"oauth":"synthetic-default-account"}"#.write(to: root.appendingPathComponent(".claude/.credentials.json"), atomically: true, encoding: .utf8)
        let source: String
        switch kind {
        case "helper": source = #"{"apiKeyHelper":"must-never-execute"}"#
        case "malformed": source = "invalid JSON"
        case "oversized": source = String(repeating: " ", count: 262_145)
        case "safe": source = #"{"env":{"ANTHROPIC_DEFAULT_SONNET_MODEL":"selected-model"}}"#
        case "discarded": source = #"{"env":{"ANTHROPIC_ORGANIZATION_ID":"work-organization"}}"#
        case "cleared": source = #"{"env":{"ANTHROPIC_API_KEY":""}}"#
        case "disabled": source = #"{"env":{"CLAUDE_CODE_USE_VERTEX":"0"}}"#
        default: source = #"{"env":{"ANTHROPIC_BASE_URL":"https://work.invalid"}}"#
        }
        try source.write(to: settings, atomically: true, encoding: .utf8)
        var environment = ["HOME": root.path]
        if kind == "explicit" { environment["ANTHROPIC_BASE_URL"] = "https://work.invalid" }
        if kind == "discarded" { environment["ANTHROPIC_ORGANIZATION_ID"] = "work-organization" }
        if kind == "cleared" { environment["ANTHROPIC_API_KEY"] = "synthetic-work-key" }
        if kind == "disabled" { environment["CLAUDE_CODE_USE_VERTEX"] = "1" }
        let reason = ClaudeCodeUtilityLaunchPolicy.investigationUnavailableReason(for: .claudeCode, environment: environment)
        #expect((reason == nil) == ["safe", "explicit"].contains(kind))
    }

    @Test("Unverified investigator providers fail before launching", arguments: AgentRuntimeAdapterRegistry.runtimeIDs.filter { $0 != .claudeCode })
    func unsupportedInvestigator(runtime: AgentRuntimeID) async {
        let result = await AgentUtilityRuntimeRunner.runPrompt("Evidence", workspacePath: "/tmp",
            configuration: .init(runtime: runtime), toolMode: .supervision)
        #expect(result.exitCode != 0)
        #expect(result.error.contains("tool-free investigation contract"))
    }

    @Test("Enforced investigator isolation preserves an explicit network denial")
    @MainActor
    func offlineIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-offline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off, allowNetwork: false) }
        let process = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: "/bin/echo",
            arguments: ["synthetic"], currentDirectory: root.path, environment: ["HOME": root.path],
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let outcome = AgentUtilityExecutionLimits.$requiresIsolation.withValue(true) {
            runner.sandboxedUtilityPlan(.init(process: process, providerHomeDirectory: "",
                permissionPolicy: .restricted, timeoutSeconds: 5))
        }
        guard case .plan(let plan) = outcome else { Issue.record("Expected an enforced sandbox plan"); return }
        #expect(plan.process.executablePath == "/usr/bin/sandbox-exec")
        #expect(plan.process.arguments.contains { $0.contains("(deny network*)") })
    }
}
