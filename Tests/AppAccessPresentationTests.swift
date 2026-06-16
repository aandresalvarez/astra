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
    func sidebarAppAccessFooterRemainsBottomAnchoredCustomMenu() throws {
        let source = try taskSidebarSource()
        let scrollViewRange = try #require(source.range(of: "ScrollView {"))
        let footerRange = try #require(source.range(of: "appAccessFooter", range: scrollViewRange.upperBound..<source.endIndex))
        let bodyEndRange = try #require(source.range(of: "\n        }\n        .accessibilityIdentifier(\"TaskSidebar\")"))

        #expect(footerRange.lowerBound > scrollViewRange.upperBound)
        #expect(footerRange.lowerBound < bodyEndRange.lowerBound)
        #expect(source.range(of: "appAccessFooter", range: scrollViewRange.upperBound..<footerRange.lowerBound) == nil)
        #expect(source.contains("private var appAccessFooter: some View"))
        #expect(!source.contains("appAccessFooterIsBottomAnchored"))
        #expect(AppAccessMenuPresentation.footerMenuTitle == "ASTRA")
        #expect(AppAccessMenuPresentation.footerMinimumHeight == 44)
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
        #expect(!source.contains("SidebarLeanPresentation"))
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

    private func taskSidebarSource() throws -> String {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/Views/TaskSidebarView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
