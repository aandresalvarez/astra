import Foundation

enum PromptContextSectionProviderID: String, Sendable, CaseIterable {
    case agentTeam = "agent-team"
    case currentTask = "current-task"
    case followUpIntro = "follow-up-intro"
    case threadState = "thread-state"
    case contextSourceIndex = "context-source-index"
    case nativeContinuation = "native-continuation"
    case conversationHistory = "conversation-history"
    case changedFiles = "changed-files"
    case workspaceInstructions = "workspace-instructions"
    case memories = "memories"
    case recentTasks = "recent-tasks"
    case workspaceEnvironment = "workspace-environment"
    case taskOutputFolder = "task-output-folder"
    case taskDetails = "task-details"
    case followUpContext = "follow-up-context"
    case capabilities = "capabilities"
    case browser = "browser"
    case documentReader = "document-reader"
    case astraRunProtocol = "astra-run-protocol"
    case historyLookupRule = "history-lookup-rule"
    case followUpRequest = "follow-up-request"
    case currentTaskReminder = "current-task-reminder"
}

enum PromptContextSectionProviderRegistry {
    static func providerIDs(for mode: PromptAssemblyMode) -> [PromptContextSectionProviderID] {
        switch mode {
        case .initialRun:
            [
                .agentTeam,
                .currentTask,
                .threadState,
                .workspaceInstructions,
                .memories,
                .recentTasks,
                .workspaceEnvironment,
                .taskOutputFolder,
                .taskDetails,
                .capabilities,
                .browser,
                .documentReader,
                .astraRunProtocol,
                .currentTaskReminder
            ]
        case .followUp:
            [
                .followUpIntro,
                .threadState,
                .contextSourceIndex,
                .nativeContinuation,
                .conversationHistory,
                .changedFiles,
                .taskOutputFolder,
                .followUpContext,
                .capabilities,
                .browser,
                .memories,
                .astraRunProtocol,
                .historyLookupRule,
                .followUpRequest
            ]
        }
    }
}

struct PromptContextSectionProviderContext {
    let mode: PromptAssemblyMode
    let task: AgentTask
    let followUpMessage: String
    let capabilityScope: TaskCapabilityPromptScope
}

struct PromptContextSectionProviderState {
    var includedExactSessionTranscript = false
}

@MainActor
protocol PromptContextSectionProvider {
    var id: PromptContextSectionProviderID { get }

    func appendSections(
        for context: PromptContextSectionProviderContext,
        state: inout PromptContextSectionProviderState,
        to sections: inout [PromptContextSection]
    )
}
