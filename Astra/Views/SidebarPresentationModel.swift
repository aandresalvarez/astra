import SwiftUI

/// The single owner of sidebar presentation.
///
/// Replaces the six uncoordinated writers of `NavigationSplitViewVisibility`
/// (the toggle, reveal-from-compact, two width probes, the responsive reconcile,
/// and a settling timer) with one durable intent — `isSidebarShown`, persisted —
/// plus a *pure* derivation of the rendered `SidebarMode`
/// (`PanelLayoutGeometry.sidebarMode`). Width probes, the responsive coordinator,
/// and the AppKit split guard only *propose* changes; this type is the sole place
/// that resolves them. Consequences:
///
///  - The toggle can never be silently undone by a width measurement or a timer.
///  - The `NavigationSplitView` is never torn out of the tree to hide the column,
///    so no visibility write is ever dead.
///  - The docked column and the floating overlay drawer share one width
///    (`sidebarWidth`) and one surface, so the two can't visually diverge.
@MainActor
final class SidebarPresentationModel: ObservableObject {
    /// Rendered presentation, derived purely from intent + width + right-panel presence.
    @Published private(set) var mode: SidebarMode

    /// Shared docked-column width, synced from the live column and reused by the
    /// floating overlay drawer so the two surfaces never desync.
    @Published private(set) var sidebarWidth: CGFloat = SidebarColumnLayout.expandedIdealWidth

    /// True during the open animation; suppresses transient sub-readable-width
    /// collapse proposals while the column expands from zero.
    @Published private(set) var isSettling = false

    // Inputs, pushed in by ContentView. The model never reads the SwiftUI
    // environment directly so its logic stays pure and unit-testable.
    private var responsiveWidth: CGFloat = 0
    private var hasRightSidePanel = false

    /// Transient request to float the sidebar over a too-narrow window. Unlike
    /// `isSidebarShown` this is NOT persisted and does not survive widening — it is
    /// the "pop the drawer" gesture, distinct from the durable dock intent, so a
    /// narrow window never auto-covers the content on launch.
    private var isOverlayOpen = false

    /// Durable "the user wants the sidebar visible" intent. Persisted via
    /// `UserDefaults` directly — deliberately not a SwiftUI AppStorage property,
    /// to keep the audited direct-AppStorage count flat — defaulting to visible
    /// on first run.
    private(set) var isSidebarShown: Bool

    private let defaults: UserDefaults
    private static let shownDefaultsKey = "sidebarUserVisible"

    /// Authoritative end of the reveal guard. The watchdog below is only an
    /// eager UI refresh; every event path that makes a decision based on
    /// `isSettling` first reconciles this monotonic deadline. A delayed or
    /// dropped timer therefore cannot leave collapse handling disabled.
    private var settleDeadline: ContinuousClock.Instant?
    private let monotonicNow: @MainActor () -> ContinuousClock.Instant
    private var settleTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = {
            ContinuousClock().now
        }
    ) {
        self.defaults = defaults
        self.monotonicNow = monotonicNow
        let shown = (defaults.object(forKey: Self.shownDefaultsKey) as? Bool) ?? true
        self.isSidebarShown = shown
        self.mode = PanelLayoutGeometry.sidebarMode(
            width: 0,
            hasRightSidePanel: false,
            wantsDock: shown,
            overlayOpen: false
        )
    }

    // MARK: - Derived view state

    var columnVisibility: NavigationSplitViewVisibility {
        mode.occupiesColumn ? .all : .detailOnly
    }

    /// True while the floating overlay drawer should render (a committed,
    /// persistent overlay — the window is too narrow to dock).
    var showsOverlayDrawer: Bool { mode == .overlay }

    /// The titlebar toggle label follows the rendered surface, not the persisted
    /// dock intent. A narrow window can preserve the dock intent while still
    /// rendering the sidebar as hidden.
    var isSidebarHidden: Bool { mode == .collapsed }

    /// In compact layouts with a right-side panel open, the most predictable
    /// "show sidebar" action is to clear the competing panel and dock the sidebar
    /// if the remaining window can fit sidebar + detail.
    var shouldClearRightSidePanelBeforeReveal: Bool {
        responsiveWidth > 0
            && mode == .collapsed
            && hasRightSidePanel
            && PanelLayoutGeometry.canDockSidebar(width: responsiveWidth, hasRightSidePanel: false)
    }

    /// Binding for `NavigationSplitView(columnVisibility:)`. Reads the derived
    /// visibility; a genuine write back (e.g. the user dragging the divider fully
    /// closed) folds into the durable intent, so there is still exactly one owner.
    func columnVisibilityBinding() -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { self.columnVisibility },
            set: { [weak self] newValue in
                self?.applyExternalColumnVisibility(newValue)
            }
        )
    }

    // MARK: - Intent (the only durable state)

    /// The titlebar toggle. On a window wide enough to dock, it flips the durable
    /// dock intent; on a too-narrow window it pops (or closes) the transient
    /// overlay drawer without touching the persisted intent.
    func toggle() {
        reconcileSettleDeadline()
        if PanelLayoutGeometry.canDockSidebar(width: responsiveWidth, hasRightSidePanel: hasRightSidePanel) {
            setShown(!isSidebarShown)
        } else {
            setOverlayOpen(!isOverlayOpen)
        }
    }

    /// Collapse when the user picks something out of the overlay drawer — the
    /// drawer is space-constrained, so a selection dismisses it. No-op while
    /// docked (a real column stays put on selection). Only the transient overlay
    /// flag is touched; the durable dock intent is preserved.
    func handleSelectionCommitted() {
        reconcileSettleDeadline()
        guard mode == .overlay else { return }
        setOverlayOpen(false)
    }

    /// Caller has cleared the right-side panel to make room for a docked reveal.
    /// Preserve/commit the user's visible-sidebar intent and start the same settle
    /// window as a normal docked reveal.
    func revealAfterClearingRightSidePanel() {
        reconcileSettleDeadline()
        isOverlayOpen = false
        hasRightSidePanel = false
        if isSidebarShown {
            beginSettle()
            resolve()
        } else {
            setShown(true)
        }
    }

    /// Tap-outside / scrim dismissal of the overlay drawer.
    func dismissOverlay() {
        reconcileSettleDeadline()
        guard mode == .overlay else { return }
        setOverlayOpen(false)
    }

    private func setShown(_ shown: Bool) {
        guard shown != isSidebarShown else { return }
        isSidebarShown = shown
        defaults.set(shown, forKey: Self.shownDefaultsKey)
        if shown { beginSettle() } else { endSettle() }
        resolve()
    }

    private func setOverlayOpen(_ open: Bool) {
        guard open != isOverlayOpen else { return }
        isOverlayOpen = open
        resolve()
    }

    // MARK: - Proposals from layout probes

    func setResponsiveWidth(_ width: CGFloat) {
        reconcileSettleDeadline()
        guard width.isFinite, width != responsiveWidth else { return }
        responsiveWidth = width
        resolve()
    }

    func setHasRightSidePanel(_ value: Bool) {
        reconcileSettleDeadline()
        guard value != hasRightSidePanel else { return }
        hasRightSidePanel = value
        resolve()
    }

    /// Live docked-column width from the sidebar's GeometryReader. Syncs the
    /// shared width, completes the open-settle once the column is readable, and
    /// (outside the settle window) collapses a column the user dragged below
    /// readable width.
    func noteColumnWidth(_ width: CGFloat) {
        reconcileSettleDeadline()
        guard width.isFinite, width > 0 else { return }
        let clamped = min(
            max(width, SidebarColumnLayout.expandedMinimumWidth),
            SidebarColumnLayout.expandedMaximumWidth
        )
        if clamped != sidebarWidth { sidebarWidth = clamped }

        if isSettling {
            return
        }
        if mode == .docked, width < SidebarColumnLayout.expandedMinimumWidth {
            setShown(false)
        }
    }

    /// Live AppKit split-subview width from `SidebarSplitViewGuard`. Unlike the
    /// SwiftUI content width, this reflects the actual split pane becoming
    /// readable, so it is safe to end the reveal-settle guard.
    func noteReadableSplitSubviewWidth(_ width: CGFloat) {
        reconcileSettleDeadline()
        guard isSettling,
              SidebarColumnLayout.shouldCompleteSidebarReveal(width: width) else {
            return
        }
        endSettle()
    }

    /// The AppKit split guard observed the column squeezed below readable width.
    /// Idempotent with the SwiftUI-side `noteColumnWidth` collapse — both just set
    /// the one intent flag, so the two probes can't race into different states.
    func proposeCompressedCollapse() {
        reconcileSettleDeadline()
        guard !isSettling, mode == .docked else { return }
        setShown(false)
    }

    // MARK: - Settle window

    private func beginSettle() {
        let deadline = monotonicNow().advanced(
            by: .nanoseconds(Int64(SidebarRevealSettlingPolicy.fallbackDelayNanoseconds))
        )
        settleDeadline = deadline
        isSettling = true
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: SidebarRevealSettlingPolicy.fallbackDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // The AppKit probe normally ends settling earlier. This watchdog is
            // only an eager refresh. The deadline remains authoritative when
            // timer delivery is delayed or missed.
            reconcileSettleDeadline(expectedDeadline: deadline)
        }
    }

    private func endSettle() {
        settleTask?.cancel()
        settleTask = nil
        settleDeadline = nil
        if isSettling { isSettling = false }
    }

    /// Reconciles the deadline before any event path trusts `isSettling`.
    /// `expectedDeadline` prevents an old cancelled watchdog from clearing a
    /// newer reveal window if cancellation races with task delivery.
    private func reconcileSettleDeadline(
        expectedDeadline: ContinuousClock.Instant? = nil
    ) {
        guard isSettling, let deadline = settleDeadline else { return }
        if let expectedDeadline, expectedDeadline != deadline { return }
        guard monotonicNow() >= deadline else { return }
        endSettle()
    }

    private func applyExternalColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
        reconcileSettleDeadline()
        // NavigationSplitView drives this only when the user collapses/expands the
        // column itself (the native toggle is suppressed). Ignore echoes that match
        // the value we already derive — both `.overlay` and `.collapsed` map to
        // `.detailOnly`, and an echo there is not a user collapse.
        guard visibility != columnVisibility else { return }
        if visibility == .detailOnly {
            // During a reveal, SwiftUI can echo the previous collapsed split-view
            // value before AppKit has expanded the sidebar column. That is layout
            // feedback, not the user's collapse intent.
            guard !isSettling else { return }
            setShown(false)
            return
        }
        if PanelLayoutGeometry.canDockSidebar(width: responsiveWidth, hasRightSidePanel: hasRightSidePanel) {
            setShown(true)
        } else {
            setOverlayOpen(true)
        }
    }

    // MARK: - Resolution (the single place `mode` is computed)

    private func resolve() {
        // Leaving the can't-dock regime retires any transient overlay, so a later
        // narrowing starts from collapsed rather than re-floating a stale drawer.
        if isOverlayOpen,
           PanelLayoutGeometry.canDockSidebar(width: responsiveWidth, hasRightSidePanel: hasRightSidePanel) {
            isOverlayOpen = false
        }
        let newMode = PanelLayoutGeometry.sidebarMode(
            width: responsiveWidth,
            hasRightSidePanel: hasRightSidePanel,
            wantsDock: isSidebarShown,
            overlayOpen: isOverlayOpen
        )
        if newMode != mode { mode = newMode }
    }
}
