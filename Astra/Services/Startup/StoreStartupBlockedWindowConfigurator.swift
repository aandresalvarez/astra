import AppKit
import SwiftUI

enum StoreStartupBlockedWindowLayout {
    static let preferredContentSize = NSSize(width: 680, height: 340)
    static let minimumContentSize = NSSize(width: 520, height: 300)
    static let maximumContentWidth: CGFloat = 640
}

/// Applies recovery-specific sizing to the main scene without constraining the
/// normal workspace window. The startup blocker is hosted by the main
/// `WindowGroup`, whose large default/restored frame is appropriate for the
/// workspace but not for a short recovery message.
struct StoreStartupBlockedWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureSoon(from: nsView, coordinator: context.coordinator)
    }

    private func configureSoon(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, let window = view.window else { return }
            coordinator.configure(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var configuredWindow: NSWindow?

        func configure(_ window: NSWindow) {
            guard configuredWindow !== window else { return }
            Self.applyRecoveryLayout(to: window)
            configuredWindow = window
        }

        static func applyRecoveryLayout(to window: NSWindow) {
            window.contentMinSize = StoreStartupBlockedWindowLayout.minimumContentSize
            window.setContentSize(StoreStartupBlockedWindowLayout.preferredContentSize)
            window.center()
        }
    }
}
