import Foundation

struct ChatPanelDraftPresentation: Equatable {
    var navigationTitle: String
    var heroTitle: String
    var heroSubtitle: String
    var composerPlaceholder: String
    var submitTitle: String
    var primaryActionTitle: String
    var primaryActionPrompt: String
    var usesWorkspaceAppStudioEmptyState: Bool

    static func resolve(draftTask: AgentTask?, fallbackPrompt: String) -> ChatPanelDraftPresentation {
        guard WorkspaceAppStudioDraftSupport.isWorkspaceAppStudioDraft(draftTask) else {
            return ChatPanelDraftPresentation(
                navigationTitle: draftTask == nil ? "New Task" : "Draft",
                heroTitle: fallbackPrompt,
                heroSubtitle: "",
                composerPlaceholder: "Describe a task or ask a question...",
                submitTitle: "Run",
                primaryActionTitle: "",
                primaryActionPrompt: "",
                usesWorkspaceAppStudioEmptyState: false
            )
        }

        let workspaceName = WorkspaceAppStudioDraftSupport.workspaceName(for: draftTask)
        return ChatPanelDraftPresentation(
            navigationTitle: draftTask?.title ?? "Workspace App Draft",
            heroTitle: "Design the \(workspaceName) app",
            heroSubtitle: "Workspace instructions, recent tasks, artifacts, and capabilities are already attached.",
            composerPlaceholder: "Describe the app workflow, users, data, or approval gates...",
            submitTitle: "Refine",
            primaryActionTitle: "Generate app plan",
            primaryActionPrompt: WorkspaceAppStudioDraftSupport.defaultPlanningPrompt(for: draftTask),
            usesWorkspaceAppStudioEmptyState: true
        )
    }
}
