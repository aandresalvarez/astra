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
        #expect(AppWindowIDs.main == "astra-main")
        #expect(AppWindowIDs.logs == "astra-logs")
        #expect(AppWindowIDs.usage == "astra-usage")
    }

    @Test("Main window commands replace SwiftUI new-item scene discovery")
    func mainWindowCommandsReplaceSwiftUINewItemSceneDiscovery() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/ASTRAApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        func matches(_ pattern: String) -> Bool {
            source.range(of: pattern, options: .regularExpression) != nil
        }

        #expect(matches(#"WindowGroup\s*\(\s*AppChannel\.current\.displayName\s*,\s*id:\s*AppWindowIDs\.main\s*\)"#))
        #expect(matches(#"CommandGroup\s*\(\s*replacing:\s*\.newItem\s*\)"#))
        #expect(!matches(#"CommandGroup\s*\(\s*after:\s*\.newItem\s*\)"#))
        #expect(matches(#"openWindow\s*\(\s*id:\s*AppWindowIDs\.main\s*\)"#))
    }

    @Test("Sidebar app access footer remains a bottom anchored custom menu")
    func sidebarAppAccessFooterRemainsBottomAnchoredCustomMenu() throws {
        let source = try taskSidebarSource()
        let scrollViewRange = try #require(source.range(of: "ScrollView {"))
        let footerRange = try #require(source.range(of: "appAccessFooter", range: scrollViewRange.upperBound..<source.endIndex))
        let sidebarIdentifierRange = try #require(source.range(of: ".accessibilityIdentifier(\"TaskSidebar\")"))

        #expect(footerRange.lowerBound > scrollViewRange.upperBound)
        #expect(footerRange.lowerBound < sidebarIdentifierRange.lowerBound)
        #expect(source.range(of: "appAccessFooter", range: scrollViewRange.upperBound..<footerRange.lowerBound) == nil)
        #expect(source.contains("private var appAccessFooter: some View"))
        #expect(!source.contains("appAccessFooterIsBottomAnchored"))
        #expect(AppAccessMenuPresentation.footerMenuTitle == "ASTRA")
        #expect(AppAccessMenuPresentation.footerMinimumHeight == 56)
        #expect(AppAccessMenuPresentation.footerContentHorizontalPadding == 22)
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
        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(source.contains("controlFill\n                }"))
        #expect(!source.contains("RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)\n                        .fill(controlFill)"))
        // Gear (VS Code's Manage-menu pattern: the button opens a drawer
        // that itself contains Settings) — ellipsis.circle promised only
        // "more…" and was the vaguest glyph on the rail.
        #expect(AppAccessMenuPresentation.footerIconSystemName == "gearshape")
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
