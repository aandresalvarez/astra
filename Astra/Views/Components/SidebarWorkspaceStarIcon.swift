import SwiftUI

/// One presentation contract for workspace-star affordances in the sidebar.
/// The section filter and per-workspace status have different semantics, but
/// they share a trailing column and must therefore share optical geometry.
enum SidebarWorkspaceStarPresentation {
    enum Role: Equatable {
        case filter(isEnabled: Bool)
        case workspaceStatus
    }

    struct Style: Equatable {
        let symbolName: String
        let isActive: Bool
        let showsBackground: Bool
    }

    static let glyphSize: CGFloat = 13
    static let frameSize: CGFloat = 22
    static let cornerRadius: CGFloat = 6
    static let activeBackgroundOpacity = 0.10

    static func style(for role: Role, isHovered: Bool = false) -> Style {
        switch role {
        case .filter(let isEnabled):
            return Style(
                symbolName: isEnabled ? "star.fill" : "star",
                isActive: isEnabled,
                showsBackground: isEnabled || isHovered
            )
        case .workspaceStatus:
            return Style(
                symbolName: "star.fill",
                isActive: true,
                showsBackground: false
            )
        }
    }
}

struct SidebarWorkspaceStarIcon: View {
    let role: SidebarWorkspaceStarPresentation.Role
    var isHovered = false

    var body: some View {
        let style = SidebarWorkspaceStarPresentation.style(for: role, isHovered: isHovered)

        Image(systemName: style.symbolName)
            .font(Stanford.ui(SidebarWorkspaceStarPresentation.glyphSize, weight: .medium))
            .foregroundStyle(style.isActive ? Stanford.lagunita : .secondary)
            .frame(
                width: SidebarWorkspaceStarPresentation.frameSize,
                height: SidebarWorkspaceStarPresentation.frameSize
            )
            .background(
                RoundedRectangle(cornerRadius: SidebarWorkspaceStarPresentation.cornerRadius)
                    .fill(
                        Stanford.lagunita.opacity(
                            style.showsBackground
                                ? SidebarWorkspaceStarPresentation.activeBackgroundOpacity
                                : 0
                        )
                    )
            )
            .contentShape(Rectangle())
    }
}
