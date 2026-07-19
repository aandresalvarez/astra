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

    @Test("Appearance shortcut presents the opposite rendered mode")
    func appearanceShortcutPresentsOppositeRenderedMode() {
        let fromLight = AppearanceTogglePresentation.make(currentColorScheme: .light)
        #expect(fromLight.title == "Dark mode")
        #expect(fromLight.systemImageName == "moon.fill")
        #expect(fromLight.target == .dark)

        let fromDark = AppearanceTogglePresentation.make(currentColorScheme: .dark)
        #expect(fromDark.title == "Light mode")
        #expect(fromDark.systemImageName == "sun.max.fill")
        #expect(fromDark.target == .light)
        #expect(AppAccessMenuPresentation.drawerRowCount(destinationCount: 3) == 5)
        #expect(AppAccessMenuPresentation.drawerHeight(rowCount: 5) == 214)
    }

    @Test("Update check presentation communicates the complete lifecycle")
    func updateCheckPresentationCommunicatesCompleteLifecycle() {
        let idle = AppAccessUpdateCheckPresentation.make(
            status: .idle,
            canCheckForUpdates: true,
            appDisplayName: "ASTRA"
        )
        #expect(idle.detail == "Checks automatically in the background.")
        #expect(idle.isEnabled)

        let checking = AppAccessUpdateCheckPresentation.make(
            status: .checking,
            canCheckForUpdates: false,
            appDisplayName: "ASTRA"
        )
        #expect(checking.detail == "Checking the signed release feed…")
        #expect(checking.showsProgress)
        #expect(!checking.isEnabled)

        let current = AppAccessUpdateCheckPresentation.make(
            status: .notAvailable,
            canCheckForUpdates: true,
            appDisplayName: "ASTRA"
        )
        #expect(current.detail == "ASTRA is up to date.")
        #expect(current.systemImageName == "checkmark.circle.fill")
        #expect(current.indicatorTone == .success)
        #expect(current.isEnabled)

        let available = AppAccessUpdateCheckPresentation.make(
            status: .available(version: "0.1.30"),
            canCheckForUpdates: true,
            appDisplayName: "ASTRA"
        )
        #expect(available.detail == "ASTRA 0.1.30 is available.")
        #expect(available.indicatorTone == .accent)

        let disabled = AppAccessUpdateCheckPresentation.make(
            status: .disabled("App updates are disabled for ASTRA Dev."),
            canCheckForUpdates: false,
            appDisplayName: "ASTRA Dev"
        )
        #expect(disabled.title == "Updates")
        #expect(disabled.detail == "App updates are disabled for ASTRA Dev.")
        #expect(!disabled.isEnabled)
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
        #expect(source.contains("controlFill"))
        #expect(!source.contains("RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)\n                        .fill(controlFill)"))
        // Gear (VS Code's Manage-menu pattern: the button opens a drawer
        // that itself contains Settings) — ellipsis.circle promised only
        // "more…" and was the vaguest glyph on the rail.
        #expect(AppAccessMenuPresentation.footerIconSystemName == "gearshape")
        #expect(!source.contains("\"app.dashed\""))
    }

    @Test("Sidebar app access menu owns the manual update check")
    func sidebarAppAccessMenuOwnsManualUpdateCheck() throws {
        let appMenuSource = try astraAppSource()
        let appAccessSource = try appAccessMenuSource()
        let contentViewSource = try contentViewSource()

        #expect(appAccessSource.contains("AppAccessUpdateCheckButton(appUpdateController: appUpdateController)"))
        #expect(appAccessSource.contains("appUpdateController.checkForUpdates()"))
        #expect(appAccessSource.contains(".accessibilityIdentifier(\"AppAccessMenuItem.checkForUpdates\")"))
        #expect(appAccessSource.contains("ProgressView()"))
        #expect(appAccessSource.contains("if presentation.isEnabled"))
        #expect(!appAccessSource.contains(".disabled(!presentation.isEnabled)"))
        #expect(appAccessSource.contains(".accessibilityValue(presentation.detail)"))
        #expect(appAccessSource.contains("AppAccessAvailableUpdateButton(appUpdateController: appUpdateController)"))
        #expect(appAccessSource.contains(".accessibilityIdentifier(\"AppAccessAvailableUpdateButton\")"))
        #expect(appAccessSource.contains("if appUpdateController.shouldShowUpdateButton"))
        #expect(!appMenuSource.contains("CheckForUpdatesMenuItem"))
        #expect(!appMenuSource.contains("CommandGroup(after: .appInfo)"))
        // The unconditional app-menu command and always-visible toolbar button
        // are gone — but a scoped toolbar fallback remains for the one state
        // where the footer (this control's normal home) isn't on screen at all:
        // the sidebar fully collapsed. `.docked` and `.overlay` both keep the
        // footer visible, so this must not render unconditionally.
        #expect(contentViewSource.contains("presentation.mode == .collapsed"))
        #expect(contentViewSource.contains("CollapsedSidebarUpdateToolbar"))
        #expect(contentViewSource.contains(".accessibilityIdentifier(\"AppUpdateButton\")"))
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

    private func astraAppSource() throws -> String {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/ASTRAApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func contentViewSource() throws -> String {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/Views/ContentView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
