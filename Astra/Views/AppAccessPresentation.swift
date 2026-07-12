import CoreGraphics

enum AppWindowIDs {
    static let main = "astra-main"
    static let logs = "astra-logs"
    static let usage = "astra-usage"
}

enum AppAccessMenuPresentation {
    static let footerMenuTitle = "ASTRA"
    /// The footer owns the full-width hover surface. Keeping the previous 6pt
    /// vertical breathing room inside this height lets its fill reach the
    /// sidebar's bottom edge, where the enclosing sidebar supplies the corner.
    static let footerMinimumHeight: CGFloat = 56
    /// Preserves the former 12pt footer inset plus the button's 10pt content
    /// inset now that the button itself spans the footer.
    static let footerContentHorizontalPadding: CGFloat = 22
    // Gear, not ellipsis: the drawer holds app utilities (Settings, Logs,
    // Usage), and a gear names that; ellipsis-in-a-circle promised only
    // "more…" and was the vaguest glyph on the rail.
    static let footerIconSystemName = "gearshape"
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
