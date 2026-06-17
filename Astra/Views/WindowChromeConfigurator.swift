import AppKit
import SwiftUI

struct WindowChromeCommandBarState: Equatable {
    let isSearchActive: Bool
    let isSidebarHidden: Bool
    let titleBarHeight: CGFloat?
}

enum WindowChromeCommandBarRefreshPolicy {
    static func shouldRefresh(
        previous: WindowChromeCommandBarState?,
        next: WindowChromeCommandBarState
    ) -> Bool {
        previous != next
    }
}

/// Small AppKit bridge for window chrome that SwiftUI does not fully expose on macOS 14.
///
/// Besides the transparent/unified titlebar tweaks, this installs a leading
/// *titlebar accessory* hosting `AstraLeadingCommandBar`. AppKit pins that
/// accessory right after the traffic lights in every layout, which SwiftUI
/// toolbar placement can't do inside a `NavigationSplitView` (where `.navigation`
/// items slide to the detail column's leading edge when the sidebar is open).
struct WindowChromeConfigurator: NSViewRepresentable {
    @Binding var isSearchActive: Bool
    let sidebarCommands: SidebarTitlebarCommandBridge
    @Binding var isSidebarToggleHovered: Bool
    var isSidebarHidden: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureSoon(from: nsView, context: context)
    }

    /// Builds the command bar for a measured title bar height. The height can only
    /// be read once the window exists, so it flows in from the coordinator rather
    /// than being baked in here; the bar uses it to size itself to the title bar
    /// and center its icons on the traffic-light row.
    private func makeCommandBar(titleBarHeight: CGFloat?) -> AstraLeadingCommandBar {
        AstraLeadingCommandBar(
            isSearchActive: $isSearchActive,
            sidebarCommands: sidebarCommands,
            isSidebarToggleHovered: $isSidebarToggleHovered,
            isSidebarHidden: isSidebarHidden,
            titleBarHeight: titleBarHeight
        )
    }

    private func configureSoon(from view: NSView, context: Context) {
        let makeBar = makeCommandBar
        let isSearchActive = isSearchActive
        let isSidebarHidden = isSidebarHidden
        let coordinator = context.coordinator
        // Capture view/coordinator weakly: if the representable is torn down (or
        // the window closes) before these blocks run, bail out instead of keeping
        // them alive or re-installing the accessory after teardown.
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, let window = view.window else { return }
            Self.configure(window)
            coordinator.installLeadingCommands(
                in: window,
                makeBar: makeBar,
                isSearchActive: isSearchActive,
                isSidebarHidden: isSidebarHidden
            )

            // SwiftUI can attach the toolbar after the representable first appears.
            // Reuse the coordinator's current builder (pass none) so this delayed
            // retry can't overwrite a newer one captured by a later update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view, weak coordinator] in
                guard let view, let coordinator, let window = view.window else { return }
                Self.configure(window)
                coordinator.installLeadingCommands(in: window)
            }
        }
    }

    private static func configure(_ window: NSWindow) {
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        // Suppress the "ASTRA" title text above the content without
        // hiding the title region itself — `titleVisibility = .hidden`
        // also collapsed the toolbar layout, pushing `.primaryAction`
        // items off the trailing edge. Setting title to empty keeps the
        // layout intact while removing the visible breadcrumb.
        window.title = ""

        // Extend content behind toolbar (Finder/Mail pattern); astraHiddenToolbarBackground() covers full-screen.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true

        // Collapse title bar + toolbar into a single row so there's no empty strip above the toolbar items.
        window.toolbarStyle = .unified
    }

    /// Owns the leading titlebar accessory and keeps its hosted command bar sized
    /// to the title bar, so the icons stay centered on the traffic lights as the
    /// title bar height changes (e.g. entering/exiting full screen). Reinstalls on
    /// a new window if the view is reparented (window tabbing/untabbing).
    @MainActor
    final class Coordinator {
        private var hostingView: FullScreenSafeHostingView<AstraLeadingCommandBar>?
        private var accessory: NSTitlebarAccessoryViewController?
        private weak var hostedWindow: NSWindow?
        private var makeBar: ((CGFloat?) -> AstraLeadingCommandBar)?
        private var lastCommandBarState: WindowChromeCommandBarState?
        private var observers: [NSObjectProtocol] = []

        func installLeadingCommands(
            in window: NSWindow,
            makeBar: ((CGFloat?) -> AstraLeadingCommandBar)? = nil,
            isSearchActive: Bool? = nil,
            isSidebarHidden: Bool? = nil
        ) {
            // Adopt a builder only when a fresh one is supplied. The delayed retry
            // (and the full-screen observer) pass nil and reuse the stored builder,
            // so a block scheduled by an earlier SwiftUI update can't clobber a
            // newer builder — and its stale binding values — over it.
            if let makeBar { self.makeBar = makeBar }
            guard let builder = self.makeBar else { return }
            guard let state = commandBarState(
                for: window,
                isSearchActive: isSearchActive,
                isSidebarHidden: isSidebarHidden
            ) else { return }

            // Already installed in this same window → refresh only when visible
            // command state changes. Hover-only state changes must not replace the
            // hosted SwiftUI root mid-click.
            if hostingView != nil, hostedWindow === window {
                refreshBarIfNeeded(state: state)
                return
            }

            // The view was reparented into a different NSWindow (e.g. window
            // tabbing / "Move Tab to New Window") or the old window went away.
            // Detach the stale accessory + observers before reinstalling, so the
            // new window gets the controls and no orphan is left behind.
            if hostingView != nil {
                teardown()
            }

            self.hostedWindow = window
            // FullScreenSafe: a plain NSHostingView here crashes the app when
            // SwiftUI invalidates constraints during the enter-full-screen
            // display cycle (see FullScreenSafeHostingView).
            let host = FullScreenSafeHostingView(rootView: builder(state.titleBarHeight))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)

            let controller = NSTitlebarAccessoryViewController()
            controller.layoutAttribute = .leading
            controller.view = host
            window.addTitlebarAccessoryViewController(controller)
            hostingView = host
            accessory = controller

            observeTitleBarChanges(of: window)
            refreshBar(state: state)
        }

        /// Removes the accessory + title-bar observers from the currently hosted
        /// window so the controls can be reinstalled on a new one (window
        /// tabbing/untabbing). No-op for the accessory if its window is already
        /// gone — AppKit drops the accessory when the window deallocates.
        private func teardown() {
            if let accessory, let window = hostedWindow,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            hostingView = nil
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        /// Rebuilds the bar at the current measured title bar height and resizes
        /// the host to match, so its content centers on the traffic-light row.
        /// Runs on every SwiftUI update and whenever the title bar resizes.
        private func refreshBarIfNeeded(state: WindowChromeCommandBarState) {
            guard WindowChromeCommandBarRefreshPolicy.shouldRefresh(
                previous: lastCommandBarState,
                next: state
            ) else {
                return
            }
            refreshBar(state: state)
        }

        private func refreshBarForTitleBarChange() {
            guard let window = hostedWindow, let lastCommandBarState else { return }
            guard let state = commandBarState(
                for: window,
                isSearchActive: lastCommandBarState.isSearchActive,
                isSidebarHidden: lastCommandBarState.isSidebarHidden
            ) else { return }
            refreshBarIfNeeded(state: state)
        }

        private func refreshBar(state: WindowChromeCommandBarState) {
            guard let host = hostingView, let makeBar else { return }
            host.rootView = makeBar(state.titleBarHeight)
            // Force the layout pass before reading fittingSize, so the size
            // reflects the just-assigned root view rather than a cached one.
            host.performSafeLayoutSubtreeIfNeeded()
            // Sub-point size changes aren't visible but do trigger a full
            // toolbar relayout, which can ping-pong with the measurement above.
            let fitting = host.fittingSize
            if abs(host.frame.width - fitting.width) >= 0.5 || abs(host.frame.height - fitting.height) >= 0.5 {
                host.frame.size = fitting
            }
            lastCommandBarState = state
        }

        private func commandBarState(
            for window: NSWindow,
            isSearchActive: Bool?,
            isSidebarHidden: Bool?
        ) -> WindowChromeCommandBarState? {
            let searchActive = isSearchActive ?? lastCommandBarState?.isSearchActive
            let sidebarHidden = isSidebarHidden ?? lastCommandBarState?.isSidebarHidden
            guard let searchActive, let sidebarHidden else { return nil }
            return WindowChromeCommandBarState(
                isSearchActive: searchActive,
                isSidebarHidden: sidebarHidden,
                titleBarHeight: titleBarHeight(of: window)
            )
        }

        /// Height of the title bar band the traffic lights are vertically centered
        /// in: the window's total height minus its laid-out content area. `nil`
        /// until the window is measurable (`> 0`), so the bar falls back to its
        /// intrinsic height and re-centers once the measurement is available.
        /// Rounded to whole points: mid-layout sub-point flutter would otherwise
        /// count as a state change and rebuild the bar every cycle, visibly
        /// shifting the rest of the toolbar back and forth.
        private func titleBarHeight(of window: NSWindow) -> CGFloat? {
            let height = (window.frame.height - window.contentLayoutRect.height).rounded()
            return height > 0 ? height : nil
        }

        /// The title bar height only changes when the window enters or leaves full
        /// screen (plain resizes don't move it); re-center the bar when it does.
        private func observeTitleBarChanges(of window: NSWindow) {
            let center = NotificationCenter.default
            let names: [NSNotification.Name] = [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in names {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // Hop onto the main actor explicitly instead of asserting the
                    // delivery context, so this can't trap if the notification is
                    // ever delivered off the main-actor executor.
                    Task { @MainActor in self?.refreshBarForTitleBarChange() }
                }
                observers.append(token)
            }
        }

        deinit {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            // Detach the accessory too, so a recreated representable can't leave a
            // duplicate or orphaned accessory on the window. Hop to the main actor
            // for the AppKit call, capturing the values rather than the
            // deallocating `self`.
            guard let accessory, let window = hostedWindow else { return }
            Task { @MainActor in
                if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
            }
        }
    }
}

extension View {
    func astraWindowChrome(
        isSearchActive: Binding<Bool>,
        sidebarCommands: SidebarTitlebarCommandBridge,
        isSidebarToggleHovered: Binding<Bool>,
        isSidebarHidden: Bool
    ) -> some View {
        background {
            WindowChromeConfigurator(
                isSearchActive: isSearchActive,
                sidebarCommands: sidebarCommands,
                isSidebarToggleHovered: isSidebarToggleHovered,
                isSidebarHidden: isSidebarHidden
            )
            .frame(width: 0, height: 0)
        }
    }

    // Extracted: inlining this on ContentView's body chain exceeded the type-checker inference budget.
    func astraHiddenToolbarBackground() -> some View {
        toolbarBackground(.hidden, for: .windowToolbar)
    }
}
