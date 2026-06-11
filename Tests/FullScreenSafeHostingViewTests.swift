import AppKit
import SwiftUI
import Testing
@testable import ASTRA

@Suite("Full-screen safe hosting view")
@MainActor
struct FullScreenSafeHostingViewTests {
    // The AppKit display-cycle exception itself can't be raised headlessly, so
    // this exercises the override's happy path: repeated invalidation through
    // the trapped setter must keep working and never wedge.
    @Test("trapped setter keeps accepting constraint invalidation")
    func constraintInvalidationRoundTrips() {
        let host = FullScreenSafeHostingView(rootView: Text("titlebar"))

        host.needsUpdateConstraints = true
        #expect(host.needsUpdateConstraints)

        // Constraint pass clears the flag; setting again must keep working
        // (the deferred-retry path must not wedge the setter).
        host.updateConstraintsForSubtreeIfNeeded()
        host.needsUpdateConstraints = true
        #expect(host.needsUpdateConstraints)
    }

    /// The titlebar accessory crashes in full screen with a plain
    /// `NSHostingView` (AppKit raises when SwiftUI invalidates constraints
    /// mid-display-cycle), so the configurator must build the trapped subclass.
    @Test("window chrome accessory uses the full-screen safe hosting view")
    func windowChromeUsesSafeHostingView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/WindowChromeConfigurator.swift"),
            encoding: .utf8
        )
        #expect(source.contains("FullScreenSafeHostingView(rootView:"))
        #expect(!source.contains("= NSHostingView(rootView:"))
    }
}
