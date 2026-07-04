import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Utility Runtime", .serialized)
struct AgentUtilityRuntimeTests {
    private static let longRunningHelperSleepSeconds = 30
    private static let fullSuiteUtilityDeadlineSeconds: TimeInterval = 20

    @Test("Utility runtime preserves arbitrary provider settings")
    func utilityRuntimePreservesArbitraryProviderSettings() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/opt/future/bin/future", for: futureRuntime)
        settings.setHomeDirectory("/tmp/future-home", for: futureRuntime)

        let configuration = AgentUtilityRuntimeConfiguration(
            runtime: futureRuntime,
            model: "future-model",
            providerSettings: settings
        )

        #expect(configuration.runtime == futureRuntime)
        #expect(configuration.model == "future-model")
        #expect(configuration.executablePath(for: futureRuntime) == "/opt/future/bin/future")
        #expect(configuration.homeDirectory(for: futureRuntime) == "/tmp/future-home")
    }

    @Test("Utility runtime normalizes reassigned model against provider cache")
    func utilityRuntimeNormalizesReassignedModelAgainstProviderCache() {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.runtimeAvailableModelsKey(for: .openCodeCLI)
        let original = defaults.string(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        RuntimeModelAvailability.persistAvailableModels(["opencode/big-pickle"], for: .openCodeCLI, defaults: defaults)

        var configuration = AgentUtilityRuntimeConfiguration(
            runtime: .openCodeCLI,
            model: "opencode/big-pickle"
        )
        configuration.model = "anthropic/claude-sonnet-4-5"

        #expect(configuration.model == "opencode/big-pickle")
    }

    @Test("Copilot utility runtime uses provider-keyed executable and home")
    func copilotUtilityRuntimeUsesProviderKeyedSettings() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-provider-settings-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Provider-keyed Copilot"}}'
        exit 0
        """
        try script.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopilot.path)

        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(fakeCopilot.path, for: .copilotCLI)
        settings.setHomeDirectory(copilotHome.path, for: .copilotCLI)

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            "Plan the work",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                providerSettings: settings
            ),
            toolMode: .readOnly
        )

        #expect(result.exitCode == 0)
        #expect(result.output == "Provider-keyed Copilot")
        #expect(FileManager.default.fileExists(atPath: copilotHome.path))
    }

    @Test("Copilot utility runtime extracts text from JSON stream")
    func copilotUtilityRuntimeExtractsText() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Planning via Copilot"}}'
        exit 0
        """
        try script.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopilot.path)

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            "Plan the work",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path
            ),
            toolMode: .readOnly
        )

        #expect(result.exitCode == 0)
        #expect(result.output == "Planning via Copilot")
    }

    @Test("Copilot utility prompt obeys strict sandbox write boundary")
    func copilotUtilityPromptObeysStrictSandboxWriteBoundary() async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-sandbox-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        let leakRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AstraUtilitySandboxDeny-\(UUID().uuidString)", isDirectory: true)
        let marker = leakRoot.appendingPathComponent("marker.txt")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: leakRoot)
        }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        set -e
        mkdir -p \(shellSingleQuoted(leakRoot.path))
        printf leak > \(shellSingleQuoted(marker.path))
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Sandbox escaped"}}'
        exit 0
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        await withStrictSandbox {
            let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
                "Summarize diff",
                workspacePath: root.path,
                configuration: AgentUtilityRuntimeConfiguration(
                    runtime: .copilotCLI,
                    model: "gpt-5",
                    copilotPath: fakeCopilot.path,
                    copilotHome: copilotHome.path,
                    timeoutSeconds: 3
                ),
                toolMode: .readOnly
            )

            #expect(result.exitCode != 0)
            #expect(!fm.fileExists(atPath: marker.path))
        }
    }

    @Test("Codex utility runtime creates provider home and extracts text from JSON stream")
    func codexUtilityRuntimeCreatesProviderHomeAndExtractsText() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-codex-\(UUID().uuidString)", isDirectory: true)
        let fakeCodex = root.appendingPathComponent("codex")
        let argsFile = root.appendingPathComponent("codex-args.txt")
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        if [ ! -d "$CODEX_HOME" ]; then
          printf 'missing CODEX_HOME directory\\n' >&2
          exit 42
        fi
        printf '%s\\n' '{"type":"assistant.message_delta","delta":"Codex utility response"}'
        exit 0
        """
        try writeExecutableScript(at: fakeCodex, contents: script)

        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(fakeCodex.path, for: .codexCLI)
        settings.setHomeDirectory(codexHome.path, for: .codexCLI)

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            "Plan the work",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .codexCLI,
                model: "gpt-5.5",
                providerSettings: settings
            ),
            toolMode: .readOnly
        )

        #expect(result.exitCode == 0)
        #expect(result.output == "Codex utility response")
        #expect(FileManager.default.fileExists(atPath: codexHome.path))
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("--sandbox\nread-only"))
        #expect(args.contains("workspace-write") == false)
    }

    @Test("Spec chat can use a non-Claude utility runtime")
    func specChatCanUseNonClaudeUtilityRuntime() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-spec-copilot-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let argsFile = root.appendingPathComponent("args.txt")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot spec response"}}'
        exit 0
        """
        try script.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopilot.path)

        let result = await SpecEngine.chat(
            messages: [(role: "user", content: "Plan the work")],
            workspacePath: root.path,
            utilityRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path
            )
        )

        guard case .success(let response) = result else {
            Issue.record("Expected fake Copilot utility success")
            return
        }

        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(response == "Copilot spec response")
        #expect(args.contains("--model"))
        #expect(args.contains("gpt-5"))
        #expect(args.contains("--allow-tool"))
        #expect(args.contains("read"))
    }

    // MARK: - Stdin + utility helper regressions

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func stdinGuardPrefix() -> String {
        """
        /usr/bin/python3 - <<'PY'
        import os
        import select
        import sys

        ready, _, _ = select.select([sys.stdin], [], [], 0.25)
        if not ready:
            sys.stderr.write("STDIN_OPEN\\n")
            sys.exit(99)
        if os.read(0, 1):
            sys.stderr.write("STDIN_DATA\\n")
            sys.exit(98)
        PY
        """
    }

    private func modernCopilotHelpText() -> String {
        """
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --no-custom-instructions --allow-all-tools required for non-interactive mode
        """
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func withStrictSandbox(_ body: () async -> Void) async {
        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let readScopeKey = AppStorageKeys.sandboxReadScope
        let originalEnforcement = UserDefaults.standard.string(forKey: enforcementKey)
        let originalReadScope = UserDefaults.standard.string(forKey: readScopeKey)
        UserDefaults.standard.set(ExecutionSandboxEnforcement.strict.rawValue, forKey: enforcementKey)
        UserDefaults.standard.set(ExecutionSandboxReadScope.enforce.rawValue, forKey: readScopeKey)
        defer {
            if let originalEnforcement { UserDefaults.standard.set(originalEnforcement, forKey: enforcementKey) }
            else { UserDefaults.standard.removeObject(forKey: enforcementKey) }
            if let originalReadScope { UserDefaults.standard.set(originalReadScope, forKey: readScopeKey) }
            else { UserDefaults.standard.removeObject(forKey: readScopeKey) }
        }
        await body()
    }

    @Test("Claude utility uses closed stdin")
    func claudeUtilityUsesClosedStdin() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-claude-stdin-\(UUID().uuidString)", isDirectory: true)
        let fakeClaude = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        \(stdinGuardPrefix())
        printf '%s\\n' 'ASTRA_COMMIT_SUGGESTION {"subject":"stdin ok","body":"","type":"test"}'
        exit 0
        """
        try writeExecutableScript(at: fakeClaude, contents: script)

        let start = Date()
        let result = await AgentRuntimeAdapterRegistry.adapter(for: .claudeCode).runUtilityPrompt(
            "Summarize diff",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .claudeCode,
                model: "claude-haiku-4-5-20251001",
                claudePath: fakeClaude.path
            ),
            toolMode: .readOnly
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 15, "Claude utility did not complete promptly: \(elapsed)s")
        #expect(result.exitCode == 0)
        #expect(result.output.contains("stdin ok"))
    }

    @Test("Copilot utility uses closed stdin")
    func copilotUtilityUsesClosedStdin() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-stdin-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        \(stdinGuardPrefix())
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot stdin ok"}}'
        exit 0
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        let start = Date()
        let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
            "Summarize diff",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path
            ),
            toolMode: .readOnly
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 15, "Copilot utility did not complete promptly: \(elapsed)s")
        #expect(result.exitCode == 0)
        #expect(result.output == "Copilot stdin ok")
    }

    @Test("Antigravity utility uses closed stdin")
    func antigravityUtilityUsesClosedStdin() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-agy-stdin-\(UUID().uuidString)", isDirectory: true)
        let fakeAgy = root.appendingPathComponent("agy")
        let providerHome = root.appendingPathComponent("agy-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        \(stdinGuardPrefix())
        printf '%s\\n' 'ASTRA_COMMIT_SUGGESTION {"subject":"agy stdin ok","body":"","type":"test"}'
        exit 0
        """
        try writeExecutableScript(at: fakeAgy, contents: script)

        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(fakeAgy.path, for: .antigravityCLI)
        settings.setHomeDirectory(providerHome.path, for: .antigravityCLI)

        let start = Date()
        let result = await AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).runUtilityPrompt(
            "Summarize diff",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .antigravityCLI,
                model: "default",
                providerSettings: settings
            ),
            toolMode: .readOnly
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 15, "Antigravity utility did not complete promptly: \(elapsed)s")
        #expect(result.exitCode == 0)
        #expect(result.output.contains("agy stdin ok"))
    }

    @Test("Copilot utility passes no-custom-instructions for git helper")
    func copilotUtilityPassesNoCustomInstructions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-args-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let argsFile = root.appendingPathComponent("args.txt")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Args captured"}}'
        exit 0
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
            "Summarize diff",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path
            ),
            toolMode: .readOnly
        )

        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(result.exitCode == 0)
        #expect(args.contains("--no-custom-instructions"))
    }

    @Test("Copilot utility timeout returns instead of leaving Goal Mode thinking")
    func copilotUtilityTimeoutReturns() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-timeout-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        sleep \(Self.longRunningHelperSleepSeconds) &
        wait
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        let start = Date()
        let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
            "Define the executable goal and plan now",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path,
                timeoutSeconds: 0.2
            ),
            toolMode: .readOnly
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < Self.fullSuiteUtilityDeadlineSeconds, "Timed-out Copilot utility did not return promptly: \(elapsed)s")
        #expect(result.exitCode == -1)
        #expect(result.error.contains("timed out"))
    }

    @Test("Copilot utility returns after completed stream output even if wrapper stays alive")
    func copilotUtilityReturnsAfterCompletedStreamOutput() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-stream-complete-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        printf '%s\\n' '{"type":"assistant.message","data":{"content":"Goal plan ready"}}'
        printf '%s\\n' '{"type":"assistant.turn_end"}'
        sleep \(Self.longRunningHelperSleepSeconds) &
        wait
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        let start = Date()
        let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
            "Define the executable goal and plan now",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path,
                timeoutSeconds: 3
            ),
            toolMode: .readOnly
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < Self.fullSuiteUtilityDeadlineSeconds, "Completed Copilot utility stream waited for wrapper exit: \(elapsed)s")
        #expect(result.exitCode == 0)
        #expect(result.output == "Goal plan ready")
    }

    @Test("Copilot utility prefers final message when stream repeats delta text")
    func copilotUtilityPrefersFinalMessageWhenStreamRepeatsDeltaText() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-stream-final-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"deltaContent":"{\\"action\\":\\"create_skill\\",\\"name\\":\\"Slash Smoke Skill\\"}"}}'
        printf '%s\\n' '{"type":"assistant.message","data":{"content":"{\\"action\\":\\"create_skill\\",\\"name\\":\\"Slash Smoke Skill\\"}"}}'
        printf '%s\\n' '{"type":"assistant.turn_end"}'
        exit 0
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
            "Return a JSON action",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path,
                timeoutSeconds: 3
            ),
            toolMode: .readOnly
        )

        #expect(result.exitCode == 0)
        #expect(result.output == #"{"action":"create_skill","name":"Slash Smoke Skill"}"#)
    }

    @Test("Copilot utility keeps streamed text when result summary follows")
    func copilotUtilityKeepsStreamedTextWhenResultSummaryFollows() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-copilot-result-summary-\(UUID().uuidString)", isDirectory: true)
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(modernCopilotHelpText())
        HELP
          exit 0
        fi
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"deltaContent":"Actual provider response"}}'
        printf '%s\\n' '{"type":"result","data":{"usage":{"input_tokens":1,"output_tokens":1},"summary":"done"}}'
        exit 0
        """
        try writeExecutableScript(at: fakeCopilot, contents: script)

        let result = await AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).runUtilityPrompt(
            "Return the provider response",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path,
                timeoutSeconds: 3
            ),
            toolMode: .readOnly
        )

        #expect(result.exitCode == 0)
        #expect(result.output == "Actual provider response")
    }
}
