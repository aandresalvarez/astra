import CoreGraphics
import Foundation

enum AppWindowIDs {
    static let logs = "astra-logs"
    static let usage = "astra-usage"
}

enum AppAccessMenuPresentation {
    static let footerMenuTitle = "ASTRA"
    static let footerMinimumHeight: CGFloat = 44
    static let footerIconSystemName = "ellipsis.circle"
    static let footerRestFillOpacity = 0.0
    static let footerHoverFillOpacity = 0.045
    static let footerOpenFillOpacity = 0.055
    static let drawerFooterGap: CGFloat = 6
    static let drawerPadding: CGFloat = 6
    static let drawerRowHeight: CGFloat = 36
    static let drawerRowSpacing: CGFloat = 2

    static func drawerHeight(rowCount: Int) -> CGFloat {
        let rows = max(rowCount, 0)
        let spacingCount = max(rows - 1, 0)
        return CGFloat(rows) * drawerRowHeight
            + CGFloat(spacingCount) * drawerRowSpacing
            + drawerPadding * 2
    }

    static func drawerVerticalOffset(rowCount: Int) -> CGFloat {
        drawerHeight(rowCount: rowCount) + drawerFooterGap
    }
}

enum AppAccessDestination: String, CaseIterable, Identifiable {
    case settings
    case logs
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings:
            return "Settings"
        case .logs:
            return "Logs"
        case .usage:
            return "Usage"
        }
    }

    var systemImageName: String {
        switch self {
        case .settings:
            return "gearshape"
        case .logs:
            return "doc.text.magnifyingglass"
        case .usage:
            return "chart.bar.xaxis"
        }
    }

    var helpText: String {
        switch self {
        case .settings:
            return "Open Settings"
        case .logs:
            return "Open Logs"
        case .usage:
            return "Open Usage"
        }
    }
}
