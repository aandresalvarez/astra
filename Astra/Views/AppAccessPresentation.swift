import CoreGraphics
import SwiftUI

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
    // Usage, updates), and a gear names that; ellipsis-in-a-circle promised only
    // "more…" and was the vaguest glyph on the rail.
    static let footerIconSystemName = "gearshape"
    static let footerRestFillOpacity = 0.0
    static let footerHoverFillOpacity = 0.045
    static let footerOpenFillOpacity = 0.055
    static let drawerFooterGap: CGFloat = 6
    static let drawerPadding: CGFloat = 6
    static let drawerRowHeight: CGFloat = 36
    static let updateCheckRowHeight: CGFloat = 50
    static let drawerRowSpacing: CGFloat = 2
    static let manualUpdateCheckRowCount = 1

    static func drawerRowCount(destinationCount: Int) -> Int {
        destinationCount + manualUpdateCheckRowCount + 1
    }

    static func drawerHeight(rowCount: Int) -> CGFloat {
        let rows = max(rowCount, 0)
        let standardRows = max(rows - manualUpdateCheckRowCount, 0)
        let spacingCount = max(rows - 1, 0)
        return CGFloat(standardRows) * drawerRowHeight
            + (rows > 0 ? updateCheckRowHeight : 0)
            + CGFloat(spacingCount) * drawerRowSpacing
            + drawerPadding * 2
    }

    static func drawerVerticalOffset(rowCount: Int) -> CGFloat {
        drawerHeight(rowCount: rowCount) + drawerFooterGap
    }
}

struct AppAccessUpdateCheckPresentation: Equatable {
    enum IndicatorTone: Equatable {
        case standard
        case accent
        case success
        case warning
        case disabled
    }

    let title: String
    let detail: String
    let systemImageName: String
    let indicatorTone: IndicatorTone
    let showsProgress: Bool
    let isEnabled: Bool

    static func make(
        status: AppUpdateController.Status,
        canCheckForUpdates: Bool,
        appDisplayName: String
    ) -> AppAccessUpdateCheckPresentation {
        let title = "Check for Updates…"

        switch status {
        case .disabled(let reason):
            return AppAccessUpdateCheckPresentation(
                title: "Updates",
                detail: reason,
                systemImageName: "arrow.triangle.2.circlepath",
                indicatorTone: .disabled,
                showsProgress: false,
                isEnabled: false
            )
        case .idle:
            return AppAccessUpdateCheckPresentation(
                title: title,
                detail: canCheckForUpdates
                    ? "Checks automatically in the background."
                    : "Preparing the update service…",
                systemImageName: "arrow.triangle.2.circlepath",
                indicatorTone: .standard,
                showsProgress: false,
                isEnabled: canCheckForUpdates
            )
        case .checking:
            return AppAccessUpdateCheckPresentation(
                title: title,
                detail: "Checking the signed release feed…",
                systemImageName: "arrow.triangle.2.circlepath",
                indicatorTone: .accent,
                showsProgress: true,
                isEnabled: false
            )
        case .notAvailable:
            return AppAccessUpdateCheckPresentation(
                title: title,
                detail: "\(appDisplayName) is up to date.",
                systemImageName: "checkmark.circle.fill",
                indicatorTone: .success,
                showsProgress: false,
                isEnabled: canCheckForUpdates
            )
        case .available(let version):
            return AppAccessUpdateCheckPresentation(
                title: title,
                detail: "\(appDisplayName) \(version) is available.",
                systemImageName: "arrow.down.circle.fill",
                indicatorTone: .accent,
                showsProgress: false,
                isEnabled: canCheckForUpdates
            )
        case .blocked(let reason), .failed(let reason):
            return AppAccessUpdateCheckPresentation(
                title: title,
                detail: reason,
                systemImageName: "exclamationmark.circle.fill",
                indicatorTone: .warning,
                showsProgress: false,
                isEnabled: canCheckForUpdates
            )
        }
    }
}

struct AppearanceTogglePresentation: Equatable {
    let title: String
    let systemImageName: String
    let helpText: String
    let target: AppearancePreference

    static func make(currentColorScheme: ColorScheme) -> AppearanceTogglePresentation {
        let target = AppearancePreference.toggled(from: currentColorScheme)
        return AppearanceTogglePresentation(
            title: "\(target.label) mode",
            systemImageName: target.symbolName,
            helpText: "Switch to \(target.label.lowercased()) mode",
            target: target
        )
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
