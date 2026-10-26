// Shared row, box-header and add-menu views for the Workspace Context rail
// (rail v2, docs/specs/2026-10-26-workspace-context-rail-v2.md). Extracted
// from WorkspaceRightRailView to keep that owner file within its line budget
// and to give the rail a single home for its reusable row vocabulary.

import SwiftUI
import AppKit
import ASTRACore
import ASTRAModels

private typealias RailLayout = WorkspaceRailSectionPresentation.Layout
private typealias RailAddAction = WorkspaceRailSectionPresentation.AddAction

/// A small green dot pinned to the corner of a row's leading icon to mark an
/// item as configured. The contrasting ring lifts it off the glyph so it reads
/// as a status badge rather than part of the icon.
struct ConfiguredStatusDot: View {
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Stanford.statusHealthy)
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .stroke(Stanford.cardBackground, lineWidth: 1.5)
            )
            .offset(x: 1, y: 1)
            .accessibilityHidden(true)
    }
}

/// A box header: the title with a tight chevron, the one-line summary while
/// collapsed, and a trailing `+` for the box's own adds. The title and chevron
/// toggle; the `+` is a separate target.
struct RailBoxHeader: View {
    let title: String
    let isExpanded: Bool
    let collapsedSummary: String
    let addActions: [WorkspaceRailSectionPresentation.AddAction]
    /// Spins while the box's facts are being re-read.
    var isBusy = false
    /// A quiet refresh control beside the `+`, for boxes whose facts come
    /// from scans (repositories, containers).
    var onRefresh: (() -> Void)? = nil
    let onToggle: () -> Void
    let onAdd: (WorkspaceRailSectionPresentation.AddAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(Stanford.ui(RailLayout.boxTitleFontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    if !isExpanded {
                        Text(collapsedSummary)
                            .font(Stanford.caption(RailLayout.rowValueFontSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 4)
                            .help(collapsedSummary)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: RailLayout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
            } else if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(Stanford.ui(11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh \(title.lowercased())")
                .accessibilityLabel("Refresh \(title)")
            }

            if !addActions.isEmpty {
                RailAddMenuButton(actions: addActions, onAdd: onAdd)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A box's `+`, or the rail-level `Add…` chip at the foot of the rail. One
/// action runs on the tap; several pop an AppKit menu, so the control never
/// flattens into a greedy SwiftUI `Menu` label.
struct RailAddMenuButton: View {
    enum Style: Equatable {
        case plus
        case chip
    }

    let actions: [WorkspaceRailSectionPresentation.AddAction]
    var style: Style = .plus
    let onAdd: (WorkspaceRailSectionPresentation.AddAction) -> Void

    @State private var menuAnchor: NSView?

    var body: some View {
        Button {
            present()
        } label: {
            switch style {
            case .plus:
                Image(systemName: "plus")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            case .chip:
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(Stanford.ui(10, weight: .semibold))
                    Text(WorkspaceRailSectionPresentation.railAddTitle)
                        .font(Stanford.caption(RailLayout.rowValueFontSize).weight(.medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .background { ToolbarMenuAnchorView(anchor: $menuAnchor) }
        .help(helpTitle)
        .accessibilityLabel(helpTitle)
        .disabled(actions.isEmpty)
    }

    private var helpTitle: String {
        actions.count == 1 ? actions[0].title : WorkspaceRailSectionPresentation.railAddTitle
    }

    private func present() {
        if actions.count == 1, let only = actions.first {
            onAdd(only)
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            menu.addItem(
                ToolbarClosureMenuItem(title: action.title, systemSymbolName: Self.systemImage(for: action)) {
                    onAdd(action)
                }
            )
        }

        if let menuAnchor {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: menuAnchor.bounds.minY - 4),
                in: menuAnchor
            )
        } else if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    static func systemImage(for action: WorkspaceRailSectionPresentation.AddAction) -> String {
        switch action {
        case .addCapability: "puzzlepiece.extension"
        case .addMemory: "text.badge.checkmark"
        case .newRoutine: "arrow.triangle.2.circlepath"
        case .addFolder: "folder.badge.plus"
        case .connectServer: "network"
        case .runInContainer: "shippingbox"
        }
    }
}

/// One line per fact: leading icon, key, trailing value, muted detail, an
/// optional verb or label, and a disclosure chevron when the row expands in
/// place. The row body is one tap target; the verb is another.
struct RailKeyValueRow: View {
    let row: WorkspaceRailSectionPresentation.Row
    var brand: BrandMark? = nil
    var isExpanded = false
    /// The tooltip. Defaults to the value, so a truncated path stays readable.
    var help: String? = nil
    var onTap: (() -> Void)? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onTap?()
            } label: {
                HStack(spacing: 8) {
                    CapabilityLeadingIcon(
                        systemImage: row.systemImage,
                        brand: brand,
                        pointSize: RailLayout.leadingIconFontSize
                    )
                    .foregroundStyle(.secondary)
                    .frame(width: RailLayout.leadingIconFrame)

                    Text(row.title)
                        .font(Stanford.ui(RailLayout.rowTitleFontSize))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    if let value = row.value {
                        Text(value)
                            .font(valueFont)
                            .foregroundStyle(valueColor)
                            .lineLimit(1)
                            .truncationMode(usesMonospace ? .head : .tail)
                    }

                    if let detail = row.detail {
                        Text(detail)
                            .font(Stanford.caption(RailLayout.rowValueFontSize))
                            .foregroundStyle(row.tone == .info ? Stanford.statusInfo : Stanford.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: RailLayout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            .help(help ?? row.value ?? row.title)

            if let action = row.action {
                actionView(action)
            }

            if row.isExpandable, onTap != nil {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Stanford.ui(9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func actionView(_ action: WorkspaceRailSectionPresentation.RowAction) -> some View {
        switch action {
        case .verb(let title):
            Button {
                onAction?()
            } label: {
                Text(title)
                    .font(Stanford.caption(RailLayout.rowValueFontSize).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .help(title)
        case .repair(let title):
            Button(title) {
                onAction?()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Stanford.poppy)
        case .label(let title):
            Text(title)
                .font(Stanford.caption(RailLayout.rowValueFontSize))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var usesMonospace: Bool {
        row.kind == .folder || row.kind == .repository
    }

    private var valueFont: Font {
        usesMonospace
            ? Stanford.mono(RailLayout.rowValueFontSize - 0.5)
            : Stanford.caption(RailLayout.rowValueFontSize)
    }

    private var valueColor: Color {
        switch row.tone {
        case .neutral: .secondary
        case .info: Stanford.statusInfo
        case .link: Stanford.lagunita
        }
    }
}

struct CapabilityRailSnapshot {
    let items: [RailCapabilityItem]
    let attentionItems: [RailCapabilityItem]
    let readyItems: [RailCapabilityItem]
    let draftItems: [RailCapabilityItem]
    let needsSetupCount: Int

    static let empty = CapabilityRailSnapshot(items: [], isDraft: { _ in false })

    init(
        items: [RailCapabilityItem],
        isDraft: (RailCapabilityItem) -> Bool
    ) {
        self.items = items
        attentionItems = items.filter { $0.readiness.level == .needsAttention }
        readyItems = items.filter { $0.readiness.level != .needsAttention && !isDraft($0) }
        draftItems = items.filter(isDraft)
        needsSetupCount = attentionItems.count
    }
}

struct RailCapabilityItem: Identifiable {
    enum Source {
        case package(PluginPackage)
        case skill(Skill)
    }

    let id: String
    let name: String
    let icon: String
    let summary: String
    let color: Color
    let isEnabled: Bool
    let readiness: CapabilityReadiness
    let presentation: CapabilityRailPackagePresentation
    let source: Source
    let skillNames: [String]
    let connectorNames: [String]
    let toolNames: [String]
    let mcpServerNames: [String]
    let browserAdapterNames: [String]
    let templateNames: [String]
    let requirementNames: [String]
    var runtimePermissionAttention: CapabilityRuntimePermissionAttention? = nil
    /// What gets this capability working again, when a check failed.
    var repair: RepairAction? = nil

    /// The recognizable brand the capability integrates with, if any, so its row
    /// can lead with the real mark instead of a stand-in SF Symbol.
    var brand: BrandMark? { BrandMark.resolve(id: id, name: name) }
}

/// A capability as one line: mark, name, and, only when the capability is
/// blocked, its repair verb as a tinted button. The button is the whole
/// signal; a ready capability shows nothing but its name. The composition
/// summary lives in the tooltip.
struct CapabilityRailRow: View {
    let icon: String
    var brand: BrandMark?
    let title: String
    /// Inventory and readiness detail, shown as the row's tooltip.
    let subtitle: String
    let readiness: CapabilityReadiness
    /// A passive trailing label (`Draft`, `Restored`), shown only when no
    /// repair button is.
    let statusLabel: String?
    let isEnabled: Bool
    var isCompact = false
    /// A separate verb ("Sign in", "Install") beside the row, never the row's
    /// own tap target, per the lean UI system.
    var repairVerb: String? = nil
    /// What a Terminal repair does (`repairGuidance(for:)`): the command it
    /// runs, shown with a second tap to run it before anything a plugin
    /// declared is executed, or, for one that runs nothing ("Start Docker
    /// Desktop…"), what to fix, shown before its check starts.
    var repairGuidance: (text: String, isCommand: Bool)? = nil
    var repairStatus: String? = nil
    var repairIsChecking = false
    var onRepair: (() -> Void)? = nil
    /// A repair with its own control (GitHub repository access), shown in
    /// place of the verb.
    var contextualRepair: AnyView? = nil
    let onOpen: () -> Void

    @State private var isConfirmingCommand = false

    var canStartRepair: Bool {
        guard repairVerb != nil, onRepair != nil, !repairIsChecking else { return false }
        if let _ = contextualRepair { return false }
        return true
    }

    private static var detailLeadingPadding: CGFloat {
        RailLayout.leadingIconFrame + 8 + 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                rowButton
                if let contextualRepair {
                    contextualRepair
                } else if repairIsChecking, let repairStatus {
                    Text(repairStatus)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if canStartRepair, let repairVerb, let onRepair {
                    Button(repairVerb) {
                        if repairGuidance == nil { onRepair() } else { isConfirmingCommand.toggle() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.poppy)
                    .help(readiness.messages.joined(separator: "\n"))
                    .accessibilityIdentifier("CapabilityRailRepairButton")
                } else if let statusLabel {
                    Text(statusLabel)
                        .font(Stanford.caption(RailLayout.rowValueFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            if !repairIsChecking, let repairStatus {
                Text(repairStatus)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.detailLeadingPadding)
                    .accessibilityIdentifier("CapabilityRailRepairFailure")
            }
            if isConfirmingCommand, canStartRepair, let repairGuidance, let onRepair {
                HStack(spacing: 6) {
                    Text(repairGuidance.text)
                        .font(repairGuidance.isCommand ? .system(size: 11, design: .monospaced) : Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(repairGuidance.isCommand ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: !repairGuidance.isCommand)
                    Spacer(minLength: 4)
                    Button(repairGuidance.isCommand ? "Run in Terminal" : "Check now") {
                        isConfirmingCommand = false
                        onRepair()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("CapabilityRailRepairRunButton")
                }
                .padding(.leading, Self.detailLeadingPadding)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
    }

    /// The rail's guidance for `repair`: a Terminal repair's command, or its
    /// prose when it runs none (`PluginsSurfacePresentation.repairGuidance`).
    /// Nil for a repair with its own flow (a page, a form, a code).
    static func repairGuidance(for repair: RepairAction?) -> (text: String, isCommand: Bool)? {
        guard let repair, repair.strategy == .terminal else { return nil }
        return PluginsSurfacePresentation.repairGuidance(repair)
    }

    private var rowButton: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                CapabilityLeadingIcon(
                    systemImage: icon,
                    brand: brand,
                    pointSize: RailLayout.leadingIconFontSize
                )
                .foregroundStyle(.secondary)
                .frame(width: RailLayout.leadingIconFrame)

                Text(title.isEmpty ? WorkspaceRailSectionPresentation.untitledCapabilityName : title)
                    .font(Stanford.ui(RailLayout.rowTitleFontSize))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, minHeight: RailLayout.rowHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(subtitle.isEmpty ? "Open details" : subtitle)
    }
}

/// String-list helpers for rail capability summaries. Namespaced rather than a
/// module-wide `Array<String>` extension so the behavior is discoverable and
/// can't collide with similarly named helpers elsewhere.
enum RailStringList {
    /// Trim, drop blanks, de-duplicate, and case-insensitively sort.
    static func uniqueSorted(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && seen.insert(trimmed).inserted
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
