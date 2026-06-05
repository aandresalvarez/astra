import AppKit
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
    let onCollapse: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(minimumExpandedWidth: minimumExpandedWidth, onCollapse: onCollapse)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.minimumExpandedWidth = minimumExpandedWidth
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
        var onCollapse: () -> Void

        private weak var observedSplitView: NSSplitView?
        private weak var observedSidebarSubview: NSView?
        private var observations: [NSObjectProtocol] = []
        private var isCollapsing = false

        init(minimumExpandedWidth: CGFloat, onCollapse: @escaping () -> Void) {
            self.minimumExpandedWidth = minimumExpandedWidth
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

            if let index = splitView.subviews.firstIndex(where: { $0 === sidebarSubview }) {
                splitView.setHoldingPriority(.defaultHigh, forSubviewAt: index)
            }
        }

        private func clearObservations() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            observedSplitView = nil
            observedSidebarSubview = nil
        }

        private func enforceReadableSidebarWidth() {
            guard let sidebarWidth = observedSidebarSubview?.frame.width else { return }
            guard sidebarWidth.isFinite else { return }
            guard SidebarColumnLayout.shouldCollapseVisibleSplitWidth(
                sidebarWidth,
                minimumExpandedWidth: minimumExpandedWidth
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
