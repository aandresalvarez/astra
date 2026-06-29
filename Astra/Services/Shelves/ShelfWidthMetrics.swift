import CoreGraphics
import Foundation

enum ShelfWidthMetrics {
    static let filesNavigatorDefaultWidth: CGFloat = 282
    static let filesResizeHandleWidth: CGFloat = 8
    static let filesMinimumPreviewWidth: CGFloat = 260
    static let filesMinReadableWidth: CGFloat =
        filesNavigatorDefaultWidth + filesResizeHandleWidth + filesMinimumPreviewWidth
    static let browserMinWidth: CGFloat = 360
}
