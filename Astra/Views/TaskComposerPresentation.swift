import CoreGraphics

enum TaskComposerPresentation {
    static let usesCompactInputSpacing = true
    static let usesForcedExpandedInputHeight = false
    static let decisionRowUsesNestedChrome = false
    static let decisionRowUsesNestedStroke = false
    static let decisionDetailsUsePopover = true
    static let decisionActionsUseOverflowMenu = false
    static let decisionUtilitiesStayLeftAligned = true
    static let decisionSummaryVisibleInCompactRow = false
    static let decisionDockHorizontalPadding: CGFloat = 14
    static let decisionDockTopPadding: CGFloat = 8
    static let decisionDockBottomPadding: CGFloat = 6
    static let decisionRowHorizontalPadding: CGFloat = 12
    static let decisionRowVerticalPadding: CGFloat = 7
    static let decisionRowSpacing: CGFloat = 12
    static let decisionAccentWidth: CGFloat = 3
    static let decisionAccentVerticalInset: CGFloat = 5
    static let decisionIconFrame: CGFloat = 16
    static let decisionIconFontSize: CGFloat = 12
    static let decisionTitleFontSize: CGFloat = 13
    static let decisionDetailFontSize: CGFloat = 12
    static let decisionDetailsWidth: CGFloat = 540
    static let decisionDetailsMaxHeight: CGFloat = 460
    static let inputHorizontalPadding: CGFloat = 14
    static let inputTopPadding: CGFloat = 12
    static let inputTopPaddingWithAttachments: CGFloat = 8
    static let inputBottomPadding: CGFloat = 9
}
