import SwiftUI

// Shared scroll primitives for the app's chat surfaces (TaskMainView, ChatPanelView).
// These are intentionally stateless: the per-surface auto-follow *policy* legitimately
// differs (snapshot-signature driven vs. message-count driven, with/without top-window
// expansion), but the "how far am I from the bottom" measurement and the jump-to-latest
// affordance are identical and live here so the two surfaces cannot drift apart.

/// Reports the bottom sentinel's `minY` within a named scroll coordinate space, so a
/// view can tell whether the transcript is scrolled to (or near) the bottom.
struct ChatBottomPositionPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum ChatScrollMetrics {
    /// A bottom sentinel within this many points of the viewport bottom counts as
    /// "at bottom" — gives a little hysteresis so the jump pill doesn't flicker and
    /// live output still tail-follows when the user is essentially at the end.
    static let atBottomSlop: CGFloat = 80

    static func isAtBottom(bottomMinY: CGFloat, viewportHeight: CGFloat) -> Bool {
        // Before the sentinel reports, the preference holds its non-finite default
        // (`.infinity`). Treat "no measurement yet" as at-bottom so the jump pill never
        // flashes in before the first real layout pass settles.
        guard bottomMinY.isFinite else { return true }
        return bottomMinY <= viewportHeight + atBottomSlop
    }

    /// A bottom sentinel a settled scroll view can never legitimately report: resting
    /// at the bottom puts it at `minY ≈ viewportHeight`; resting anywhere higher (short
    /// content, or still scrolled up) only ever pushes it *more* positive. A negative
    /// reading means the sentinel — the transcript's actual last pixel — has already
    /// scrolled above the viewport's top edge, i.e. the viewport is parked in empty
    /// space past the end of the content. That happens when a one-shot `scrollTo` is
    /// computed against a taller, pre-relayout height (e.g. a streaming bubble that
    /// hasn't yet collapsed into its shorter, completed presentation) and the layout
    /// then shrinks out from under it. `isAtBottom` deliberately can't tell this apart
    /// from a normal rest (both satisfy `bottomMinY <= viewportHeight + slop`) — this is
    /// a separate, stricter check callers use only to decide whether to force a
    /// corrective re-scroll. The small negative deadband absorbs sub-pixel layout
    /// rounding at a genuine rest so that doesn't misfire as parked.
    static let overscrollParkThreshold: CGFloat = -4

    static func isParkedPastContent(bottomMinY: CGFloat) -> Bool {
        guard bottomMinY.isFinite else { return false }
        return bottomMinY < overscrollParkThreshold
    }

    /// A 1pt clear sentinel to place at the very end of a transcript's scroll content.
    /// Read its position via `.named(coordinateSpace)` to drive `isAtBottom`, and use
    /// its `.id` as a `scrollTo` target.
    static func bottomSentinel(id: String, coordinateSpace: String) -> some View {
        Color.clear
            .frame(height: 1)
            .id(id)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatBottomPositionPreferenceKey.self,
                        value: proxy.frame(in: .named(coordinateSpace)).minY
                    )
                }
            )
    }
}

/// Watchdog for the parked-scroll state `ChatScrollMetrics.isParkedPastContent`
/// detects. Feed it every bottom-sentinel reading; it arms a settle-delay timer the
/// first time a reading looks parked, and fires `onRecover` only if the sentinel is
/// *still* parked once the delay elapses. A reading that recovers on its own (e.g.
/// natural trackpad bounce springing back) cancels the pending timer, so this never
/// fights a live, legitimate scroll gesture — it only catches a scroll that's
/// genuinely stuck past the end of the content with nothing left to move it.
///
/// A class (not a struct) so a view can hold one stably across re-renders via
/// `@State`, matching `TaskThreadViewModel`'s pattern in the same view. Kept free of
/// any view/proxy dependency — `onRecover` is the only side effect — so the debounce
/// logic itself is unit-testable without hosting a live `ScrollViewProxy`.
@MainActor
final class ChatScrollRecoveryWatchdog {
    private let settleNanoseconds: UInt64
    private var armedToken = 0

    init(settleNanoseconds: UInt64 = 220_000_000) {
        self.settleNanoseconds = settleNanoseconds
    }

    func sentinelDidUpdate(
        bottomMinY: CGFloat,
        currentBottomMinY: @escaping () -> CGFloat,
        onRecover: @escaping () -> Void
    ) {
        armedToken += 1
        guard ChatScrollMetrics.isParkedPastContent(bottomMinY: bottomMinY) else { return }
        let token = armedToken
        Task {
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            guard token == armedToken, !Task.isCancelled else { return }
            // Re-check the live reading rather than trusting the value captured when
            // this timer armed: only a sentinel that's still parked once the delay
            // elapses should trigger a corrective scroll.
            guard ChatScrollMetrics.isParkedPastContent(bottomMinY: currentBottomMinY()) else { return }
            onRecover()
        }
    }
}

/// Floating "scroll to latest" pill shown whenever the user is scrolled away from the
/// bottom of a chat transcript. `hasUnseenActivity` only changes the emphasis (label,
/// accent, dot) — it does not gate visibility, so this works both as a live "new
/// activity" nudge and as a plain "get me back to the bottom" affordance while reading
/// history. The HStack uses default (center) alignment and carries no selectable text,
/// so it does not risk the `.firstTextBaseline` + `.textSelection` layout-loop freeze.
struct ChatJumpToLatestButton: View {
    let hasUnseenActivity: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(Stanford.ui(11))
                Text(hasUnseenActivity ? "New activity" : "Jump to latest")
                    .font(Stanford.chatSection())
                if hasUnseenActivity {
                    Circle()
                        .fill(Stanford.lagunita)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThickMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        Stanford.lagunita.opacity(hasUnseenActivity ? 0.45 : 0.25),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(hasUnseenActivity ? "Jump to latest activity" : "Jump to latest")
        .padding(.bottom, 10)
    }
}
