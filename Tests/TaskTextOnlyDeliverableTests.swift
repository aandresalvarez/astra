import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Text-only deliverable intent")
@MainActor
struct TaskTextOnlyDeliverableTests {
    nonisolated static let textRequests = [
        "ASTRA_TEXT_ONLY_REPRO. Write five numbered sentences about testing a desktop app. Answer only in this chat.",
        "Write five numbered sentences about testing a desktop app.",
        "Write about a desktop app.",
        "Write what the app does.",
        "Put the app in the foreground.",
        "Write exactly 60 numbered lines. Each line should contain a different short sentence about testing a desktop app with a large synthetic chat history.",
        "Write a summary of the app's UI.",
        "Write an explanation of how to build a website.",
        "Explain how to build a website.",
        "Write an explanation: how to build a website.",
        "How do I create an app?",
        "Write a tutorial on how to create a website.",
        "Review the app and write five sentences about its UI.",
        "Create a document describing a dashboard.",
        "Generate a checklist for reviewing an HTML file.",
        "Write a report about generating a CSV file.",
        "Write a summary about an app and do not create a file.",
        "Do not create a file and build an app.",
        "Do not create a file; write five sentences about an app."
    ]

    @Test("An answer's subject does not become a file requirement", arguments: textRequests)
    func textRequestsDoNotRequireArtifacts(goal: String) {
        let task = AgentTask(title: "Text response", goal: goal)
        #expect(!TaskDeliverableExpectation.requiresDeliverableArtifact(task))
    }

    @Test("Creation requests retain their deliverable requirement", arguments: [
        "Build a local app so the team can install it.",
        "Generate a what-if dashboard.",
        "Create an about web page.",
        "Write a how-to app.",
        "Put this in files.",
        "Create a UI for browsing tickets.",
        "Createan app for the team.",
        "Create:\n- a desktop app",
        "Create the following:\n- a UI for tickets",
        "Write a script explaining how an app works.",
        "Write a paragraph into a text file about the app.",
        "Write a paragraph about the app into a text file.",
        "Write a summary about the app as a file.",
        "Write five sentences about an app and create a website.",
        "Explain how apps work and create a CSV file.",
        "Write a short summary and build a local app.",
        "Write a paragraph not longer than five lines and create a website.",
        "Write a summary about an app, then save it as a file.",
        "Write a summary about an app. Save it as notes.txt."
    ])
    func creationRequestsStillRequireArtifacts(goal: String) {
        #expect(TaskDeliverableExpectation.requiresDeliverableArtifact(AgentTask(title: "Task", goal: goal)))
    }

    @Test("Creation headers govern labeled and numbered list items", arguments: [
        "Create the following artifacts:\n- a website",
        "Create:\n1. a website",
        "Create the following outputs:\n1) a website",
        "Generate these deliverables:\n+ a script",
        "Build the following items:\n• a dashboard",
        "Create artifacts:\n1. a short summary about scheduling\n2. a website",
        "Write the following files:\n1. a short summary about an app",
        "Create:\n1. five sentences about an app\n2. a website",
        "Create the following artifacts: 12. a website",
        "Create:\r\n1. a website",
        "Create:\n  1) a website",
        "Do not create the following:\n1. a website\n\nCreate:\n1. a dashboard"
    ])
    func creationListsRequireArtifacts(goal: String) {
        #expect(TaskDeliverableExpectation.requiresStandaloneArtifact(AgentTask(title: "Task", goal: goal)))
    }

    @Test("List normalization preserves negation, text objects, and instruction boundaries", arguments: [
        "Do not create the following artifacts:\n1. a website",
        "Never generate these outputs:\n- a script",
        "Do not write the following files:\n1. a short summary about an app",
        "Write the following:\n1. five sentences about an app\n2. a summary of a website",
        "Explain the following:\n1. how to build a website",
        "Explain how to create the following artifacts:\n1. a website",
        "Write an explanation:\n1. how to build a website",
        "Write the following:\n1. a summary about testing\n\nA website is the topic.",
        "Write the following:\n1. a summary about testing\nA website is the topic."
    ])
    func listsDoNotInventArtifacts(goal: String) {
        #expect(!TaskDeliverableExpectation.requiresDeliverableArtifact(AgentTask(title: "Task", goal: goal)))
    }

    @Test("Context fields cannot lend an artifact noun to a text request")
    func contextDoesNotChangeTextRequest() {
        let task = AgentTask(title: "Desktop app overview", goal: "Write five numbered sentences.")
        task.inputs = ["Topic: a desktop app with an HTML user interface"]
        #expect(!TaskDeliverableExpectation.requiresDeliverableArtifact(task))
    }

    @Test("Text requests neither rewrite the provider prompt nor block successful completion", arguments: [
        "Write five numbered sentences about testing a desktop app. Answer only in this chat.",
        "Write an explanation of how to build a website.",
        "Write the following:\n1. five sentences about an app\n2. a summary of a website"
    ])
    func textRequestCompletesWithoutAFile(goal: String) async throws {
        let fixture = try fixture(goal: goal)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            withExtendedLifetime(fixture.container) {}
        }
        fixture.run.setOutput("Here is the requested text response.")
        #expect(!AgentPromptBuilder.buildPrompt(for: fixture.task).contains("Artifact first-action requirement:"))
        let verification = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task, run: fixture.run, modelContext: fixture.container.mainContext
        )
        #expect(verification.profile == .notRequired)
        #expect(verification.canComplete)
        #expect(!TaskCompletionPolicy.decideSuccessfulCompletion(task: fixture.task, run: fixture.run).shouldBlockCompletion)
    }

    @Test("Real creation still rewrites the prompt and fails verification when its file is missing", arguments: [
        "Write five sentences about an app and create a website.",
        "Create the following artifacts:\n- a website",
        "Create:\n1. a website",
        "Write the following files:\n1. a short summary about an app",
        "Create:\n1. a summary about testing\n2. a website"
    ])
    func missingArtifactIsStillBlocked(goal: String) async throws {
        let fixture = try fixture(goal: goal)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            withExtendedLifetime(fixture.container) {}
        }
        fixture.run.setOutput("Here are five sentences.")
        #expect(AgentPromptBuilder.buildPrompt(for: fixture.task).contains("Artifact first-action requirement:"))
        let verification = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task, run: fixture.run, modelContext: fixture.container.mainContext
        )
        #expect(!verification.canComplete)
        #expect(TaskCompletionPolicy.decideSuccessfulCompletion(task: fixture.task, run: fixture.run).shouldBlockCompletion)
    }

    private func fixture(goal: String) throws -> (root: URL, container: ModelContainer, task: AgentTask, run: TaskRun) {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-text-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Text intent", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: goal, workspace: workspace)
        let run = TaskRun(task: task)
        container.mainContext.insert(workspace)
        container.mainContext.insert(task)
        container.mainContext.insert(run)
        try container.mainContext.save()
        return (root, container, task, run)
    }
}
