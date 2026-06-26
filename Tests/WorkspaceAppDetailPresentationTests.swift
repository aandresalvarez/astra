import Foundation
import SwiftData
import Testing
@testable import ASTRA

// F7: the detail-area routing decision for Workspace App surfaces. These are the
// unit-testable parts of the wiring (the SwiftUI rendering itself is verified by
// running the app).
@Suite("Content Detail Presentation (Workspace Apps / F7)")
struct WorkspaceAppDetailPresentationTests {

    @MainActor
    private func makeApp(_ workspace: Workspace) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "agentic-workflow",
            name: "Agentic Workflow",
            manifestRelativePath: "m.json",
            appDirectoryRelativePath: "d",
            manifestDigest: "digest"
        )
    }

    @MainActor
    @Test("a selected workspace app resolves to the app detail surface")
    func selectedAppResolvesToAppDetail() {
        let workspace = Workspace(name: "WS", primaryPath: "/tmp/f7")
        let presentation = ContentDetailPresentation.resolve(
            selectedTask: nil,
            effectiveWorkspace: workspace,
            isComposingTask: false,
            selectedWorkspaceApp: makeApp(workspace)
        )
        #expect(presentation == .workspaceApp)
    }

    @MainActor
    @Test("composing a workspace app resolves to the App Studio")
    func composingResolvesToStudio() {
        let workspace = Workspace(name: "WS", primaryPath: "/tmp/f7")
        let presentation = ContentDetailPresentation.resolve(
            selectedTask: nil,
            effectiveWorkspace: workspace,
            isComposingTask: false,
            selectedWorkspaceApp: nil,
            isComposingWorkspaceApp: true
        )
        #expect(presentation == .workspaceAppStudio)
    }

    @MainActor
    @Test("a selected task takes precedence over a selected app")
    func taskTakesPrecedenceOverApp() {
        let workspace = Workspace(name: "WS", primaryPath: "/tmp/f7")
        let task = AgentTask(title: "T", goal: "G", workspace: workspace)
        task.status = .queued
        let presentation = ContentDetailPresentation.resolve(
            selectedTask: task,
            effectiveWorkspace: workspace,
            isComposingTask: false,
            selectedWorkspaceApp: makeApp(workspace)
        )
        #expect(presentation == .existingTask)
    }
}
