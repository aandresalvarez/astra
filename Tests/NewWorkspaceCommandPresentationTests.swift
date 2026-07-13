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

        #expect(source.contains("Image(systemName: \"folder.badge.plus\")"))
        #expect(source.contains("accessibilityLabel(NewWorkspaceCommandPresentation.title)"))
        #expect(source.contains("accessibilityHint(\"Creates a new workspace\")"))
    }

    @Test("Hover immediately names and highlights the command")
    func hoverNamesAndHighlightsCommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/Components/NewWorkspaceCommandButton.swift"),
            encoding: .utf8
        )

        #expect(NewWorkspaceCommandPresentation.title == "New Workspace")
        #expect(NewWorkspaceCommandPresentation.hoverFillOpacity > 0)
        #expect(source.contains("if isHovered"))
        #expect(source.contains("Text(NewWorkspaceCommandPresentation.title)"))
        #expect(source.contains(".onHover { isHovered = $0 }"))
    }

    @Test("Expanded command bar reaches the measured sidebar edge")
    func expandedCommandBarReachesMeasuredSidebarEdge() {
        let width = AstraLeadingCommandBarLayout.commandBarWidth(
            sidebarWidth: 320,
            accessoryLeadingX: 88,
            isSidebarHidden: false
        )

        #expect(width == 232)
        #expect(AstraLeadingCommandBarMetrics.expandedTrailingPadding == 10)
    }

    @Test("Collapsed command bar keeps New Workspace in the compact leading cluster")
    func collapsedCommandBarStaysCompact() {
        let width = AstraLeadingCommandBarLayout.commandBarWidth(
            sidebarWidth: 320,
            accessoryLeadingX: 88,
            isSidebarHidden: true
        )

        #expect(width == AstraLeadingCommandBarLayout.collapsedCommandBarWidth)
        #expect(width! >= NewWorkspaceCommandPresentation.hoveredControlWidth)
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
}
