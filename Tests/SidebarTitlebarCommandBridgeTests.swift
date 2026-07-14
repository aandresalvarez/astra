import Foundation
import Testing
@testable import ASTRA

@MainActor
@Suite("SidebarTitlebarCommandBridge")
struct SidebarTitlebarCommandBridgeTests {

    @Test("Sidebar toggle requests advance a stable command counter")
    func sidebarToggleRequestsAdvanceCounter() {
        let bridge = SidebarTitlebarCommandBridge()

        #expect(bridge.toggleRequestID == 0)

        bridge.requestSidebarToggle()
        #expect(bridge.toggleRequestID == 1)

        bridge.requestSidebarToggle()
        #expect(bridge.toggleRequestID == 2)
    }

    @Test("Sidebar toggle requests post a titlebar command notification")
    func sidebarToggleRequestsPostNotification() {
        let notificationCenter = NotificationCenter()
        let bridge = SidebarTitlebarCommandBridge(notificationCenter: notificationCenter)
        var notificationCount = 0

        let observer = notificationCenter.addObserver(
            forName: SidebarTitlebarCommandBridge.sidebarToggleRequestedNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        bridge.requestSidebarToggle()

        #expect(notificationCount == 1)
    }

    @Test("Sidebar toggle requests synchronously invoke the installed handler")
    func sidebarToggleRequestsInvokeInstalledHandler() {
        let bridge = SidebarTitlebarCommandBridge(notificationCenter: NotificationCenter())
        var handlerCount = 0

        bridge.installSidebarToggleHandler {
            handlerCount += 1
        }

        bridge.requestSidebarToggle()

        #expect(handlerCount == 1)
    }

    @Test("New workspace requests advance a stable command counter")
    func newWorkspaceRequestsAdvanceCounter() {
        let bridge = SidebarTitlebarCommandBridge()

        #expect(bridge.newWorkspaceRequestID == 0)

        bridge.requestNewWorkspace()
        #expect(bridge.newWorkspaceRequestID == 1)

        bridge.requestNewWorkspace()
        #expect(bridge.newWorkspaceRequestID == 2)
    }

    @Test("New workspace requests post a titlebar command notification")
    func newWorkspaceRequestsPostNotification() {
        let notificationCenter = NotificationCenter()
        let bridge = SidebarTitlebarCommandBridge(notificationCenter: notificationCenter)
        var notificationCount = 0

        let observer = notificationCenter.addObserver(
            forName: SidebarTitlebarCommandBridge.newWorkspaceRequestedNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        bridge.requestNewWorkspace()

        #expect(notificationCount == 1)
    }

    @Test("New workspace requests synchronously invoke the installed handler")
    func newWorkspaceRequestsInvokeInstalledHandler() {
        let bridge = SidebarTitlebarCommandBridge(notificationCenter: NotificationCenter())
        var handlerCount = 0

        bridge.installNewWorkspaceHandler {
            handlerCount += 1
        }

        bridge.requestNewWorkspace()

        #expect(handlerCount == 1)
    }

    @Test("New workspace handlers remain isolated between window bridges")
    func newWorkspaceHandlersRemainWindowScoped() {
        let firstWindowBridge = SidebarTitlebarCommandBridge(notificationCenter: NotificationCenter())
        let secondWindowBridge = SidebarTitlebarCommandBridge(notificationCenter: NotificationCenter())
        var firstWindowHandlerCount = 0
        var secondWindowHandlerCount = 0

        firstWindowBridge.installNewWorkspaceHandler {
            firstWindowHandlerCount += 1
        }
        secondWindowBridge.installNewWorkspaceHandler {
            secondWindowHandlerCount += 1
        }

        firstWindowBridge.requestNewWorkspace()
        #expect(firstWindowHandlerCount == 1)
        #expect(secondWindowHandlerCount == 0)

        secondWindowBridge.requestNewWorkspace()
        #expect(firstWindowHandlerCount == 1)
        #expect(secondWindowHandlerCount == 1)
    }

    @Test("Clearing one window bridge leaves other window handlers installed")
    func clearingOneWindowBridgeDoesNotAffectAnother() {
        let firstWindowBridge = SidebarTitlebarCommandBridge(notificationCenter: NotificationCenter())
        let secondWindowBridge = SidebarTitlebarCommandBridge(notificationCenter: NotificationCenter())
        var firstWindowHandlerCount = 0
        var secondWindowHandlerCount = 0

        firstWindowBridge.installNewWorkspaceHandler {
            firstWindowHandlerCount += 1
        }
        secondWindowBridge.installNewWorkspaceHandler {
            secondWindowHandlerCount += 1
        }

        secondWindowBridge.clearNewWorkspaceHandler()
        firstWindowBridge.requestNewWorkspace()
        secondWindowBridge.requestNewWorkspace()

        #expect(firstWindowHandlerCount == 1)
        #expect(secondWindowHandlerCount == 0)
    }

    @Test("ContentView owns titlebar commands per window")
    func contentViewOwnsTitlebarCommandsPerWindow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains(
            "@StateObject private var sidebarTitlebarCommands = SidebarTitlebarCommandBridge()"
        ))
        #expect(!source.contains("SidebarTitlebarCommandBridge.shared"))
    }
}
