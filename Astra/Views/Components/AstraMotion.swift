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
}
