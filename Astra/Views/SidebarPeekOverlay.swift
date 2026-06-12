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

/// Floating presenter for the sidebar's non-docked states. Renders the *same*
/// `SidebarSurface` the docked column uses, in two situations:
///
///  1. **Committed overlay** (`mode == .overlay`): the window is too narrow to
///     dock the column alongside the right panel, so a deliberate "show sidebar"
///     presents the sidebar as a persistent drawer over the detail area, with a
///     tap-to-dismiss scrim. The right rail stays logically present, just occluded.
///  2. **Transient preview** (`mode == .collapsed` + the toggle is hovered): a
///     hover preview of that same drawer, debounced by `SidebarPeekPolicy`.
///
/// It never writes sidebar state directly; dismissal is forwarded to the owner
/// (`SidebarPresentationModel`) via `onDismiss`, so there is still one writer.
struct SidebarPeekContainer<SidebarContent: View>: View {
    /// Current sidebar presentation mode (the single source of truth).
    let mode: SidebarMode
    /// Hover state of the show-sidebar toggle button (the preview's open trigger).
    let isTriggerHovered: Bool
    /// Shared sidebar width, so the floating surface matches the docked column.
    let width: CGFloat
    let reduceMotion: Bool
    /// Collapse the committed overlay (scrim tap) — routed to the owner.
    let onDismiss: () -> Void
    @ViewBuilder var sidebarContent: SidebarContent

    @Environment(\.scenePhase) private var scenePhase
    @State private var isPeeking = false
    @State private var isPanelHovered = false
    @State private var dismissTask: Task<Void, Never>?

    /// Persistent drawer the user committed to on a too-narrow window.
    private var isCommittedOverlay: Bool { mode == .overlay }
    /// Transient hover preview — only while the sidebar is fully collapsed.
    private var isPreviewing: Bool { mode == .collapsed && isPeeking }
    private var isDrawerVisible: Bool { isCommittedOverlay || isPreviewing }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isCommittedOverlay {
                scrim
            }
            if isDrawerVisible {
                SidebarSurface(style: .floating, width: width) {
                    sidebarContent
                }
                .onHover { hovering in
                    isPanelHovered = hovering
                    reconcile()
                }
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sidebar")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Mode-driven visibility (committed overlay, resize transitions) animates
        // here; the transient hover preview animates at its own mutation site.
        .animation(AstraMotion.rightPanel(reduceMotion: reduceMotion), value: mode)
        .accessibilityHidden(!isDrawerVisible)
        .onChange(of: isTriggerHovered) { _, _ in reconcile() }
        .onChange(of: mode) { _, newMode in
            // Left the collapsed state (docked, or committed to an overlay) — drop
            // any transient hover preview so it can't linger as a second surface.
            if newMode != .collapsed { forceDismissPreview() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Don't strand the preview open if the app/window deactivates mid-hover.
            if newPhase != .active { forceDismissPreview() }
        }
        .onDisappear {
            // Cancel any pending dismiss so the detached task can't mutate state
            // after the overlay is torn down.
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    private var scrim: some View {
        Color.black.opacity(0.08)
            .ignoresSafeArea(.all, edges: .top)
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// The preview trigger only counts while the sidebar is fully collapsed —
    /// mirrors the owner's gating so a stale hover can't reopen a preview after
    /// the column docks or the overlay commits.
    private var triggerActive: Bool { mode == .collapsed && isTriggerHovered }
    private var panelActive: Bool { mode == .collapsed && isPanelHovered }

    /// Open the transient preview immediately when either the toggle or the panel
    /// is hovered while collapsed; otherwise start the debounced dismiss.
    private func reconcile() {
        if SidebarPeekPolicy.shouldOpen(triggerHovered: triggerActive, panelHovered: panelActive) {
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
            // window keeps the preview open.
            guard SidebarPeekPolicy.shouldDismiss(
                triggerHovered: triggerActive,
                panelHovered: panelActive
            ) else { return }
            withAnimation(AstraMotion.rightPanel(reduceMotion: reduceMotion)) {
                isPeeking = false
            }
            dismissTask = nil
        }
    }

    private func forceDismissPreview() {
        dismissTask?.cancel()
        dismissTask = nil
        isPanelHovered = false
        guard isPeeking else { return }
        withAnimation(AstraMotion.rightPanel(reduceMotion: reduceMotion)) {
            isPeeking = false
        }
    }
}
