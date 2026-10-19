import AppKit
import SwiftUI

/// Only presentation state: hover never writes workspace or scene selection.
struct WorkspaceHoverState: Equatable {
    var rowHovered = false
    var cardHovered = false
    var isSuppressed = false

    var wantsCard: Bool { (rowHovered || cardHovered) && !isSuppressed }

    mutating func updateRow(_ hovering: Bool) {
        rowHovered = hovering
        if !hovering { isSuppressed = false }
    }

    mutating func dismiss() {
        cardHovered = false
        isSuppressed = rowHovered
    }

    static let openDelay: Duration = .milliseconds(400)
    static let closeDelay: Duration = .milliseconds(200)
}

extension View {
    func workspaceHoverCard<Card: View>(isHovered: Bool,
                                       @ViewBuilder card: @escaping (@escaping () -> Void) -> Card) -> some View {
        modifier(WorkspaceHoverModifier(isHovered: isHovered, card: card))
    }
}

private struct WorkspaceHoverModifier<Card: View>: ViewModifier {
    let isHovered: Bool
    let card: (@escaping () -> Void) -> Card
    @State private var explicitRequest = 0
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                WorkspaceHoverAnchor(isHovered: isHovered, explicitRequest: explicitRequest) { dismiss in
                    card(dismiss).environment(\.colorScheme, colorScheme)
                }
                .accessibilityHidden(true)
            }
            .accessibilityAction(named: Text("Workspace options")) { explicitRequest += 1 }
            .onKeyPress(.downArrow, phases: .down) { event in
                guard event.modifiers.contains(.option) else { return .ignored }
                explicitRequest += 1
                return .handled
            }
    }
}

/// A nonactivating child panel keeps hover from stealing keyboard focus or
/// intercepting the row's disclosure click. Native popover dismissal can consume
/// that first click; the local monitor below passes mouse events through.
private struct WorkspaceHoverAnchor<Card: View>: NSViewRepresentable {
    let isHovered: Bool
    let explicitRequest: Int
    let card: (@escaping () -> Void) -> Card

    func makeNSView(context: Context) -> NSView { AnchorView() }
    func makeCoordinator() -> WorkspaceHoverPresenter { WorkspaceHoverPresenter() }

    func updateNSView(_ view: NSView, context: Context) {
        let presenter = context.coordinator
        presenter.anchor = view
        presenter.content = AnyView(card { [weak presenter] in presenter?.dismiss() }
            .onHover { [weak presenter] in presenter?.updateCardHover($0) })
        presenter.update(rowHovered: isHovered, explicitRequest: explicitRequest)
    }

    static func dismantleNSView(_ view: NSView, coordinator: WorkspaceHoverPresenter) {
        coordinator.dismiss()
        coordinator.anchor = nil
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
final class WorkspaceHoverPresenter {
    weak var anchor: NSView?
    var content = AnyView(EmptyView()) {
        didSet { host?.rootView = content }
    }
    private(set) var state = WorkspaceHoverState()
    private(set) var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var pending: Task<Void, Never>?
    private var lastExplicitRequest = 0
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func update(rowHovered: Bool, explicitRequest: Int) {
        let changed = rowHovered != state.rowHovered
        state.updateRow(rowHovered)
        if explicitRequest != lastExplicitRequest {
            lastExplicitRequest = explicitRequest
            state.isSuppressed = false
            show(keyboard: true)
        } else if changed {
            reconcile()
        }
    }

    func updateCardHover(_ hovering: Bool) {
        state.cardHovered = hovering
        reconcile()
    }

    private func reconcile() {
        pending?.cancel()
        if state.wantsCard {
            guard panel == nil else { return }
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: WorkspaceHoverState.openDelay) } catch { return }
                guard let self, self.state.wantsCard else { return }
                self.show()
            }
        } else {
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: WorkspaceHoverState.closeDelay) } catch { return }
                guard let self, !self.state.wantsCard else { return }
                self.dismiss()
            }
        }
    }

    func show(keyboard: Bool = false) {
        pending?.cancel()
        if let panel {
            if keyboard { panel.makeKey() }
            return
        }
        guard let anchor, let parent = anchor.window,
              parent.isVisible, NSApp.isActive else { return }
        let host = WorkspaceHoverHostView(rootView: content)
        let size = host.fittingSize
        let row = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? row
        let x = row.maxX + size.width <= screen.maxX ? row.maxX + 4 : row.minX - size.width - 4
        let origin = NSPoint(x: max(screen.minX, min(x, screen.maxX - size.width)),
                             y: max(screen.minY, min(row.maxY - size.height, screen.maxY - size.height)))
        let panel = WorkspaceOptionsPanel(contentRect: NSRect(origin: origin, size: size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.contentView = host
        self.panel = panel
        self.host = host
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if keyboard { panel.makeKey() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.dismiss()
                return nil // Escape belongs to the card, not the editor beneath it.
            }
            if event.type == .scrollWheel
                || ((event.type == .leftMouseDown || event.type == .rightMouseDown)
                    && !panel.frame.contains(NSEvent.mouseLocation)) {
                self.dismiss()
            }
            return event
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        state.dismiss()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        host = nil
    }
}

private final class WorkspaceOptionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hover is passive, but the first deliberate click must activate an action.
private final class WorkspaceHoverHostView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
