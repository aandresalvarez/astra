import SwiftUI

/// Overflow controls blend into the row until the control itself is active.
enum SidebarOverflowPresentation {
    static let controlSize: CGFloat = 24
    static let cornerRadius: CGFloat = 6

    static func backgroundOpacity(isHovered: Bool, isPressed: Bool, isFocused: Bool) -> Double {
        if isPressed { return Stanford.fillPressed }
        return isHovered || isFocused ? Stanford.fillSoft : 0
    }
}

/// Shared by task and workspace menus; row hover reveals the menu, while
/// button hover, press, and keyboard focus provide local interaction feedback.
struct SidebarOverflowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarOverflowButtonBody(configuration: configuration)
    }
}

private struct SidebarOverflowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: SidebarOverflowPresentation.cornerRadius,
            style: .continuous
        )
        let isActive = isEnabled && (isHovered || isFocused || configuration.isPressed)
        configuration.label
            .foregroundStyle(isActive ? Stanford.lagunita : Stanford.textSecondary)
            .frame(width: SidebarOverflowPresentation.controlSize, height: SidebarOverflowPresentation.controlSize)
            .background(shape.fill(Color.primary.opacity(
                SidebarOverflowPresentation.backgroundOpacity(
                    isHovered: isEnabled && isHovered,
                    isPressed: isEnabled && configuration.isPressed,
                    isFocused: isEnabled && isFocused
                )
            )))
            .overlay(shape.stroke(isFocused ? Stanford.focusRing : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovered)
    }
}
