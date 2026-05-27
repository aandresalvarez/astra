import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Utility Runtime")
struct AgentUtilityRuntimeTests {
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
}
