import Testing
@testable import ASTRA

@Suite("Workspace App Studio Draft Support")
struct WorkspaceAppStudioDraftSupportTests {

    @MainActor
    @Test("App Studio task drafts use dedicated presentation and chat context")
    func appStudioDraftUsesDedicatedPresentationAndChatContext() throws {
        let workspace = Workspace(
            name: "Clinical Ops",
            primaryPath: "/tmp/clinical-ops",
            instructions: "Track reconciliation work."
        )
        let draft = WorkspaceAppStudioGenerationTaskBuilder.draft(
            userPrompt: "Build a reconciliation app.",
            workspace: workspace,
            packages: [],
            existingAppManifest: #"{"name":"Existing"}"#
        )
        let task = AgentTask(title: draft.title, goal: draft.goal, workspace: workspace)
        task.status = .draft
        task.inputs = draft.inputs
        task.constraints = draft.constraints
        task.acceptanceCriteria = draft.acceptanceCriteria

        #expect(WorkspaceAppStudioDraftSupport.isWorkspaceAppStudioDraft(task))

        let presentation = ChatPanelDraftPresentation.resolve(
            draftTask: task,
            fallbackPrompt: "What idea should we test?"
        )
        #expect(presentation.navigationTitle == "Design Workspace App: Clinical Ops")
        #expect(presentation.heroTitle == "Design the Clinical Ops app")
        #expect(presentation.composerPlaceholder == "Describe the app workflow, users, data, or approval gates...")
        #expect(presentation.submitTitle == "Refine")
        #expect(presentation.usesWorkspaceAppStudioEmptyState)

        let context = try #require(WorkspaceAppStudioDraftSupport.conversationContext(for: task))
        #expect(context.contains("Workspace App Studio draft"))
        #expect(context.contains("Workspace App Studio context:"))
        #expect(context.contains("Build a reconciliation app."))
        #expect(context.contains("Proposes the app storage, views, actions, automations, and permission mode."))
    }

    @MainActor
    @Test("Regular drafts keep generic composer presentation")
    func regularDraftKeepsGenericComposerPresentation() {
        let workspace = Workspace(name: "Git", primaryPath: "/tmp/git")
        let task = AgentTask(title: "Fix CI", goal: "Fix CI", workspace: workspace)
        task.status = .draft

        #expect(!WorkspaceAppStudioDraftSupport.isWorkspaceAppStudioDraft(task))

        let presentation = ChatPanelDraftPresentation.resolve(
            draftTask: task,
            fallbackPrompt: "What idea should we test?"
        )
        #expect(presentation.navigationTitle == "Draft")
        #expect(presentation.heroTitle == "What idea should we test?")
        #expect(presentation.composerPlaceholder == "Describe a task or ask a question...")
        #expect(presentation.submitTitle == "Run")
        #expect(!presentation.usesWorkspaceAppStudioEmptyState)
        #expect(WorkspaceAppStudioDraftSupport.conversationContext(for: task) == nil)
    }

    @MainActor
    @Test("App Studio conversation updates keep generated context input")
    func appStudioConversationUpdatesKeepGeneratedContextInput() {
        let workspace = Workspace(name: "Clinical Ops", primaryPath: "/tmp/clinical-ops")
        let draft = WorkspaceAppStudioGenerationTaskBuilder.draft(workspace: workspace, packages: [])
        let task = AgentTask(title: draft.title, goal: draft.goal, workspace: workspace)
        task.status = .draft
        task.inputs = draft.inputs

        let merged = WorkspaceAppStudioDraftSupport.inputsAfterConversationUpdate(
            task: task,
            attachedFiles: ["/tmp/schema.json", "/tmp/schema.json", "/tmp/mock.png"]
        )

        #expect(merged.first == draft.inputs.first)
        #expect(merged.suffix(2) == ["/tmp/schema.json", "/tmp/mock.png"])
    }

    @MainActor
    @Test("App Studio conversation updates keep generated title and goal")
    func appStudioConversationUpdatesKeepGeneratedTitleAndGoal() {
        let workspace = Workspace(name: "Clinical Ops", primaryPath: "/tmp/clinical-ops")
        let draft = WorkspaceAppStudioGenerationTaskBuilder.draft(workspace: workspace, packages: [])
        let task = AgentTask(title: draft.title, goal: draft.goal, workspace: workspace)
        task.status = .draft
        task.inputs = draft.inputs

        let metadata = WorkspaceAppStudioDraftSupport.metadataAfterConversationUpdate(
            task: task,
            firstMessage: "Make it dashboard-first"
        )

        #expect(metadata.title == draft.title)
        #expect(metadata.goal == draft.goal)

        let regular = AgentTask(title: "Draft", goal: "Old goal", workspace: workspace)
        regular.status = .draft
        let regularMetadata = WorkspaceAppStudioDraftSupport.metadataAfterConversationUpdate(
            task: regular,
            firstMessage: "Make it dashboard-first"
        )

        #expect(regularMetadata.title == "Make it dashboard-first")
        #expect(regularMetadata.goal == "Make it dashboard-first")
    }
}
