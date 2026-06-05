import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Utility Runtime")
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

    @Test("Local MLX utility runtime runs a text-only prompt through the helper")
    func localMLXUtilityRuntimeRunsTextOnlyPromptThroughHelper() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-utility-local-mlx-\(UUID().uuidString)", isDirectory: true)
        let fakeHelper = root.appendingPathComponent("astra-local-model")
        let argsFile = root.appendingPathComponent("args.txt")
        let requestCapture = root.appendingPathComponent("request.json")
        let envCapture = root.appendingPathComponent("env.txt")
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s\\n' "$ASTRA_LOCAL_MODEL_EXPERIMENTAL_TOOLS" > '\(envCapture.path)'
        request=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--request-file" ]; then
            shift
            request="$1"
            cp "$request" '\(requestCapture.path)'
          fi
          shift
        done
        printf '%s\\n' '{"v":1,"type":"phase","message":"Loading local utility model."}'
        printf '%s\\n' '{"v":1,"type":"text","text":"Local utility response"}'
        printf '%s\\n' '{"v":1,"type":"stats","inputTokens":4,"outputTokens":3}'
        printf '%s\\n' '{"v":1,"type":"completed","summary":"Completed summary"}'
        exit 0
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutableScript(at: fakeHelper, contents: script)

        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(fakeHelper.path, for: .localMLX)
        settings.setHomeDirectory(modelDirectory.path, for: .localMLX)

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            "Summarize the pasted paragraph.",
            workspacePath: root.path,
            configuration: AgentUtilityRuntimeConfiguration(
                runtime: .localMLX,
                model: LocalMLXRuntime.defaultModel,
                providerSettings: settings
            ),
            toolMode: .readOnly
        )

        #expect(result.exitCode == 0)
        #expect(result.output == "Local utility response")
        #expect(result.error.isEmpty)

        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("run"))
        #expect(args.contains("--request-file"))
        #expect(try String(contentsOf: envCapture, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "0")

        let request = try JSONDecoder().decode(
            LocalModelRunRequest.self,
            from: Data(contentsOf: requestCapture)
        )
        #expect(request.prompt == "Summarize the pasted paragraph.")
        #expect(request.model == LocalMLXRuntime.defaultModel)
        #expect(request.modelDirectory == modelDirectory.path)
        #expect(request.permissionMode == PermissionPolicy.restricted.rawValue)
        #expect(request.experimentalToolsEnabled == false)
        #expect(request.keepWarmTTLSeconds == 0)
        #expect(request.messages.first?.role == "system")
        #expect(request.messages.first?.content.contains("Private Local Chat utility") == true)
        #expect(request.messages.first?.content.contains("Do not claim you used files") == true)
    }
}
