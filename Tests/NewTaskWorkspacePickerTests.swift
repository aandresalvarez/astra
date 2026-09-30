import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("New task workspace picker")
struct NewTaskWorkspacePickerTests {
    // MARK: - Row

    @Test("The row starts with the current workspace, then recent ones with starred first")
    func initialRowLeadsWithCurrentThenRecents() {
        let current = workspace("Current")
        let starred = workspace("Starred", starred: true)
        let recent = workspace("Recent")
        let older = workspace("Older")
        let unused = workspace("Unused")
        let state = WorkspaceSidebarOrderingState(recentUseDates: [
            recent.id: Date(timeIntervalSince1970: 300),
            older.id: Date(timeIntervalSince1970: 100)
        ])

        let row = NewTaskWorkspacePicker.initialRow(
            current: current,
            workspaces: [unused, older, recent, starred, current],
            state: state
        )

        #expect(row == [current.id, starred.id, recent.id, older.id])
    }

    @Test("A single workspace still yields a one-segment row")
    func singleWorkspaceRow() {
        let only = workspace("Only")

        #expect(NewTaskWorkspacePicker.initialRow(
            current: only, workspaces: [only], state: WorkspaceSidebarOrderingState()
        ) == [only.id])
    }

    @Test("Selecting a workspace already in the row never reorders it")
    func selectingInsideRowKeepsOrder() {
        let all = (0..<4).map { workspace("W\($0)") }
        let row = all.map(\.id)

        #expect(NewTaskWorkspacePicker.row(row, selecting: all[2].id, in: all) == row)
    }

    @Test("A workspace from the menu is appended while there is room")
    func menuPickIsAppendedWhenRoomRemains() {
        let all = (0..<5).map { workspace("W\($0)") }
        let row = [all[0].id, all[1].id]

        #expect(NewTaskWorkspacePicker.row(row, selecting: all[4].id, in: all) == [all[0].id, all[1].id, all[4].id])
    }

    @Test("A workspace from the menu takes the last slot once the row is full")
    func menuPickReplacesLastSegmentWhenFull() {
        let all = (0..<6).map { workspace("W\($0)") }
        let row = all.prefix(4).map(\.id)

        let next = NewTaskWorkspacePicker.row(row, selecting: all[5].id, in: all)

        #expect(next == [all[0].id, all[1].id, all[2].id, all[5].id])
    }

    @Test("Deleted workspaces leave the row, and an unknown selection is ignored")
    func deletedWorkspacesAreDropped() {
        let kept = workspace("Kept")
        let gone = workspace("Gone")
        let stranger = workspace("Stranger")

        let next = NewTaskWorkspacePicker.row([kept.id, gone.id], selecting: stranger.id, in: [kept])

        #expect(next == [kept.id])
    }

    @Test("A narrow pane shows fewer segments but always keeps the current workspace")
    func narrowRowKeepsTheCurrentWorkspace() {
        let ids = (0..<4).map { _ in UUID() }

        #expect(NewTaskWorkspacePicker.visibleRow(ids, keeping: ids[0], count: 4) == ids)
        #expect(NewTaskWorkspacePicker.visibleRow(ids, keeping: ids[1], count: 2) == [ids[0], ids[1]])
        #expect(NewTaskWorkspacePicker.visibleRow(ids, keeping: ids[3], count: 2) == [ids[0], ids[3]])
        #expect(NewTaskWorkspacePicker.visibleRow(ids, keeping: ids[2], count: 1) == [ids[2]])
        #expect(NewTaskWorkspacePicker.visibleRow(ids, keeping: ids[0], count: 0) == [ids[0]])
    }

    @Test("Long workspace names are shortened to fit a segment")
    func segmentTitlesAreShortened() {
        #expect(NewTaskWorkspacePicker.segmentTitle("Astra Work") == "Astra Work")
        let exact = String(repeating: "a", count: 24)
        #expect(NewTaskWorkspacePicker.segmentTitle(exact) == exact)
        let long = String(repeating: "b", count: 40)
        let shortened = NewTaskWorkspacePicker.segmentTitle(long)
        #expect(shortened.count == 24)
        #expect(shortened.hasSuffix("…"))
    }

    // MARK: - Menu

    @Test("Recent workspaces come first, newest first, then the rest by name")
    func menuLeadsWithRecents() {
        let older = workspace("Older")
        let newer = workspace("Newer")
        let zulu = workspace("Zulu")
        let alpha = workspace("alpha")
        let state = WorkspaceSidebarOrderingState(recentUseDates: [
            older.id: Date(timeIntervalSince1970: 100),
            newer.id: Date(timeIntervalSince1970: 200)
        ])

        let groups = NewTaskWorkspacePicker.menuGroups(
            workspaces: [zulu, older, alpha, newer], query: "", state: state
        )

        #expect(groups.map(\.kind) == [.recent, .all])
        #expect(groups[0].title == "Recent")
        #expect(groups[0].workspaces.map(\.id) == [newer.id, older.id])
        #expect(groups[1].title == "All workspaces")
        #expect(groups[1].workspaces.map(\.id) == [alpha.id, zulu.id])
    }

    @Test("Recents are capped, and a workspace appears in only one section")
    func recentsAreCappedWithoutDuplicates() {
        let all = (0..<9).map { workspace("Workspace \($0)") }
        let state = WorkspaceSidebarOrderingState(recentUseDates: Dictionary(
            uniqueKeysWithValues: all.enumerated().map { ($1.id, Date(timeIntervalSince1970: Double($0))) }
        ))

        let groups = NewTaskWorkspacePicker.menuGroups(workspaces: all, query: "", state: state)

        #expect(groups[0].workspaces.count == NewTaskWorkspacePicker.recentLimit)
        #expect(groups.flatMap(\.workspaces).count == 9)
        #expect(Set(groups.flatMap(\.workspaces).map(\.id)).count == 9)
    }

    @Test("A workspace already in the row never takes a Recent slot, but is still listed")
    func rowWorkspacesSkipRecent() {
        let inRow = workspace("In row")
        let recent = workspace("Recent")
        let rest = workspace("Rest")
        let state = WorkspaceSidebarOrderingState(recentUseDates: [
            inRow.id: Date(timeIntervalSince1970: 300),
            recent.id: Date(timeIntervalSince1970: 200)
        ])

        let groups = NewTaskWorkspacePicker.menuGroups(
            workspaces: [rest, recent, inRow], row: [inRow.id], query: "", state: state
        )

        #expect(groups[0].kind == .recent)
        #expect(groups[0].workspaces.map(\.id) == [recent.id])
        #expect(groups[1].workspaces.map(\.id) == [inRow.id, rest.id])
    }

    @Test("Without any usage history the menu is one alphabetical list")
    func menuWithoutHistoryIsOneList() {
        let beta = workspace("beta")
        let alpha = workspace("Alpha")

        let groups = NewTaskWorkspacePicker.menuGroups(
            workspaces: [beta, alpha], query: "", state: WorkspaceSidebarOrderingState()
        )

        #expect(groups.map(\.kind) == [.all])
        #expect(groups[0].workspaces.map(\.id) == [alpha.id, beta.id])
    }

    @Test("Search is case-insensitive, applies to both sections, and can match nothing")
    func searchFiltersByName() {
        let jira = workspace("Jira Analytics")
        let jiraOld = workspace("Old jira queue")
        let other = workspace("StarrDocs")
        let state = WorkspaceSidebarOrderingState(recentUseDates: [jira.id: Date()])

        let hit = NewTaskWorkspacePicker.menuGroups(
            workspaces: [jira, jiraOld, other], query: " JIRA ", state: state
        )
        let miss = NewTaskWorkspacePicker.menuGroups(
            workspaces: [jira, other], query: "clinical", state: state
        )

        #expect(hit.map(\.kind) == [.recent, .all])
        #expect(hit.flatMap(\.workspaces).map(\.id) == [jira.id, jiraOld.id])
        #expect(miss.isEmpty)
    }

    // MARK: - Activity

    @MainActor
    @Test("Running counts come from the store, per workspace, and ignore finished work")
    func runningCountsComeFromTheStore() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let busy = workspace("Busy")
        let quiet = workspace("Quiet")
        context.insert(busy)
        context.insert(quiet)
        let running = AgentTask(title: "Running", goal: "Go", workspace: busy, runtime: .claudeCode)
        running.status = .running
        let done = AgentTask(title: "Done", goal: "Done", workspace: busy, runtime: .claudeCode)
        done.status = .completed
        done.completedAt = Date()
        let draft = AgentTask(title: "Draft", goal: "Later", workspace: quiet, runtime: .claudeCode)
        context.insert(running)
        context.insert(done)
        context.insert(draft)
        try context.save()

        let counts = NewTaskWorkspaceActivity.runningCounts(in: context)

        #expect(counts[busy.id] == 1)
        #expect(counts[quiet.id] == nil)
        withExtendedLifetime(container) {}
    }

    private func workspace(_ name: String, starred: Bool = false) -> Workspace {
        let workspace = Workspace(name: name, primaryPath: "/tmp/\(UUID().uuidString)")
        workspace.isStarred = starred
        return workspace
    }
}
