import AppKit
import Foundation

/// Supplies the missing end callback for SwiftUI drag sources on macOS.
/// A stable reference held in `@State` owns the timer without making each
/// sidebar drag feature duplicate cancellation and teardown behavior.
@MainActor
final class SidebarDragReleaseWatchdog {
    private var timer: Timer?

    func start(onRelease: @escaping @MainActor () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard Self.primaryButtonIsReleased(pressedMouseButtons: NSEvent.pressedMouseButtons) else {
                    return
                }
                self?.stop()
                onRelease()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated static func primaryButtonIsReleased(pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons & 0x1 == 0
    }
}
