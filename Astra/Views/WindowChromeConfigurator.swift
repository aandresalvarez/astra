import AppKit
import SwiftUI

/// Small AppKit bridge for window chrome that SwiftUI does not fully expose on macOS 14.
///
/// Besides the transparent/unified titlebar tweaks, this installs a leading
/// *titlebar accessory* hosting `AstraLeadingCommandBar`. AppKit pins that
/// accessory right after the traffic lights in every layout, which SwiftUI
/// toolbar placement can't do inside a `NavigationSplitView` (where `.navigation`
/// items slide to the detail column's leading edge when the sidebar is open).
struct WindowChromeConfigurator: NSViewRepresentable {
    @Binding var isSearchActive: Bool
    @Binding var isSidebarToggleHovered: Bool
    var isSidebarHidden: Bool
    var onToggleSidebar: () -> Void

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
            isSidebarToggleHovered: $isSidebarToggleHovered,
            isSidebarHidden: isSidebarHidden,
            onToggleSidebar: onToggleSidebar,
            titleBarHeight: titleBarHeight
        )
    }

    private func configureSoon(from view: NSView, context: Context) {
        let makeBar = makeCommandBar
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.configure(window)
            coordinator.installLeadingCommands(in: window, makeBar: makeBar)

            // SwiftUI can attach the toolbar after the representable first appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
                guard let window else { return }
                Self.configure(window)
                coordinator.installLeadingCommands(in: window, makeBar: makeBar)
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

    /// Holds the titlebar accessory + its hosting view across SwiftUI updates so
    /// the accessory is installed exactly once and only its root view refreshes.
    /// Owns the leading titlebar accessory and keeps its hosted command bar sized
    /// to the title bar, so the icons stay centered on the traffic lights as the
    /// title bar height changes (e.g. entering/exiting full screen).
    @MainActor
    final class Coordinator {
        private var hostingView: NSHostingView<AstraLeadingCommandBar>?
        private var accessory: NSTitlebarAccessoryViewController?
        private weak var hostedWindow: NSWindow?
        private var makeBar: ((CGFloat?) -> AstraLeadingCommandBar)?
        private var observers: [NSObjectProtocol] = []

        func installLeadingCommands(
            in window: NSWindow,
            makeBar: @escaping (CGFloat?) -> AstraLeadingCommandBar
        ) {
            self.makeBar = makeBar

            // Already installed in this same window → just refresh the bar.
            if hostingView != nil, hostedWindow === window {
                refreshBar()
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
            let host = NSHostingView(rootView: makeBar(titleBarHeight(of: window)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)

            let controller = NSTitlebarAccessoryViewController()
            controller.layoutAttribute = .leading
            controller.view = host
            window.addTitlebarAccessoryViewController(controller)
            hostingView = host
            accessory = controller

            observeTitleBarChanges(of: window)
            refreshBar()
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
        private func refreshBar() {
            guard let host = hostingView, let window = hostedWindow, let makeBar else { return }
            host.rootView = makeBar(titleBarHeight(of: window))
            host.frame.size = host.fittingSize
        }

        /// Height of the title bar band the traffic lights are vertically centered
        /// in: the window's total height minus its laid-out content area. `nil`
        /// until the window is measurable (`> 0`), so the bar falls back to its
        /// intrinsic height and re-centers once the measurement is available.
        private func titleBarHeight(of window: NSWindow) -> CGFloat? {
            let height = window.frame.height - window.contentLayoutRect.height
            return height > 0 ? height : nil
        }

        /// The title bar height changes when the window enters/exits full screen
        /// (and, defensively, on any resize); re-center the bar when it does.
        private func observeTitleBarChanges(of window: NSWindow) {
            let center = NotificationCenter.default
            let names: [NSNotification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in names {
                // Delivered on `.main` (the main actor); assert that so the
                // @MainActor `refreshBar()` call is statically sound.
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshBar() }
                }
                observers.append(token)
            }
        }

        deinit {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
        }
    }
}

extension View {
    func astraWindowChrome(
        isSearchActive: Binding<Bool>,
        isSidebarToggleHovered: Binding<Bool>,
        isSidebarHidden: Bool,
        onToggleSidebar: @escaping () -> Void
    ) -> some View {
        background {
            WindowChromeConfigurator(
                isSearchActive: isSearchActive,
                isSidebarToggleHovered: isSidebarToggleHovered,
                isSidebarHidden: isSidebarHidden,
                onToggleSidebar: onToggleSidebar
            )
            .frame(width: 0, height: 0)
        }
    }

    // Extracted: inlining this on ContentView's body chain exceeded the type-checker inference budget.
    func astraHiddenToolbarBackground() -> some View {
        toolbarBackground(.hidden, for: .windowToolbar)
    }
}
