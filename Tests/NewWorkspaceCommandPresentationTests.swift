import Foundation
import Testing
@testable import ASTRA

@Suite("New workspace command presentation")
struct NewWorkspaceCommandPresentationTests {

    @Test("The shared button uses the folder-plus affordance")
    func sharedButtonUsesFolderPlusAffordance() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/Components/NewWorkspaceCommandButton.swift"),
            encoding: .utf8
        )

        #expect(source.contains("systemImage: \"folder.badge.plus\""))
        #expect(source.contains("accessibilityLabel(NewWorkspaceCommandPresentation.title)"))
        #expect(source.contains("accessibilityHint(\"Creates a new workspace\")"))
    }

    @Test("Hover keeps fixed icon geometry and uses shared active chrome")
    func hoverKeepsFixedIconGeometry() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/Components/NewWorkspaceCommandButton.swift"),
            encoding: .utf8
        )

        #expect(NewWorkspaceCommandPresentation.title == "New Workspace")
        #expect(source.contains("AstraToolbarCommandIcon("))
        #expect(source.contains("isActive: isHovered"))
        #expect(source.contains(".onHover { isHovered = $0 }"))
        #expect(!source.contains("Text(NewWorkspaceCommandPresentation.title)"))
    }

    @Test("Expanded command bar reaches the edge at minimum sidebar width")
    func expandedCommandBarReachesEdgeAtMinimumSidebarWidth() {
        let width = AstraLeadingCommandBarLayout.commandBarWidth(
            sidebarWidth: SidebarColumnLayout.expandedMinimumWidth,
            accessoryLeadingX: 90,
            isSidebarHidden: false
        )

        #expect(width == 220)
        #expect(AstraLeadingCommandBarMetrics.expandedTrailingPadding == 10)
    }

    @Test("Collapsed command bar reserves only fixed icon geometry")
    func collapsedCommandBarReservesFixedIconGeometry() {
        let width = AstraLeadingCommandBarLayout.commandBarWidth(
            sidebarWidth: 320,
            accessoryLeadingX: 88,
            isSidebarHidden: true
        )
        let expectedWidth = (AstraToolbarCommandMetrics.iconWidth * 3)
            + AstraToolbarCommandMetrics.clusterSpacing
            + (AstraToolbarCommandMetrics.clusterHorizontalPadding * 3)
            + AstraLeadingCommandBarMetrics.trailingPadding

        #expect(width == expectedWidth)
    }

    @Test("The sidebar no longer contributes a competing window-toolbar item")
    func sidebarDoesNotContributeWindowToolbarItem() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sidebarSource = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/TaskSidebarView.swift"),
            encoding: .utf8
        )
        let commandBarSource = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/Components/AstraLeadingCommandBar.swift"),
            encoding: .utf8
        )

        #expect(!sidebarSource.contains("SidebarTopToolbar"))
        #expect(commandBarSource.contains("Spacer(minLength: 0)"))
        #expect(commandBarSource.contains("sidebarCommands.requestNewWorkspace()"))
    }

    @Test("The workspace header does not duplicate the titlebar creation command")
    func workspaceHeaderDoesNotDuplicateCreationCommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sidebarSource = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/TaskSidebarView.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )

        #expect(!sidebarSource.contains("onNewWorkspace"))
        #expect(!sidebarSource.contains("isWorkspacesAddHovered"))
        #expect(!sidebarSource.contains(".help(\"New Workspace\")"))
        #expect(!contentSource.contains("onNewWorkspace: createWorkspace"))
    }
}
