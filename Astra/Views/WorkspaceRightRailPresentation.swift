import SwiftUI

enum WorkspaceRightRailPresentation {
    /// Order while a workspace still has setup to do: setup stays directly under
    /// the repository so onboarding is not buried beneath the inventory.
    static let primarySectionOrder = [
        "Repository",
        WorkspaceSetupChecklistPresentation.sectionTitle,
        CapabilityRailSectionPresentation.sectionTitle
    ]

    /// Order once setup is complete: the capabilities the workspace actually uses
    /// rise above the now-compact configured-setup summary, so the panel leads
    /// with where the user has invested rather than with finished chores.
    static let steadyStateSectionOrder = [
        "Repository",
        CapabilityRailSectionPresentation.sectionTitle,
        WorkspaceSetupChecklistPresentation.sectionTitle
    ]

    /// The section order to render for a workspace, chosen by whether any setup
    /// item is still outstanding.
    static func sectionOrder(hasPendingSetup: Bool) -> [String] {
        hasPendingSetup ? primarySectionOrder : steadyStateSectionOrder
    }

    static let headerIconFontSize: CGFloat = 15
    static let headerIconFrame: CGFloat = 22
    static let headerTitleFontSize: CGFloat = 16
    static let headerSubtitleFontSize: CGFloat = 12

    /// Collapse verb for the rail's own expandable groups (setup, capabilities).
    /// Kept here rather than borrowing the git panel's constant so the rail and
    /// git presentation layers stay independent.
    static let hideActionTitle = "Hide"
}

enum CapabilityRailLayout {
    static let compactContentPadding: CGFloat = 16
    static let regularContentPadding: CGFloat = 14
    static let compactPanelSpacing: CGFloat = 14
    static let regularPanelSpacing: CGFloat = 12
    static let compactSectionPadding: CGFloat = 18
    static let regularSectionPadding: CGFloat = 16
    static let compactSectionContentSpacing: CGFloat = 10
    static let regularSectionContentSpacing: CGFloat = 8
    static let compactGroupSpacing: CGFloat = 14
    static let regularGroupSpacing: CGFloat = 12
    static let sectionTitleFontSize: CGFloat = 15
    static let sectionActionFontSize: CGFloat = 13
    static let sectionActionSubtitleFontSize: CGFloat = 10
    static let groupHeadingFontSize: CGFloat = 12
    static let leadingIconFontSize: CGFloat = 16
    static let leadingIconFrame: CGFloat = 30
    static let leadingIconSpacing: CGFloat = 12
    static let rowTitleFontSize: CGFloat = 14
    static let rowSubtitleFontSize: CGFloat = 12
    static let rowActionFontSize: CGFloat = 12
    static let rowChevronFontSize: CGFloat = 11
    static let compactRowMinHeight: CGFloat = 60
    static let regularRowMinHeight: CGFloat = 56
    static let summaryRowMinHeight: CGFloat = 58
    static let setupRowMinHeight: CGFloat = 56
    static let usesNestedGroupChrome = false
    static let titleLineHeight: CGFloat = 18
    static let subtitleLineHeight: CGFloat = 15
    static let titleSubtitleSpacing: CGFloat = 3
    static let textVerticalBreathingRoom: CGFloat = 12

    static var minimumTwoLineRowHeight: CGFloat {
        titleLineHeight + subtitleLineHeight + titleSubtitleSpacing + textVerticalBreathingRoom
    }

    static func rowMinHeight(isCompact: Bool) -> CGFloat {
        isCompact ? compactRowMinHeight : regularRowMinHeight
    }

    static func groupHorizontalPadding(isCompact _: Bool) -> CGFloat {
        0
    }

    static func dividerLeadingPadding(isCompact _: Bool) -> CGFloat {
        leadingIconFrame
    }

    static func dividerTrailingPadding(isCompact _: Bool) -> CGFloat {
        0
    }
}

enum CapabilityRailSectionPresentation {
    static let sectionTitle = "Capabilities"
    static let addActionTitle = "Add"
    static let addActionSubtitle = ""
    static let addActionHelp = "Browse capability library"
    static let addActionShowsPlusIcon = false
    static let showsAvailableToAddCount = false
    static let showsBrowseLibraryFooter = false
    static let showsTopHealthSummaryMetrics = false
    static let attentionGroupShowsWarningIcon = false
    static let attentionGroupUsesWarningTint = false

    static func readySummaryTitle(count: Int) -> String {
        "\(count) ready \(count == 1 ? "capability" : "capabilities")"
    }

    static func draftSummaryTitle(count: Int) -> String {
        "\(count) draft \(count == 1 ? "capability" : "capabilities")"
    }

    /// Status + count metadata shown beneath the noun-first capability summary
    /// title (the title carries the capability names).
    static func readySummarySubtitle(count: Int) -> String {
        "Ready · \(count)"
    }

    static func draftSummarySubtitle(count: Int) -> String {
        "Draft · \(count)"
    }

    /// Disclosure verb that names how many rows it reveals. Only rendered for
    /// count >= 2 — a lone capability renders expanded instead.
    static func showAllActionTitle(count: Int) -> String {
        "Show all (\(count))"
    }

    static func previewList(_ names: [String], limit: Int = 3) -> String {
        let displayNames = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !displayNames.isEmpty else { return "No details" }

        let visible = displayNames.prefix(limit)
        let remaining = displayNames.count - visible.count
        let prefix = visible.joined(separator: ", ")
        return remaining > 0 ? "\(prefix) +\(remaining)" : prefix
    }
}

struct CapabilityRailPackagePresentation: Equatable {
    let statusLabel: String?
    let actionTitle: String
    let rowSubtitle: String
    let scopeValues: [String]

    static func make(
        isEnabled: Bool,
        readinessLevel: CapabilityReadinessLevel,
        workspaceName: String,
        sharedResourceCount: Int,
        workspaceResourceCount: Int,
        declaredResourceCount: Int,
        contentSummary: String
    ) -> CapabilityRailPackagePresentation {
        let statusLabel: String?
        if !isEnabled {
            statusLabel = "Available"
        } else {
            switch readinessLevel {
            case .ready:
                statusLabel = nil
            case .needsAttention:
                statusLabel = "Needs setup"
            case .inactive:
                statusLabel = "Disabled"
            }
        }

        let actionTitle = "Details"
        let workspaceLabel = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "this workspace"
            : workspaceName
        var scopeValues: [String] = [
            isEnabled ? "Enabled for \(workspaceLabel)" : "Available in the library; not active here"
        ]

        if sharedResourceCount > 0 {
            scopeValues.append(
                "Uses \(countPhrase(sharedResourceCount, singular: "shared resource", plural: "shared resources")) reusable in other workspaces"
            )
        }
        if workspaceResourceCount > 0 {
            scopeValues.append(
                "Uses \(countPhrase(workspaceResourceCount, singular: "workspace resource", plural: "workspace resources")) that can differ here"
            )
        }
        if sharedResourceCount == 0, workspaceResourceCount == 0, declaredResourceCount > 0 {
            scopeValues.append("Installing links the declared package resources to this workspace")
        }

        let trimmedSummary = contentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowSubtitle: String
        if !trimmedSummary.isEmpty {
            rowSubtitle = trimmedSummary
        } else if declaredResourceCount > 0 {
            rowSubtitle = countPhrase(declaredResourceCount, singular: "declared resource", plural: "declared resources")
        } else {
            rowSubtitle = "Capability available to tasks"
        }

        return CapabilityRailPackagePresentation(
            statusLabel: statusLabel,
            actionTitle: actionTitle,
            rowSubtitle: rowSubtitle,
            scopeValues: scopeValues
        )
    }

    private static func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
