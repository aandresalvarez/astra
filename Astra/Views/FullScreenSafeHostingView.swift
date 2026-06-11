import AppKit
import AstraObjCSupport
import os
import SwiftUI

/// `NSHostingView` whose constraint invalidation survives AppKit's
/// display-cycle assertion.
///
/// During the enter-full-screen animation, AppKit lays out the window inside a
/// `CATransaction` commit. If SwiftUI schedules an update mid-pass (observed:
/// `LazyLayoutViewCache.signalPrefetch` → `NSHostingView.setNeedsUpdate`), the
/// resulting `setNeedsUpdateConstraints` bubbles to
/// `-[NSWindow _postWindowNeedsUpdateConstraints]`, which raises an
/// `NSException` while the window is mid-display-cycle —
/// `NSApplicationCrashOnExceptions` (enabled by Sparkle) turns that raise into
/// a crash. The raise unwinds through this view's own setter frame, so trapping
/// here converts it into a retry on the next main-loop turn, after the display
/// cycle has finished.
// File-scope because generic types cannot hold static stored properties.
// Subsystem follows the running bundle so dev/beta channels filter correctly.
private let fullScreenSafeHostingTrapLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ASTRA",
    category: "WindowChrome"
)

@MainActor
final class FullScreenSafeHostingView<Content: View>: NSHostingView<Content> {
    private var retryScheduled = false
    private var trappedCount = 0

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            let raised = AstraExceptionTrap.catching {
                super.needsUpdateConstraints = newValue
            }
            guard let raised, newValue, !retryScheduled else { return }
            trappedCount += 1
            // Visible in Console: a steadily climbing count means something is
            // invalidating constraints mid-display-cycle in a loop, not a
            // one-off full-screen transition.
            fullScreenSafeHostingTrapLogger.warning("Titlebar accessory constraint invalidation trapped (count \(self.trappedCount, privacy: .public)): \(raised.name.rawValue, privacy: .public)")
            retryScheduled = true
            Task { @MainActor [weak self] in
                self?.retryDeferredConstraintInvalidation()
            }
        }
    }

    private func retryDeferredConstraintInvalidation() {
        retryScheduled = false
        _ = AstraExceptionTrap.catching {
            super.needsUpdateConstraints = true
        }
    }
}
