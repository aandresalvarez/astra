import AppKit
import SwiftUI

/// Small AppKit bridge for window chrome that SwiftUI does not fully expose on macOS 14.
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureSoon(from: nsView)
    }

    private func configureSoon(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.configure(window)

            // SwiftUI can attach the toolbar after the representable first appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
                guard let window else { return }
                Self.configure(window)
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
    }
}

extension View {
    func astraWindowChrome() -> some View {
        background {
            WindowChromeConfigurator()
                .frame(width: 0, height: 0)
        }
    }
}
