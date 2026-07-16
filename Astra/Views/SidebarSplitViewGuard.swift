import AppKit
import AstraObjCSupport
import SwiftUI

/// Watches the AppKit split-view column that hosts the SwiftUI sidebar.
///
/// SwiftUI's `navigationSplitViewColumnWidth(min:ideal:max:)` is a sizing
/// preference, not a hard guarantee while the user drags the split divider.
/// When AppKit temporarily squeezes the visible sidebar below ASTRA's readable
/// minimum, the SwiftUI sidebar can keep its own wider layout and get clipped
/// from the leading edge. This probe observes the actual split subview frame and
/// lets the owner collapse the sidebar before row margins and trailing metadata
/// degrade into a clipped strip.
struct SidebarSplitViewGuard: NSViewRepresentable {
    let minimumExpandedWidth: CGFloat
    let isRevealInProgress: Bool
    let onReadableWidth: (CGFloat) -> Void
    let onCollapse: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            minimumExpandedWidth: minimumExpandedWidth,
            isRevealInProgress: isRevealInProgress,
            onReadableWidth: onReadableWidth,
            onCollapse: onCollapse
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.minimumExpandedWidth = minimumExpandedWidth
        context.coordinator.isRevealInProgress = isRevealInProgress
        context.coordinator.onReadableWidth = onReadableWidth
        context.coordinator.onCollapse = onCollapse
        configureSoon(from: nsView, coordinator: context.coordinator)
    }

    private func configureSoon(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.configure(from: view)
        }
    }

    final class Coordinator {
        var minimumExpandedWidth: CGFloat
        var isRevealInProgress: Bool {
            didSet {
                if isRevealInProgress {
                    isAwaitingReadableRevealWidth = true
                }
            }
        }
        var onReadableWidth: (CGFloat) -> Void
        var onCollapse: () -> Void

        private weak var observedSplitView: NSSplitView?
        private weak var observedSidebarSubview: NSView?
        private var observations: [NSObjectProtocol] = []
        private var isCollapsing = false
        private var didApplyHoldingPriority = false
        private var isAwaitingReadableRevealWidth: Bool

        init(
            minimumExpandedWidth: CGFloat,
            isRevealInProgress: Bool,
            onReadableWidth: @escaping (CGFloat) -> Void,
            onCollapse: @escaping () -> Void
        ) {
            self.minimumExpandedWidth = minimumExpandedWidth
            self.isRevealInProgress = isRevealInProgress
            self.isAwaitingReadableRevealWidth = isRevealInProgress
            self.onReadableWidth = onReadableWidth
            self.onCollapse = onCollapse
        }

        deinit {
            clearObservations()
        }

        func configure(from probe: NSView) {
            guard let target = Self.findContainingSplitSubview(for: probe) else {
                clearObservations()
                return
            }

            if observedSplitView !== target.splitView || observedSidebarSubview !== target.sidebarSubview {
                installObservations(splitView: target.splitView, sidebarSubview: target.sidebarSubview)
            }

            applyHoldingPriorityIfNeeded()
            enforceReadableSidebarWidth()
        }

        private func installObservations(splitView: NSSplitView, sidebarSubview: NSView) {
            clearObservations()
            observedSplitView = splitView
            observedSidebarSubview = sidebarSubview

            splitView.postsFrameChangedNotifications = true
            sidebarSubview.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            observations = [
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: splitView,
                    queue: .main
                ) { [weak self] _ in
                    self?.enforceReadableSidebarWidth()
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: sidebarSubview,
                    queue: .main
                ) { [weak self] _ in
                    self?.enforceReadableSidebarWidth()
                }
            ]

            // Holding priority is applied separately (and retried) by
            // `applyHoldingPriorityIfNeeded`, because the AppKit call can raise
            // mid-transition right after a fresh split view is observed.
            didApplyHoldingPriority = false
        }

        /// Pins the sidebar pane's holding priority so it keeps its width as the
        /// window resizes — the resize-nicety the guard otherwise can't express.
        ///
        /// Deferred out of `installObservations` and retried each `configure`
        /// because `-[NSSplitView setHoldingPriority:forSubviewAtIndex:]` can
        /// raise an NSException when its internal pane list briefly lags
        /// `subviews` during a SwiftUI column show/hide transition (the index is
        /// valid for `subviews` yet still out of AppKit's live range). Swift
        /// can't catch that, so the call is funneled through `AstraExceptionTrap`
        /// and only marked done once it returns cleanly; a transient raise just
        /// retries on the next `configure`.
        private func applyHoldingPriorityIfNeeded() {
            guard !didApplyHoldingPriority,
                  let splitView = observedSplitView,
                  let sidebarSubview = observedSidebarSubview,
                  splitView.subviews.count >= 2,
                  let index = splitView.subviews.firstIndex(where: { $0 === sidebarSubview }) else {
                return
            }

            let raised = AstraExceptionTrap.catching {
                splitView.setHoldingPriority(.defaultHigh, forSubviewAt: index)
            }
            didApplyHoldingPriority = (raised == nil)
        }

        private func clearObservations() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            observedSplitView = nil
            observedSidebarSubview = nil
            didApplyHoldingPriority = false
        }

        private func enforceReadableSidebarWidth() {
            guard let sidebarWidth = observedSidebarSubview?.frame.width else { return }
            handleObservedSidebarWidth(sidebarWidth)
        }

        /// Keeps AppKit's delayed narrow reveal frames from being interpreted as
        /// a user collapse after the model's liveness watchdog expires. Only a
        /// real readable frame retires this guard; the model remains independently
        /// responsive to explicit user intent and its other width input.
        func handleObservedSidebarWidth(_ sidebarWidth: CGFloat) {
            guard sidebarWidth.isFinite else { return }
            if SidebarColumnLayout.shouldCompleteSidebarReveal(
                width: sidebarWidth,
                minimumExpandedWidth: minimumExpandedWidth
            ) {
                isAwaitingReadableRevealWidth = false
                onReadableWidth(sidebarWidth)
                return
            }
            guard !isAwaitingReadableRevealWidth else { return }
            guard SidebarColumnLayout.shouldCollapseVisibleSplitWidth(
                sidebarWidth,
                minimumExpandedWidth: minimumExpandedWidth,
                isRevealInProgress: isRevealInProgress
            ) else {
                return
            }
            guard !isCollapsing else { return }

            isCollapsing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onCollapse()
                self.isCollapsing = false
            }
        }

        private static func findContainingSplitSubview(for probe: NSView) -> (
            splitView: NSSplitView,
            sidebarSubview: NSView
        )? {
            var current = probe.superview
            while let view = current {
                if let splitView = view as? NSSplitView,
                   let sidebarSubview = splitView.subviews.first(where: { probe.isDescendant(of: $0) }) {
                    return (splitView, sidebarSubview)
                }
                current = view.superview
            }
            return nil
        }
    }
}
