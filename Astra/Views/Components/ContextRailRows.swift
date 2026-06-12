// Shared row & badge views for the Workspace Context right rail (capability
// rows, summary rows, hierarchy lines, empty states). Extracted from
// WorkspaceRightRailView to keep that owner file within its line budget and to
// give the rail a single home for its reusable row vocabulary.

import SwiftUI
import ASTRACore

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

struct RailCountBadge: View {
    let text: String

    init(count: Int) {
        self.text = "\(count)"
    }

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Stanford.caption(11).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Stanford.railBadgeHorizontalPadding)
            .frame(minWidth: Stanford.railBadgeMinWidth, minHeight: Stanford.railBadgeHeight)
            .background(Color.primary.opacity(0.05))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Stanford.railBadgeCornerRadius,
                    style: .continuous
                )
            )
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

struct CapabilityHierarchySummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CapabilityHierarchyLine(
                icon: "shippingbox",
                title: "Package",
                detail: "workspace switch"
            )
            CapabilityHierarchyLine(
                icon: "text.quote",
                title: "Skills",
                detail: "instructions"
            )
            CapabilityHierarchyLine(
                icon: "slider.horizontal.3",
                title: "Connectors, tools, browser",
                detail: "access and execution"
            )
        }
    }
}

struct CapabilityHierarchyLine: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(Stanford.caption(10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

struct CapabilityOverviewMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(Stanford.ui(9, weight: .semibold))
                    .foregroundStyle(color)
                Text(value)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            Text(title)
                .font(Stanford.caption(10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapabilityResourceScopeRow: View {
    let title: String
    let value: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(value)")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

struct CapabilityRailSnapshot {
    let items: [RailCapabilityItem]
    let attentionItems: [RailCapabilityItem]
    let readyItems: [RailCapabilityItem]
    let draftItems: [RailCapabilityItem]
    let needsSetupCount: Int

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
    let browserAdapterNames: [String]
    let templateNames: [String]
    let requirementNames: [String]

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

struct CapabilityRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var trailing: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? "No details" : subtitle)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
    }
}

struct CapabilityToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? color : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? "No details" : subtitle)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .padding(.trailing, 4)
    }
}

struct ResourceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var onEdit: (() -> Void)?

    var body: some View {
        Group {
            if let onEdit {
                Button(action: onEdit) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(Stanford.railCardPadding)
        .frame(minHeight: Stanford.railResourceRowHeight, alignment: .leading)
        .railCard(cornerRadius: Stanford.railCardCornerRadius)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: Stanford.railIconFrame, height: Stanford.railIconFrame)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.body(13).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? "No details" : subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if onEdit != nil {
                Image(systemName: "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .contentShape(Rectangle())
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

struct InlineActionRow: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

struct EmptyRailState: View {
    let title: String
    let description: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Stanford.body(13).weight(.medium))
                .foregroundStyle(.secondary)
            Text(description)
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Stanford.railCardPadding)
        .background(
            RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius, style: .continuous)
                .fill(emptyStateFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius, style: .continuous)
                .stroke(emptyStateStroke, lineWidth: 1)
        }
    }

    private var emptyStateFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.04)
            : Color.primary.opacity(0.025)
    }

    private var emptyStateStroke: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.075)
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
