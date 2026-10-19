import AppKit

/// Owns the transient card's window notifications, independently of its content.
@MainActor
final class WorkspaceHoverWindowLifetime {
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    // Read-only access lets callers await a scheduled check, including cancellation.
    private(set) var pendingFocusCheck: Task<Void, Never>?

    init(parent: NSWindow, panel: NSWindow, notifications: NotificationCenter = .default,
         keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         dismiss: @escaping @MainActor () -> Void) {
        self.notifications = notifications
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(notifications.addObserver(forName: name, object: parent, queue: .main) { _ in
                MainActor.assumeIsolated { dismiss() }
            })
        }
        observers.append(notifications.addObserver(forName: NSApplication.didResignActiveNotification,
                                                   object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dismiss() }
        })
        observers.append(notifications.addObserver(forName: NSWindow.didResignKeyNotification,
                                                   object: nil, queue: .main) { [weak self, weak parent, weak panel] notification in
            MainActor.assumeIsolated {
                guard let parent, let panel, let window = notification.object as? NSWindow,
                      window === parent || window === panel else { return }
                self?.checkFocusAfterTransition(parent: parent, panel: panel, keyWindow: keyWindow, dismiss: dismiss)
            }
        })
    }

    private func checkFocusAfterTransition(parent: NSWindow, panel: NSWindow,
                                          keyWindow: @escaping @MainActor () -> NSWindow?,
                                          dismiss: @escaping @MainActor () -> Void) {
        pendingFocusCheck?.cancel()
        pendingFocusCheck = Task { @MainActor [weak self, weak parent, weak panel] in
            // didResignKey arrives before AppKit assigns the new key window.
            // Wait for that transition so keyboard entry into the card survives.
            await Task.yield()
            guard !Task.isCancelled, let self, let parent, let panel else { return }
            self.pendingFocusCheck = nil
            let current = keyWindow()
            if current !== parent && current !== panel { dismiss() }
        }
    }

    func invalidate() {
        pendingFocusCheck?.cancel()
        pendingFocusCheck = nil
        observers.forEach(notifications.removeObserver)
        observers = []
    }
}
