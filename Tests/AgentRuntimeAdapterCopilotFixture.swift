import Foundation
@testable import ASTRA

enum CopilotAdapterFixture {
    static func writeExecutable(
        in directory: URL,
        supportsAdditionalMCPConfig: Bool = true
    ) async throws -> String {
        let url = directory.appendingPathComponent("copilot")
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(helpText(supportsAdditionalMCPConfig: supportsAdditionalMCPConfig))
        HELP
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        exit 0
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        _ = try await CopilotCLIRuntime.requiredCapabilities(executablePath: url.path)
        return url.path
    }

    static func helpText(supportsAdditionalMCPConfig: Bool = true) -> String {
        let mcpConfigHelp = supportsAdditionalMCPConfig ? " --additional-mcp-config CONFIG" : ""
        return "--allow-tool TOOL --available-tools=TOOLS --excluded-tools=TOOLS --output-format=FORMAT --stream=MODE --no-ask-user --no-custom-instructions --effort LEVEL\(mcpConfigHelp)"
    }

}
