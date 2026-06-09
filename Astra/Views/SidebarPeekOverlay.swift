import SwiftUI

/// Pure, view-free timing/decision policy for the hover-to-peek sidebar.
/// Mirrors `SidebarRevealSettlingPolicy` so the open/dismiss rules can be
/// reasoned about — and unit-tested — in isolation from any view state.
enum SidebarPeekPolicy {
    /// Grace period after the pointer leaves *both* the show-sidebar toggle and the
    /// panel before the peek dismisses. Absorbs fast diagonal exits and the few-pixel
    /// gap as the pointer crosses from the toggle into the panel.
    static let dismissDelayNanoseconds: UInt64 = 180_000_000

    static func shouldOpen(triggerHovered: Bool, panelHovered: Bool) -> Bool {
        triggerHovered || panelHovered
    }

    static func shouldDismiss(triggerHovered: Bool, panelHovered: Bool) -> Bool {
        !triggerHovered && !panelHovered
    }
}

/// Floating sidebar panel shown when the user peeks the collapsed sidebar.
///
/// Reuses the real sidebar content (injected) inside fixed-width chrome that
/// floats *over* the detail area. It deliberately carries none of the
/// `NavigationSplitView` sizing modifiers, so it never participates in the split
/// layout and cannot feed the collapse/reveal loop that `SidebarSplitViewGuard`
/// exists to suppress.
struct SidebarPeekPanel<Content: View>: View {
    let reduceMotion: Bool
    @Binding var isHovered: Bool
    let onHoverChange: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: SidebarColumnLayout.expandedIdealWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.ultraThickMaterial)
            .overlay(alignment: .trailing) {
                // Hairline so the panel reads as a distinct surface over light
                // detail content, complementing the trailing shadow.
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 16, x: 6, y: 0)
            .onHover { hovering in
                isHovered = hovering
                onHoverChange()
            }
            .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
    }
}

/// Owns the transient hover-to-peek state and renders the floating sidebar panel.
/// Extracted from `ContentView` so the peek lives behind a focused boundary (and so
/// `ContentView` stays within its architecture size budget). The peek is a pure
/// overlay and never mutates `splitVisibility`, so it can't feed the collapse/reveal
/// loop that `SidebarSplitViewGuard` suppresses.
///
/// The host passes `isTriggerHovered` from the show-sidebar toggle button's hover;
/// the panel keeps itself open while hovered, and a debounced grace window
/// (`SidebarPeekPolicy`) absorbs the pointer crossing from the toggle into the panel.
struct SidebarPeekContainer<SidebarContent: View>: View {
    /// True while the sidebar column is collapsed — the peek only applies then.
    let isColumnHidden: Bool
    /// Hover state of the show-sidebar toggle button (the peek's open trigger).
    let isTriggerHovered: Bool
    let reduceMotion: Bool
    @ViewBuilder var sidebarContent: SidebarContent

    @Environment(\.scenePhase) private var scenePhase
    @State private var isPeeking = false
    @State private var isPanelHovered = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isColumnHidden, isPeeking {
                SidebarPeekPanel(
                    reduceMotion: reduceMotion,
                    isHovered: $isPanelHovered,
                    onHoverChange: reconcile
                ) {
                    sidebarContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The panel only renders when the column is hidden AND peeking, so mirror both
        // here — otherwise a brief column-visible+peeking state would expose an empty
        // overlay to accessibility.
        .accessibilityHidden(!(isColumnHidden && isPeeking))
        .onChange(of: isTriggerHovered) { _, _ in reconcile() }
        .onChange(of: isColumnHidden) { _, hidden in
            // Sidebar re-expanded (or compact layout changed) — drop any open peek.
            if !hidden { forceDismiss() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Don't strand the peek open if the app/window deactivates mid-hover.
            if newPhase != .active { forceDismiss() }
        }
        .onDisappear {
            // Cancel any pending dismiss so the detached task can't mutate state
            // after the overlay is torn down.
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    /// The open trigger only counts while the column is actually hidden — mirrors the
    /// host's gating so a stale hover can't reopen a peek after the sidebar returns.
    private var triggerActive: Bool { isColumnHidden && isTriggerHovered }

    /// Open immediately when either the toggle or the panel is hovered; otherwise
    /// start the debounced dismiss.
    private func reconcile() {
        if SidebarPeekPolicy.shouldOpen(triggerHovered: triggerActive, panelHovered: isPanelHovered) {
            dismissTask?.cancel()
            dismissTask = nil
            if !isPeeking {
                withAnimation(AstraMotion.rightPanel(reduceMotion: reduceMotion)) {
                    isPeeking = true
                }
            }
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: SidebarPeekPolicy.dismissDelayNanoseconds)
            guard !Task.isCancelled else { return }
            // Re-check live hover state at fire time so a re-entry during the grace
            // window keeps the peek open.
            guard SidebarPeekPolicy.shouldDismiss(
                triggerHovered: triggerActive,
                panelHovered: isPanelHovered
            ) else { return }
            withAnimation(AstraMotion.rightPanel(reduceMotion: reduceMotion)) {
                isPeeking = false
            }
            dismissTask = nil
        }
    }

    private func forceDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        isPanelHovered = false
        guard isPeeking else { return }
        withAnimation(AstraMotion.rightPanel(reduceMotion: reduceMotion)) {
            isPeeking = false
        }
    }
}
