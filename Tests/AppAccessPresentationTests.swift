import Foundation
import Testing
@testable import ASTRA

@Suite("App Access Presentation")
struct AppAccessPresentationTests {
    @Test("Sidebar app access destinations stay ordered by daily utility")
    func sidebarAppAccessDestinationsStayOrderedByDailyUtility() {
        #expect(AppAccessDestination.allCases == [.settings, .logs, .usage])
        #expect(AppAccessDestination.allCases.map(\.title) == ["Settings", "Logs", "Usage"])
        #expect(AppAccessDestination.allCases.map(\.systemImageName) == [
            "gearshape",
            "doc.text.magnifyingglass",
            "chart.bar.xaxis"
        ])
    }

    @Test("App utility windows use stable scene identifiers")
    func appUtilityWindowsUseStableSceneIdentifiers() {
        #expect(AppWindowIDs.logs == "astra-logs")
        #expect(AppWindowIDs.usage == "astra-usage")
    }

    @Test("Sidebar app access footer remains a bottom anchored custom menu")
    func sidebarAppAccessFooterRemainsBottomAnchoredCustomMenu() {
        #expect(SidebarLeanPresentation.appAccessFooterIsBottomAnchored)
        #expect(SidebarLeanPresentation.appAccessFooterMenuTitle == "ASTRA")
        #expect(SidebarLeanPresentation.appAccessFooterMinimumHeight == 44)
    }

    @Test("Sidebar app access menu uses an attached drawer instead of a popover bubble")
    func sidebarAppAccessMenuUsesAttachedDrawerInsteadOfPopoverBubble() throws {
        let source = try appAccessMenuSource()

        #expect(!source.contains(".popover("))
        #expect(source.contains(".overlay(alignment: .top)"))
        #expect(source.contains(".offset(y: -AppAccessMenuPresentation.drawerVerticalOffset"))
        #expect(!source.contains(".alignmentGuide(.top)"))
        #expect(source.contains(".onAppear { isPresented = false }"))
        #expect(!source.contains(".strokeBorder(controlStroke)"))
        #expect(!source.contains("controlStroke"))
        #expect(AppAccessMenuPresentation.footerIconSystemName == "ellipsis.circle")
        #expect(!source.contains("\"app.dashed\""))
    }

    private func appAccessMenuSource() throws -> String {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/Views/Components/AppAccessMenu.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
