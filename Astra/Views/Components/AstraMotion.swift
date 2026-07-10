import SwiftUI

enum AstraMotion {
    static func toolbarCommand(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0.0)
    }

    static func rightPanel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0.0)
    }

    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16, extraBounce: 0.0)
    }

    /// Workspace drawer open/close. A touch slower than plain disclosure so
    /// the accordion's close+open reads as one drawer handing off to another
    /// rather than two unrelated snaps.
    static func accordion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.20, extraBounce: 0.0)
    }
}
