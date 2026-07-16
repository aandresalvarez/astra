import Foundation
import SwiftUI
import Testing
@testable import ASTRA

/// Behavioural contract for the single owner of sidebar visibility. These lock in
/// the two bugs the model was built to kill — the sidebar must not present as two
/// different surfaces, and a deliberately-shown sidebar must never be silently
/// undone by a width measurement or a right-panel re-presentation — plus the rule
/// that a too-narrow window never auto-covers content (overlay is explicit).
@MainActor
@Suite("SidebarPresentationModel")
struct SidebarPresentationModelTests {

    private func makeModel(shown: Bool) -> SidebarPresentationModel {
        let defaults = UserDefaults(suiteName: "sidebar.test.\(UUID().uuidString)")!
        defaults.set(shown, forKey: "sidebarUserVisible")
        return SidebarPresentationModel(defaults: defaults)
    }

    // MARK: - Mode derivation

    @Test("Docks when shown and the window is wide enough for sidebar + rail + detail")
    func docksWhenWide() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_400)
        #expect(model.mode == .docked)
        #expect(model.columnVisibility == .all)
        #expect(model.showsOverlayDrawer == false)
    }

    @Test("Docks at a narrow width when there is no right panel competing for space")
    func docksWhenNarrowWithoutRightPanel() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_000) // >= 310 + 480
        #expect(model.mode == .docked)
    }

    @Test("Too narrow to dock collapses (no intrusive auto-overlay) until the overlay is opened")
    func tooNarrowCollapsesUntilOverlayOpened() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        // Shown, but can't dock alongside the rail → collapsed, NOT a floating drawer.
        #expect(model.mode == .collapsed)
        #expect(model.showsOverlayDrawer == false)

        // Explicit toggle pops the transient overlay.
        model.toggle()
        #expect(model.mode == .overlay)
        #expect(model.columnVisibility == .detailOnly)
        #expect(model.showsOverlayDrawer)
    }

    @Test("Compact reveal asks the caller to clear the right panel when that would make room to dock")
    func compactRevealCanClearRightPanelToDock() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        #expect(model.mode == .collapsed)
        #expect(model.shouldClearRightSidePanelBeforeReveal)

        model.revealAfterClearingRightSidePanel()

        #expect(model.isSidebarShown)
        #expect(model.mode == .docked)
        #expect(model.columnVisibility == .all)
    }

    @Test("Compact reveal keeps the overlay fallback when clearing the right panel still cannot dock")
    func compactRevealKeepsOverlayFallbackWhenTooNarrowToDock() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(700)
        #expect(model.mode == .collapsed)
        #expect(model.shouldClearRightSidePanelBeforeReveal == false)

        model.toggle()

        #expect(model.mode == .overlay)
        #expect(model.isSidebarShown == false)
    }

    @Test("Collapsed whenever the user has not asked for the sidebar")
    func collapsedWhenIntentFalse() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_400)
        #expect(model.mode == .collapsed)
        #expect(model.columnVisibility == .detailOnly)
    }

    @Test("Rendered hidden state follows the actual mode rather than persisted dock intent")
    func renderedHiddenStateFollowsMode() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        #expect(model.mode == .collapsed)
        #expect(model.isSidebarHidden)

        model.toggle()
        #expect(model.mode == .overlay)
        #expect(model.isSidebarHidden == false)

        model.setResponsiveWidth(1_400)
        #expect(model.mode == .docked)
        #expect(model.isSidebarHidden == false)
    }

    // MARK: - Problem B: intent survives responsive events

    @Test("Opening the right rail at narrow width hides the docked sidebar but preserves the dock intent")
    func rightRailRepresentationPreservesDockIntent() {
        let model = makeModel(shown: true)
        model.setResponsiveWidth(1_000)
        model.setHasRightSidePanel(false)
        #expect(model.mode == .docked)

        // The exact Problem-B trigger: a right panel appears while narrow.
        model.setHasRightSidePanel(true)
        #expect(model.mode == .collapsed)     // presentation yields…
        #expect(model.isSidebarShown)         // …but the dock intent does NOT flip off.

        // Closing the rail re-docks — no re-toggle needed.
        model.setHasRightSidePanel(false)
        #expect(model.mode == .docked)
        #expect(model.isSidebarShown)
    }

    @Test("Widening re-docks a sidebar that narrowing had hidden, with no re-toggle")
    func wideningRedocksWithoutRetoggle() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        #expect(model.mode == .collapsed)

        model.setResponsiveWidth(1_400)
        #expect(model.mode == .docked)
        #expect(model.isSidebarShown)
    }

    // MARK: - Toggle + persistence

    @Test("Toggle on a dockable window flips and persists the durable intent")
    func togglePersistsIntentWhenDockable() {
        let defaults = UserDefaults(suiteName: "sidebar.test.\(UUID().uuidString)")!
        defaults.set(true, forKey: "sidebarUserVisible")
        let model = SidebarPresentationModel(defaults: defaults)
        model.setResponsiveWidth(1_400)
        model.setHasRightSidePanel(false)

        model.toggle()
        #expect(model.isSidebarShown == false)
        #expect(defaults.object(forKey: "sidebarUserVisible") as? Bool == false)

        let reborn = SidebarPresentationModel(defaults: defaults)
        #expect(reborn.isSidebarShown == false)
    }

    @Test("Toggle on a too-narrow window opens a transient overlay without touching the persisted intent")
    func toggleNarrowOpensTransientOverlay() {
        let model = makeModel(shown: false)        // dock intent is OFF
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        #expect(model.mode == .collapsed)

        model.toggle()                              // can't dock → pops overlay
        #expect(model.mode == .overlay)
        #expect(model.isSidebarShown == false)      // persisted intent untouched

        model.dismissOverlay()
        #expect(model.mode == .collapsed)
        #expect(model.isSidebarShown == false)

        // A transient overlay does not become a docked sidebar on widening.
        model.setResponsiveWidth(1_400)
        #expect(model.mode == .collapsed)
    }

    @Test("First run with no stored preference defaults to shown")
    func defaultsToShownOnFirstRun() {
        let defaults = UserDefaults(suiteName: "sidebar.test.\(UUID().uuidString)")!
        let model = SidebarPresentationModel(defaults: defaults)
        #expect(model.isSidebarShown)
    }

    // MARK: - Width probes / settle

    @Test("Compressed-collapse proposals are ignored during the open settle window")
    func compressedCollapseSuppressedWhileSettling() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_000)

        model.toggle()                       // dockable → shown, docked, settling
        #expect(model.mode == .docked)
        #expect(model.isSettling)

        model.proposeCompressedCollapse()     // ignored while settling
        #expect(model.mode == .docked)
        #expect(model.isSidebarShown)

        model.noteColumnWidth(320)            // may be stale during reveal; keep settling
        #expect(model.isSettling)

        model.proposeCompressedCollapse()
        #expect(model.mode == .docked)
        #expect(model.isSidebarShown)
    }

    @Test("Readable AppKit split width completes the reveal settle window")
    func readableSplitSubviewWidthCompletesSettling() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_400)

        model.toggle()
        #expect(model.isSettling)

        model.noteReadableSplitSubviewWidth(SidebarColumnLayout.expandedMinimumWidth)

        #expect(model.isSettling == false)
    }

    @Test("Reveal settle watchdog recovers when the AppKit width probe is missed")
    func revealSettleWatchdogRecoversWithoutProbe() async throws {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_400)

        model.toggle()
        #expect(model.isSettling)

        try await Task.sleep(for: .milliseconds(600))

        #expect(!model.isSettling)
        model.proposeCompressedCollapse()
        #expect(model.mode == .collapsed)
    }

    @Test("Column width syncs the shared sidebar width, clamped to the readable range")
    func noteColumnWidthSyncsClampedWidth() {
        let model = makeModel(shown: true)
        model.setResponsiveWidth(1_400)
        model.noteColumnWidth(350)
        #expect(model.sidebarWidth == 350)
        model.noteColumnWidth(500)            // above max -> clamp
        #expect(model.sidebarWidth == SidebarColumnLayout.expandedMaximumWidth)
    }

    // MARK: - Overlay dismissal

    @Test("Overlay dismissal only applies while overlaid and leaves the dock intent intact")
    func overlayDismissalScopedToOverlay() {
        let overlay = makeModel(shown: true)
        overlay.setHasRightSidePanel(true)
        overlay.setResponsiveWidth(1_000)
        overlay.toggle()                      // open transient overlay
        #expect(overlay.mode == .overlay)
        overlay.dismissOverlay()
        #expect(overlay.mode == .collapsed)
        #expect(overlay.isSidebarShown)       // dock intent preserved

        let docked = makeModel(shown: true)
        docked.setHasRightSidePanel(false)
        docked.setResponsiveWidth(1_400)
        #expect(docked.mode == .docked)
        docked.dismissOverlay()               // no-op while docked
        #expect(docked.mode == .docked)
    }

    @Test("Selecting from the overlay drawer dismisses it; selecting while docked does not")
    func selectionDismissesOnlyOverlay() {
        let overlay = makeModel(shown: true)
        overlay.setHasRightSidePanel(true)
        overlay.setResponsiveWidth(1_000)
        overlay.toggle()
        #expect(overlay.mode == .overlay)
        overlay.handleSelectionCommitted()
        #expect(overlay.mode == .collapsed)

        let docked = makeModel(shown: true)
        docked.setHasRightSidePanel(false)
        docked.setResponsiveWidth(1_400)
        docked.handleSelectionCommitted()
        #expect(docked.mode == .docked)
    }

    // MARK: - External column-visibility writes

    @Test("A NavigationSplitView collapse write folds into the durable intent")
    func externalCollapseFoldsIntoIntent() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_400)
        #expect(model.mode == .docked)

        model.columnVisibilityBinding().wrappedValue = .detailOnly
        #expect(model.isSidebarShown == false)
        #expect(model.mode == .collapsed)
    }

    @Test("A transient split-view collapse echo is ignored while a dock reveal is settling")
    func externalCollapseEchoIgnoredDuringDockRevealSettle() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_400)
        #expect(model.mode == .collapsed)

        model.toggle()
        #expect(model.mode == .docked)
        #expect(model.columnVisibility == .all)
        #expect(model.isSettling)

        model.columnVisibilityBinding().wrappedValue = .detailOnly
        #expect(model.isSidebarShown)
        #expect(model.mode == .docked)
        #expect(model.columnVisibility == .all)
        #expect(model.isSettling)
    }

    @Test("A stale readable width does not end reveal settling before a collapse echo")
    func staleReadableWidthDoesNotExposeDelayedCollapseEcho() {
        let model = makeModel(shown: false)
        model.setHasRightSidePanel(false)
        model.setResponsiveWidth(1_400)

        model.toggle()
        #expect(model.mode == .docked)
        #expect(model.isSettling)

        model.noteColumnWidth(SidebarColumnLayout.expandedMinimumWidth)
        model.columnVisibilityBinding().wrappedValue = .detailOnly

        #expect(model.isSidebarShown)
        #expect(model.mode == .docked)
        #expect(model.columnVisibility == .all)
        #expect(model.isSettling)
    }

    @Test("An echo write matching the derived overlay visibility does not collapse the overlay")
    func externalEchoDoesNotCollapseOverlay() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        model.toggle()                        // open transient overlay
        #expect(model.mode == .overlay)
        #expect(model.columnVisibility == .detailOnly)

        // SwiftUI echoing the value it was handed must be a no-op, not a collapse.
        model.columnVisibilityBinding().wrappedValue = .detailOnly
        #expect(model.mode == .overlay)
    }

    @Test("An external show request opens the overlay when the sidebar cannot dock")
    func externalShowOpensOverlayWhenCannotDock() {
        let model = makeModel(shown: true)
        model.setHasRightSidePanel(true)
        model.setResponsiveWidth(1_000)
        #expect(model.mode == .collapsed)
        #expect(model.isSidebarShown)

        model.columnVisibilityBinding().wrappedValue = .all

        #expect(model.mode == .overlay)
        #expect(model.columnVisibility == .detailOnly)
        #expect(model.isSidebarShown)
    }
}
