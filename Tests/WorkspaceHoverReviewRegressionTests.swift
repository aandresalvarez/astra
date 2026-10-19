import AppKit
import Testing
@testable import ASTRA

@Suite("Workspace hover review regressions", .serialized)
@MainActor
struct WorkspaceHoverReviewRegressionTests {
    @Test("An unconfigured workspace never resolves to the process working directory",
          arguments: ["", " ", "\n\t"])
    func missingFolder(path: String) {
        #expect(WorkspaceFinderDestination.url(for: path) == nil)
    }

    @Test("Configured paths retain spaces and non-ASCII folder names")
    func configuredFolder() {
        let path = "/tmp/Anna Sofía Proyecto"
        #expect(WorkspaceFinderDestination.url(for: path)?.path == path)
    }

    @Test("Switching to another window dismisses the passive card")
    func parentLosesKey() async {
        let fixture = FocusFixture()
        defer { fixture.tearDown() }
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.parent)
        fixture.keyWindow = fixture.other
        await fixture.settle()
        #expect(fixture.dismissals == 1)
    }

    @Test("Keyboard focus can enter the card, then leave it for another window")
    func keyboardFocus() async {
        let fixture = FocusFixture()
        defer { fixture.tearDown() }
        // AppKit resigns the old key window before the new one takes over.
        fixture.keyWindow = nil
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.parent)
        fixture.keyWindow = fixture.panel
        await fixture.settle()
        #expect(fixture.dismissals == 0)
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.panel)
        fixture.keyWindow = fixture.other
        await fixture.settle()
        #expect(fixture.dismissals == 1)
    }

    @Test("Returning from the card to its parent keeps the card available")
    func returnToParent() async {
        let fixture = FocusFixture()
        defer { fixture.tearDown() }
        fixture.keyWindow = fixture.panel
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.panel)
        fixture.keyWindow = fixture.parent
        await fixture.settle()
        #expect(fixture.dismissals == 0)
    }

    @Test("Losing all key windows dismisses once even when parent and panel both resign")
    func noKeyWindow() async {
        let fixture = FocusFixture()
        defer { fixture.tearDown() }
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.parent)
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.panel)
        fixture.keyWindow = nil
        await fixture.settle()
        #expect(fixture.dismissals == 1)
    }

    @Test("Unrelated windows and invalidated notifications cannot dismiss a card")
    func observerScope() async {
        let fixture = FocusFixture()
        defer { fixture.tearDown() }
        fixture.keyWindow = fixture.other
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.other)
        #expect(fixture.lifetime.pendingFocusCheck == nil)
        #expect(fixture.dismissals == 0)
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.parent)
        let pending = fixture.lifetime.pendingFocusCheck
        #expect(pending != nil)
        fixture.lifetime.invalidate()
        await pending?.value
        #expect(fixture.dismissals == 0)
        fixture.notifications.post(name: NSWindow.didResizeNotification, object: fixture.parent)
        #expect(fixture.dismissals == 0)
    }

    @Test("Parent geometry, closing, and app deactivation still dismiss the card",
          arguments: [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                      NSWindow.willCloseNotification, NSApplication.didResignActiveNotification])
    func existingDismissals(name: Notification.Name) {
        let fixture = FocusFixture()
        defer { fixture.tearDown() }
        fixture.notifications.post(name: name, object: fixture.parent)
        #expect(fixture.dismissals == 1)
    }
}

@MainActor
private final class FocusFixture {
    let notifications = NotificationCenter()
    let parent = NSWindow()
    let panel = NSPanel()
    let other = NSWindow()
    var keyWindow: NSWindow?
    var dismissals = 0
    var lifetime: WorkspaceHoverWindowLifetime!

    init() {
        for window in [parent, panel, other] { window.isReleasedWhenClosed = false }
        keyWindow = parent
        lifetime = WorkspaceHoverWindowLifetime(parent: parent, panel: panel, notifications: notifications,
                                                keyWindow: { [weak self] in self?.keyWindow }) { [weak self] in
            self?.dismissals += 1
        }
    }

    func settle() async {
        let pending = lifetime.pendingFocusCheck
        #expect(pending != nil)
        await pending?.value
    }

    func tearDown() {
        lifetime.invalidate()
        for window in [parent, panel, other] { window.close() }
    }
}
