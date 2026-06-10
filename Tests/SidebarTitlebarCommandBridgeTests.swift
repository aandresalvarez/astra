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
}
