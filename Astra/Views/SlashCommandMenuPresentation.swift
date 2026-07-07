import SwiftUI

enum SlashCommandMenuPresentation {
    static let rowHeight: CGFloat = 46
    static let iconFrame: CGFloat = 28
    static let iconSize: CGFloat = 15
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 6
    static let menuVerticalPadding: CGFloat = 4
    static let commandFontSize: CGFloat = 14
    static let titleFontSize: CGFloat = 12
    static let descriptionFontSize: CGFloat = 11
    static let descriptionLineLimit = 1
    static let maxWidth: CGFloat = 380
    static let rowCornerRadius: CGFloat = 7
    static let menuCornerRadius: CGFloat = 10
    static let returnIconSize: CGFloat = 11
    static let dividerLeadingPadding: CGFloat = 50
    static let dividerTrailingPadding: CGFloat = 12
    static let dividerOpacity = 0.12
    static let selectedBackgroundOpacity = 0.075
    static let borderOpacity = 0.10
    static let shadowRadius: CGFloat = 8
    static let shadowOpacity = 0.08
    static let shadowYOffset: CGFloat = -2
    static let usesIconColumnDividers = true
    static let usesFullWidthDividers = false

    static func menuHeight(rowCount: Int) -> CGFloat {
        CGFloat(rowCount) * rowHeight + menuVerticalPadding * 2
    }
}
