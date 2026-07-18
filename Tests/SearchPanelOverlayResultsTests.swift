import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Search Panel Overlay Results")
struct SearchPanelOverlayResultsTests {
    @Test("recent tasks are newest first and capped")
    func recentTasksAreNewestFirstAndCapped() {
        let tasks = (0..<11).map { index in
            makeTask(title: "Task \(index)", updatedAt: TimeInterval(index))
        }

        let results = SearchPanelOverlayResults.recentTasks(tasks, workspaces: [])

        #expect(results.map(\.title) == (2..<11).reversed().map { "Task \($0)" })
    }

    @Test("empty task search falls back to recent tasks")
    func emptyTaskSearchFallsBackToRecentTasks() {
        let older = makeTask(title: "Older", updatedAt: 1)
        let newer = makeTask(title: "Newer", updatedAt: 2)

        let results = SearchPanelOverlayResults.filteredTasks(searchText: "   ", tasks: [older, newer], workspaces: [])

        #expect(results.map(\.title) == ["Newer", "Older"])
    }

    @Test("task search matches title goal workspace name and path")
    func taskSearchMatchesTaskAndWorkspaceFields() {
        let workspaceName = Workspace(name: "Alpha Client", primaryPath: "/tmp/name-only")
        let workspacePath = Workspace(name: "Other", primaryPath: "/tmp/alpha-client")
        let titleMatch = makeTask(title: "Ship alpha", goal: "No goal match", workspace: nil, updatedAt: 1)
        let goalMatch = makeTask(title: "Unrelated", goal: "alpha release", workspace: nil, updatedAt: 4)
        let workspaceNameMatch = makeTask(title: "Docs", goal: "Other", workspace: workspaceName, updatedAt: 3)
        let workspacePathMatch = makeTask(title: "Build", goal: "Other", workspace: workspacePath, updatedAt: 2)

        let results = SearchPanelOverlayResults.filteredTasks(
            searchText: "alpha",
            tasks: [titleMatch, goalMatch, workspaceNameMatch, workspacePathMatch],
            workspaces: [workspaceName, workspacePath]
        )

        #expect(results.map(\.title) == ["Unrelated", "Docs", "Build", "Ship alpha"])
    }

    @Test("workspace search trims input and sorts names")
    func workspaceSearchTrimsInputAndSortsNames() {
        let zebra = Workspace(name: "Zebra Alpha", primaryPath: "/tmp/z")
        let amber = Workspace(name: "Amber Alpha", primaryPath: "/tmp/a")
        let skipped = Workspace(name: "Beta", primaryPath: "/tmp/b")

        let results = SearchPanelOverlayResults.filteredWorkspaces(
            searchText: " alpha ",
            workspaces: [zebra, skipped, amber],
            taskCount: 3
        )

        #expect(results.map(\.name) == ["Amber Alpha", "Zebra Alpha"])
        #expect(SearchPanelOverlayResults.filteredWorkspaces(searchText: " ", workspaces: [amber], taskCount: 0).isEmpty)
    }

    @Test("workspace search is capped for broad matches")
    func workspaceSearchIsCapped() {
        let workspaces = (0..<30).map {
            Workspace(name: "Shared \($0)", primaryPath: "/tmp/shared-\($0)")
        }

        let results = SearchPanelOverlayResults.filteredWorkspaces(
            searchText: "shared",
            workspaces: workspaces,
            taskCount: 0
        )

        #expect(results.count == 12)
    }

    private func makeTask(
        title: String,
        goal: String = "",
        workspace: Workspace? = nil,
        updatedAt: TimeInterval
    ) -> AgentTask {
        let task = AgentTask(title: title, goal: goal, workspace: workspace)
        task.updatedAt = Date(timeIntervalSince1970: updatedAt)
        return task
    }
}
