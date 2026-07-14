import CoreGraphics
import SwiftUI

/// Responsive sizing for the task transcript column.
///
/// The task keeps the product's adaptive wide-window measure. Performance
/// comes from a stable parent proposal, grouped transcript layout, and
/// resolving task-wide policy once, not from permanently narrowing the chat.
enum TaskChatLayoutGeometry {
    static func horizontalPadding(for viewportWidth: CGFloat) -> CGFloat {
        if viewportWidth < 520 { return 12 }
        if viewportWidth < 760 { return 16 }
        return 32
    }

    static func columnMaxWidth(for viewportWidth: CGFloat) -> CGFloat {
        let horizontalPadding = horizontalPadding(for: viewportWidth) * 2
        let usableWidth = max(240, viewportWidth - horizontalPadding)
        guard usableWidth >= 860 else { return usableWidth }

        let proportionalWidth = max(900, usableWidth * 0.78)
        return min(usableWidth, proportionalWidth, 1_280)
    }

    static func visibleViewportWidth(
        proposedWidth: CGFloat,
        unobscuredWidth: CGFloat?
    ) -> CGFloat {
        max(0, min(proposedWidth, unobscuredWidth ?? proposedWidth))
    }
}

private struct TaskChatUnobscuredWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var taskChatUnobscuredWidth: CGFloat? {
        get { self[TaskChatUnobscuredWidthKey.self] }
        set { self[TaskChatUnobscuredWidthKey.self] = newValue }
    }
}

extension View {
    func taskChatContainerFrame(unobscuredWidth: CGFloat?) -> some View {
        frame(width: unobscuredWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
