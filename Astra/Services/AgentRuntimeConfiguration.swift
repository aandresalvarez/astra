import Foundation
import ASTRACore

struct AgentRuntimeConfiguration {
    var claudePath: String
    var copilotPath: String
    var copilotHome: String
    var defaultRuntimeID: AgentRuntimeID

    init(
        claudePath: String = RuntimePathResolver.detectClaudePath(),
        copilotPath: String = CopilotCLIRuntime.detectPath(),
        copilotHome: String = CopilotCLIRuntime.channelHome(),
        defaultRuntimeID: AgentRuntimeID = .claudeCode
    ) {
        self.claudePath = claudePath
        self.copilotPath = copilotPath
        self.copilotHome = copilotHome
        self.defaultRuntimeID = defaultRuntimeID
    }

    func selectedRuntime(for task: AgentTask) -> AgentRuntimeID {
        if let configured = task.runtimeID.flatMap(AgentRuntimeID.init(rawValue:)) {
            return configured
        }
        return defaultRuntimeID
    }

    mutating func resolvedCopilotPath() -> String {
        if copilotPath.isEmpty {
            copilotPath = CopilotCLIRuntime.detectPath()
        }
        return copilotPath
    }
}
