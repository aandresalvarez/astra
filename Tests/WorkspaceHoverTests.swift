import AppKit
import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace hover and disclosure")
@MainActor
struct WorkspaceHoverTests {
    @Test("Crossing the gap from the row to the card keeps options open")
    func pointerCrossing() {
        var state = WorkspaceHoverState()
        state.updateRow(true)
        #expect(state.wantsCard)
        state.updateRow(false)
        #expect(!state.wantsCard)
        state.cardHovered = true
        #expect(state.wantsCard)
        state.cardHovered = false
        #expect(!state.wantsCard)
        #expect(WorkspaceHoverState.closeDelay > .zero)
        #expect(WorkspaceHoverState.openDelay > WorkspaceHoverState.closeDelay)
    }

    @Test("Click or Escape dismissal stays dismissed until the pointer leaves and returns")
    func dismissalDoesNotImmediatelyReopen() {
        var state = WorkspaceHoverState(rowHovered: true, cardHovered: true)
        state.dismiss()
        #expect(!state.wantsCard)
        state.updateRow(true)
        #expect(!state.wantsCard)
        state.updateRow(false)
        state.updateRow(true)
        #expect(state.wantsCard)
    }

    @Test("Leaving the card and returning to its row keeps options available")
    func cardToRow() {
        var state = WorkspaceHoverState(cardHovered: true)
        state.updateRow(true)
        state.cardHovered = false
        #expect(state.wantsCard)
        state.updateRow(false)
        #expect(!state.wantsCard)
    }

    @Test("Task count includes completed tasks and ignores the search filter")
    func countsAllTasks() {
        let workspace = Workspace(name: "Project", primaryPath: "/tmp/project")
        let other = Workspace(name: "Other", primaryPath: "/tmp/other")
        let active = AgentTask(title: "Active", goal: "")
        active.workspace = workspace
        let completed = AgentTask(title: "Completed", goal: "")
        completed.isDone = true
        completed.workspace = workspace
        let elsewhere = AgentTask(title: "Elsewhere", goal: "")
        elsewhere.workspace = other
        let index = SidebarTaskIndex(tasks: [active, completed, elsewhere], searchText: "no match")
        #expect(index.taskCount(in: workspace) == 2)
        #expect(index.taskCount(in: other) == 1)
        #expect(SidebarTaskIndex.empty.taskCount(in: workspace) == 0)
    }

    @Test("Disclosure handler cannot replace the task or workspace selection")
    func disclosureDoesNotNavigate() throws {
        let source = try sidebarSource()
        let start = try #require(source.range(of: "private func toggleWorkspaceOpenState("))
        let end = try #require(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let handler = String(source[start.lowerBound..<end.upperBound])
        #expect(handler.contains("WorkspaceSidebarAccordion.toggling("))
        #expect(!handler.contains("selectedTask ="))
        #expect(!handler.contains("selectedWorkspace ="))
        #expect(!handler.contains("openWorkspace("))
    }

    @Test("Configuration explicitly routes to the full workspace screen")
    func configurationRoute() throws {
        let source = try sidebarSource()
        #expect(source.contains("openConfiguration: { openWorkspace(workspace) }"))
        // The old details sheet must not be the hover configuration route.
        let start = try #require(source.range(of: "private func workspaceActions("))
        let end = try #require(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        #expect(!source[start.lowerBound..<end.upperBound].contains("onEditWorkspace"))
    }

    @Test("Folder states render different silhouettes without a disclosure arrow")
    func folderStates() throws {
        func pixels(expanded: Bool) throws -> Data {
            let renderer = ImageRenderer(content: WorkspaceFolderIcon(isExpanded: expanded)
                .font(.system(size: 13)).foregroundStyle(.black).frame(width: 24, height: 24).background(.white))
            let image = try #require(renderer.nsImage)
            return try #require(image.tiffRepresentation)
        }
        #expect(try pixels(expanded: false) != pixels(expanded: true))
        // Keep the lower-left flap: starting a new subpath here accidentally
        // turns the open folder into a triangle resembling a paper plane.
        #expect(WorkspaceFolderIcon.openFolderPath(size: CGSize(width: 100, height: 100))
            .contains(CGPoint(x: 20, y: 80)))
        let source = try sidebarSource()
        let start = try #require(source.range(of: "private func workspaceRow(for"))
        let end = try #require(source.range(of: "private func workspaceRowFill", range: start.upperBound..<source.endIndex))
        let row = source[start.lowerBound..<end.lowerBound]
        #expect(row.contains("WorkspaceFolderRow("))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folderRow = try String(contentsOf: root.appendingPathComponent("Astra/Views/WorkspaceFolderRow.swift"), encoding: .utf8)
        #expect(folderRow.contains("WorkspaceFolderIcon(isExpanded: isExpanded)"))
        #expect(!folderRow.contains("chevron.right"))
        #expect(!row.contains("chevron.right"))
        #expect(row.contains(".workspaceHoverCard(isHovered: isHovered)"))
    }

    private func sidebarSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Astra/Views/TaskSidebarView.swift"), encoding: .utf8)
    }
}
