import SwiftUI

/// Event owner for commands emitted from the AppKit-hosted titlebar accessory.
///
/// The accessory is outside `ContentView`'s normal view subtree, so sidebar
/// commands are also emitted through `NotificationCenter`; that avoids relying
/// on SwiftUI view invalidation across the AppKit-hosted `NSHostingView`.
/// Counting keeps repeated clicks observable for tests and diagnostics.
@MainActor
final class SidebarTitlebarCommandBridge: ObservableObject {
    static let shared = SidebarTitlebarCommandBridge()

    static let sidebarToggleRequestedNotification = Notification.Name(
        "SidebarTitlebarCommandBridge.sidebarToggleRequested"
    )
    static let newWorkspaceRequestedNotification = Notification.Name(
        "SidebarTitlebarCommandBridge.newWorkspaceRequested"
    )

    @Published private(set) var toggleRequestID = 0
    @Published private(set) var newWorkspaceRequestID = 0

    private let notificationCenter: NotificationCenter
    private var sidebarToggleHandler: (() -> Void)?
    private var newWorkspaceHandler: (() -> Void)?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func installSidebarToggleHandler(_ handler: @escaping () -> Void) {
        sidebarToggleHandler = handler
    }

    func clearSidebarToggleHandler() {
        sidebarToggleHandler = nil
    }

    func requestSidebarToggle() {
        toggleRequestID &+= 1
        notificationCenter.post(
            name: Self.sidebarToggleRequestedNotification,
            object: self
        )
        sidebarToggleHandler?()
    }

    func installNewWorkspaceHandler(_ handler: @escaping () -> Void) {
        newWorkspaceHandler = handler
    }

    func clearNewWorkspaceHandler() {
        newWorkspaceHandler = nil
    }

    func requestNewWorkspace() {
        newWorkspaceRequestID &+= 1
        notificationCenter.post(
            name: Self.newWorkspaceRequestedNotification,
            object: self
        )
        newWorkspaceHandler?()
    }
}
