// Shared row & badge views for the Workspace Context right rail (capability
// rows, summary rows, hierarchy lines, empty states). Extracted from
// WorkspaceRightRailView to keep that owner file within its line budget and to
// give the rail a single home for its reusable row vocabulary.

import SwiftUI
import ASTRACore
import ASTRAModels

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

struct CapabilitySummaryRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: CapabilityRailLayout.leadingIconSpacing) {
                Image(systemName: icon)
                    .font(Stanford.ui(CapabilityRailLayout.leadingIconFontSize, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: CapabilityRailLayout.leadingIconFrame)

                VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                    Text(title)
                        .font(Stanford.ui(CapabilityRailLayout.rowTitleFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                }
                .layoutPriority(1)

                Spacer(minLength: 10)

                if let actionTitle {
                    Text(actionTitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowActionFontSize).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.summaryRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CapabilityEmptyPrompt: View {
    let title: String
    let description: String
    let actionTitle: String
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)

            Text(description)
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
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

    /// The recognizable brand the capability integrates with, if any, so its row
    /// can lead with the real mark instead of a stand-in SF Symbol.
    var brand: BrandMark? { BrandMark.resolve(id: id, name: name) }
}

struct CapabilityRailRow: View {
    let icon: String
    var brand: BrandMark?
    let title: String
    let subtitle: String
    let color: Color
    let readiness: CapabilityReadiness
    let statusLabel: String?
    let statusColor: Color
    let isEnabled: Bool
    var isCompact = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: CapabilityRailLayout.leadingIconSpacing) {
                CapabilityLeadingIcon(
                    systemImage: icon,
                    brand: brand,
                    pointSize: CapabilityRailLayout.leadingIconFontSize
                )
                .foregroundStyle(isEnabled ? color : .secondary)
                .frame(width: CapabilityRailLayout.leadingIconFrame)

                VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                    HStack(spacing: 5) {
                        Text(title.isEmpty ? "Untitled Capability" : title)
                            .font(Stanford.ui(CapabilityRailLayout.rowTitleFontSize, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 6)

                        if let statusLabel {
                            CapabilityStatusBadge(title: statusLabel, color: statusColor)
                                .help(readiness.messages.joined(separator: "\n"))
                                .accessibilityLabel(statusLabel)
                        }
                    }

                    Text(subtitle.isEmpty ? "No details" : subtitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.65))
            }
            .contentShape(Rectangle())
            .frame(
                maxWidth: .infinity,
                minHeight: CapabilityRailLayout.rowMinHeight(isCompact: isCompact),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .help(subtitle.isEmpty ? "Open details" : subtitle)
    }
}

struct CapabilityStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(Stanford.caption(11).weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.07))
            .clipShape(Capsule())
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

extension View {
    /// Card chrome shared by the rail's floating sections and the row components
    /// above. Lives here, with the rows it dresses, rather than in a feature view
    /// file so the extracted components don't implicitly depend on that file.
    func railCard(
        cornerRadius: CGFloat = Stanford.railCardCornerRadius,
        fill: Color = Color(nsColor: .windowBackgroundColor),
        strokeOpacity: Double = 0.06
    ) -> some View {
        liquidSurface(
            cornerRadius: cornerRadius,
            fallbackFill: fill,
            fallbackStrokeOpacity: strokeOpacity
        )
    }
}
