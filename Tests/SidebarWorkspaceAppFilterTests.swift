import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// The search-aware filtering behind the sidebar's inline app rows. Mirrors how chat rows
/// behave during search: no query (or a workspace-name match) shows every app; otherwise only
/// apps whose name matches. Pure value logic, so it's unit-tested without the SwiftUI row.
@Suite("Sidebar Workspace App Filter")
@MainActor
struct SidebarWorkspaceAppFilterTests {
    private func app(_ name: String, workspaceID: UUID) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspaceID,
            logicalID: name.lowercased(),
            name: name,
            manifestRelativePath: "m.json",
            appDirectoryRelativePath: "d",
            manifestDigest: "digest"
        )
    }

    @Test("no search shows every app for the workspace, name-sorted, other workspaces excluded")
    func noSearchShowsAllSorted() {
        let ws = Workspace(name: "Research", primaryPath: "/tmp/ws")
        let other = UUID()
        let apps = [
            app("Sample Tracker", workspaceID: ws.id),
            app("Enrollment Reconciliation", workspaceID: ws.id),
            app("Other App", workspaceID: other)
        ]
        let result = SidebarWorkspaceAppFilter.apps(apps, in: ws, searchText: "", workspaceMatchesSearch: false)
        #expect(result.map(\.name) == ["Enrollment Reconciliation", "Sample Tracker"])
    }

    @Test("a query filters apps by name; a non-matching app is hidden")
    func queryFiltersByName() {
        let ws = Workspace(name: "Research", primaryPath: "/tmp/ws")
        let apps = [
            app("Sample Tracker", workspaceID: ws.id),
            app("Enrollment Reconciliation", workspaceID: ws.id)
        ]
        let result = SidebarWorkspaceAppFilter.apps(apps, in: ws, searchText: "sample", workspaceMatchesSearch: false)
        #expect(result.map(\.name) == ["Sample Tracker"])
    }

    @Test("when the workspace name itself matches, all its apps stay visible")
    func workspaceNameMatchShowsAll() {
        let ws = Workspace(name: "Research", primaryPath: "/tmp/ws")
        let apps = [
            app("Sample Tracker", workspaceID: ws.id),
            app("Enrollment Reconciliation", workspaceID: ws.id)
        ]
        // The query matched the workspace name (not the app names), so children are not narrowed.
        let result = SidebarWorkspaceAppFilter.apps(apps, in: ws, searchText: "research", workspaceMatchesSearch: true)
        #expect(result.count == 2)
    }

    @Test("hasMatch surfaces a workspace whose only match is an app name")
    func hasMatchOnAppName() {
        let ws = Workspace(name: "Research", primaryPath: "/tmp/ws")
        let apps = [app("Sample Tracker", workspaceID: ws.id)]
        #expect(SidebarWorkspaceAppFilter.hasMatch(apps, in: ws, searchText: "sample"))
        #expect(!SidebarWorkspaceAppFilter.hasMatch(apps, in: ws, searchText: "nomatch"))
        // An empty query never forces visibility on its own.
        #expect(!SidebarWorkspaceAppFilter.hasMatch(apps, in: ws, searchText: ""))
    }
}
