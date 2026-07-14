import CoreGraphics

/// Stable sizing for the task transcript column.
///
/// The transcript intentionally stops growing once it reaches a readable
/// width. Keeping that cap stable across wide-window shelf toggles prevents
/// every retained Markdown message from receiving a new text constraint when
/// a docked shelf opens or closes.
enum TaskChatLayoutGeometry {
    static let readableColumnMaxWidth: CGFloat = 900
    static let wideContainerMaxWidth: CGFloat = readableColumnMaxWidth + 64

    static func horizontalPadding(for viewportWidth: CGFloat) -> CGFloat {
        if viewportWidth < 520 { return 12 }
        if viewportWidth < 760 { return 16 }
        return 32
    }

    static func columnMaxWidth(for viewportWidth: CGFloat) -> CGFloat {
        let horizontalPadding = horizontalPadding(for: viewportWidth) * 2
        let usableWidth = max(240, viewportWidth - horizontalPadding)
        return min(usableWidth, readableColumnMaxWidth)
    }
}
