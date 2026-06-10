import AppKit
import AstraObjCSupport
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
@MainActor
final class FullScreenSafeHostingView<Content: View>: NSHostingView<Content> {
    private var retryScheduled = false

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            let raised = AstraExceptionTrap.catching {
                super.needsUpdateConstraints = newValue
            }
            guard raised != nil, newValue, !retryScheduled else { return }
            retryScheduled = true
            DispatchQueue.main.async { [weak self] in
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
