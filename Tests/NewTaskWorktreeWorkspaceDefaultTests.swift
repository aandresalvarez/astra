import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A workspace can make "Start in a new worktree" the starting value of its
/// new-task composer. It is off unless a person turned it on, it never
/// overrides a choice somebody already made, and it leaves drafts alone.
@Suite("A workspace's worktree default is the composer's starting value", .serialized)
@MainActor
struct NewTaskWorktreeWorkspaceDefaultTests {
    private typealias Fixture = NewTaskWorktreeFixture
    private let app = GitRepositoryInfo(name: "App", path: "/repos/app")

    @Test("The setting is off until turned on, is kept per workspace under a stable key, and off again leaves nothing behind")
    func storeRoundTrip() {
        let store = InMemoryDefaults()
        let first = UUID(), second = UUID()
        #expect(!NewTaskWorktreeDefaultStore.startsEnabled(workspaceID: first, in: store))
        NewTaskWorktreeDefaultStore.setStartsEnabled(true, workspaceID: first, in: store)
        #expect(NewTaskWorktreeDefaultStore.startsEnabled(workspaceID: first, in: store))
        #expect(!NewTaskWorktreeDefaultStore.startsEnabled(workspaceID: second, in: store))
        // The key is what a relaunch reads back; renaming it would silently reset every workspace.
        #expect(store.bool(forKey: "newTaskWorktree.startsEnabled.\(first.uuidString)"))
        NewTaskWorktreeDefaultStore.setStartsEnabled(false, workspaceID: first, in: store)
        #expect(!NewTaskWorktreeDefaultStore.startsEnabled(workspaceID: first, in: store))
        #expect(store.object(forKey: "newTaskWorktree.startsEnabled.\(first.uuidString)") == nil)
    }

    @Test("A fresh composer with a repository starts checked when the workspace asks for it, and unchecked otherwise")
    func startingValue() {
        var on = NewTaskWorktreeSelection()
        on.updateRepositories([app], selectedPath: nil)
        on.applyWorkspaceDefault(true)
        #expect(on.isEnabled && on.canSubmit && on.request?.repositoryPath == app.path)
        #expect(on.base == .defaultBranch)

        var off = NewTaskWorktreeSelection()
        off.updateRepositories([app], selectedPath: nil)
        off.applyWorkspaceDefault(false)
        #expect(!off.isEnabled && !off.awaitsWorkspaceDefault)
    }

    @Test("Where no repository is offered the setting does nothing, and it applies once a scan finds one")
    func needsARepository() {
        var selection = NewTaskWorktreeSelection()
        selection.applyWorkspaceDefault(true)
        #expect(!selection.isEnabled && selection.canSubmit && selection.awaitsWorkspaceDefault)
        selection.isLoading = true
        selection.applyWorkspaceDefault(true)
        #expect(!selection.isEnabled)
        selection.updateRepositories([app], selectedPath: nil)
        selection.applyWorkspaceDefault(true)
        #expect(selection.isEnabled)
    }

    @Test("Clearing the choice for one task stays cleared, and the next fresh composer starts checked again")
    func oneTaskCanOptOut() throws {
        let store = InMemoryDefaults()
        let workspace = Workspace(name: "Repo", primaryPath: "/repos/app")
        NewTaskWorktreeDefaultStore.setStartsEnabled(true, workspaceID: workspace.id, in: store)
        var selection = NewTaskWorktreeSelection()
        selection.updateRepositories([app], selectedPath: nil)
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &selection, draft: nil, workspace: workspace, defaults: store)
        #expect(selection.isEnabled)
        // The person clears it; a later scan or reset of the same composer does not check it again.
        selection.isEnabled = false
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &selection, draft: nil, workspace: workspace, defaults: store)
        selection.updateRepositories([app], selectedPath: nil)
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &selection, draft: nil, workspace: workspace, defaults: store)
        #expect(!selection.isEnabled)
        // Clearing it for a task did not change the workspace's setting.
        #expect(NewTaskWorktreeDefaultStore.startsEnabled(workspaceID: workspace.id, in: store))
        selection.resetTaskChoice()
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &selection, draft: nil, workspace: workspace, defaults: store)
        #expect(selection.isEnabled && selection.base == .defaultBranch)
    }

    @Test("A saved draft keeps what it recorded, or off; the setting never changes it")
    func draftsAreLeftAlone() throws {
        let store = InMemoryDefaults()
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "Repo", primaryPath: "/repos/app")
        context.insert(workspace)
        NewTaskWorktreeDefaultStore.setStartsEnabled(true, workspaceID: workspace.id, in: store)

        // A draft with no recorded choice: the composer stays off for it.
        let plain = AgentTask(title: "Draft", goal: "Draft", workspace: workspace)
        plain.status = .draft
        context.insert(plain)
        var selection = NewTaskWorktreeSelection()
        selection.updateRepositories([app], selectedPath: nil)
        NewTaskWorktreeComposerFlow.restoreChoice(&selection, from: plain)
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &selection, draft: plain, workspace: workspace, defaults: store)
        #expect(!selection.isEnabled)
        #expect(TaskWorktreeService.latestRequest(for: plain) == nil)

        // A draft that recorded "off" stays off even after the composer is otherwise fresh.
        var recorded = NewTaskWorktreeSelection()
        recorded.updateRepositories([app], selectedPath: nil)
        recorded.isEnabled = true
        try NewTaskWorktreeComposerFlow.persistChoice(recorded, on: plain, modelContext: context)
        recorded.isEnabled = false
        try NewTaskWorktreeComposerFlow.persistChoice(recorded, on: plain, modelContext: context)
        var restored = NewTaskWorktreeSelection()
        restored.updateRepositories([app], selectedPath: nil)
        NewTaskWorktreeComposerFlow.restoreChoice(&restored, from: plain)
        #expect(!restored.isEnabled && !restored.awaitsWorkspaceDefault)
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &restored, draft: nil, workspace: workspace, defaults: store)
        #expect(!restored.isEnabled)
    }

    @Test("Without the setting nothing changes: a fresh composer starts unchecked")
    func offByDefault() throws {
        let store = InMemoryDefaults()
        let workspace = Workspace(name: "Repo", primaryPath: "/repos/app")
        var selection = NewTaskWorktreeSelection()
        selection.updateRepositories([app], selectedPath: nil)
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &selection, draft: nil, workspace: workspace, defaults: store)
        #expect(!selection.isEnabled && selection.request == nil)
        // No workspace, no setting to read.
        var orphan = NewTaskWorktreeSelection()
        orphan.updateRepositories([app], selectedPath: nil)
        NewTaskWorktreeComposerFlow.applyWorkspaceDefault(to: &orphan, draft: nil, workspace: nil, defaults: store)
        #expect(!orphan.isEnabled && orphan.awaitsWorkspaceDefault)
    }

    @Test("The workspace default is offered beside the task's choice once a worktree is picked, and stays in view while it is on")
    func defaultControlVisibility() {
        typealias Row = NewTaskWorktreeDockPresentation
        #expect(!Row.showsWorkspaceDefault(showsToggle: true, isEnabled: false, workspaceDefault: false))
        #expect(Row.showsWorkspaceDefault(showsToggle: true, isEnabled: true, workspaceDefault: false))
        // Still there after the person clears this one task, so the default can be turned off.
        #expect(Row.showsWorkspaceDefault(showsToggle: true, isEnabled: false, workspaceDefault: true))
        // A draft pinned to its checkout offers no choice at all.
        #expect(!Row.showsWorkspaceDefault(showsToggle: false, isEnabled: true, workspaceDefault: true))
    }

    @Test("The switch for the default is in a view a person can reach, and in no other")
    func defaultControlIsReachable() throws {
        // The first version put the switch in a sheet nothing opened. The
        // composer's worktree row is on screen for every new task in a
        // repository, so the switch lives there, beside the checkbox.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Astra/Views")
        let setters = try FileManager.default.subpathsOfDirectory(atPath: views.path).filter { $0.hasSuffix(".swift") }.filter {
            try String(contentsOf: views.appendingPathComponent($0), encoding: .utf8).contains("NewTaskWorktreeDefaultStore.setStartsEnabled")
        }
        #expect(setters == ["NewTaskWorktreeDockView.swift"])
        let row = try String(contentsOf: views.appendingPathComponent("NewTaskWorktreeDockView.swift"), encoding: .utf8)
        #expect(row.contains("NewTaskWorktreeWorkspaceDefaultToggle"))
        // The row itself is built by the composer of a new task.
        let composer = try String(contentsOf: views.appendingPathComponent("ChatPanelView.swift"), encoding: .utf8)
        #expect(composer.contains("NewTaskWorktreeDockView("))
    }
}
