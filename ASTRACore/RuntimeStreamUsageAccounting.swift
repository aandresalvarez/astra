import Foundation

/// One process-scoped normalization boundary shared by task and utility streams.
/// Native frames remain available to execution-proof inspection before projection.
public final class RuntimeStreamUsageAccounting: @unchecked Sendable {
    private let claude: ClaudeStreamAccounting?
    private let copilot: CopilotStreamAccounting?
    private let openCode: OpenCodeStreamAccounting?
    public init(runtime: AgentRuntimeID, sessionInput: Int = 0, sessionOutput: Int = 0) {
        claude = runtime == .claudeCode ? ClaudeStreamAccounting() : nil
        copilot = runtime == .copilotCLI ? CopilotStreamAccounting(sessionInput: sessionInput, sessionOutput: sessionOutput) : nil
        openCode = runtime == .openCodeCLI ? OpenCodeStreamAccounting() : nil
    }
    public var hasInvalidUsage: Bool {
        claude?.hasInvalidUsage == true || copilot?.hasInvalidUsage == true || openCode?.hasInvalidUsage == true
    }
    public func normalize(_ line: String) -> (line: String, invalidUsage: Bool) {
        claude?.normalize(line) ?? copilot?.normalize(line) ?? openCode?.normalize(line) ?? (line, false)
    }
}
