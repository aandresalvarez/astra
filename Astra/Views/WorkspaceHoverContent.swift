import SwiftUI

/// Retains the latest card builder without constructing closed hover cards.
/// The presenter owns the host; this weak reference only refreshes its content
/// while attached, and is retired when the panel closes.
@MainActor
final class WorkspaceHoverContent {
    private var builder: () -> AnyView = { AnyView(EmptyView()) }
    private weak var host: NSHostingView<AnyView>?

    func update(_ builder: @escaping () -> AnyView) {
        self.builder = builder
        if let host { host.rootView = builder() }
    }

    func attach(to host: NSHostingView<AnyView>) {
        self.host = host
        host.rootView = builder()
    }

    func detach() {
        host = nil
    }
}
