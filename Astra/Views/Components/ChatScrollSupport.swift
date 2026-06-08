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
        .help(hasUnseenActivity ? "Jump to latest activity" : "Scroll to latest")
        .padding(.bottom, 10)
    }
}
