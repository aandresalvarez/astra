import SwiftUI
import ASTRAModels
import ASTRACore

/// A task row on the sidebar rail (workspace drawers, Pinned, Unreads).
/// Lives here (not in `TaskSidebarView`) to keep that file within its
/// architecture-fitness line budget.
struct SidebarThreadRow: View {
    let task: AgentTask
    let isSelected: Bool
    /// Hover signal driven by the parent's `hoveredTaskID` instead of an
    /// internal `@State`. Two separate hover sources (one inner, one
    /// outer) used to race — the three-dots overlay would appear (parent's
    /// hover fired) while the inner timestamp stayed visible (inner
    /// hover hadn't fired yet), which is what produced the overlap. One
    /// source of truth fixes the race.
    let isHovered: Bool
    var contentLeadingPadding: CGFloat = 0
    var attemptCount: Int = 1
    var subtitle: String?
    /// Hidden when the row is rendered inside the Pinned section — the
    /// section already implies "pinned" and the unpin overlay button
    /// covers the same gutter on hover, so showing the glyph there
    /// would just add noise. Pinned tasks are excluded from their
    /// workspace's own list entirely (`SidebarTaskIndex` groups them into
    /// `pinnedTasks` instead of the per-workspace groups), so in practice
    /// this glyph now only fires in the Unreads row, for a task that is
    /// both pinned and unread.
    var showsPinIndicator: Bool = true
    /// Hidden inside the Pinned section: the same task already shows
    /// its timestamp in the Unreads row when it's also unread, and
    /// dropping it here keeps the right gutter clear for the unpin
    /// overlay (which previously had to fight the timestamp for the same
    /// x-position) and gives pinned titles more room before they truncate.
    var showsTimestamp: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.10)
    }

    private var metadataAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private var titleWeight: Font.Weight {
        if task.shouldShowUnread { return .semibold }
        return isSelected ? .medium : .regular
    }

    private var metadataWeight: Font.Weight {
        task.shouldShowUnread ? .semibold : .regular
    }

    private var showIcon: Bool {
        SidebarThreadRowLayout.showsStatusIcon(
            for: task.status,
            isUnread: task.shouldShowUnread,
            isHovered: isHovered,
            isSelected: isSelected
        )
    }

    private var isActionableStatus: Bool {
        SidebarThreadRowLayout.isActionableStatus(task.status)
    }

    /// True when the row's glyph is the unread dot: a finished result the
    /// user hasn't looked at yet. Actionable states keep their own glyphs —
    /// they already say "needs me" more specifically than a dot could.
    private var showsUnreadDot: Bool {
        task.shouldShowUnread && !isActionableStatus
    }

    /// Names the leading glyph for tooltips and VoiceOver — the status text
    /// no longer renders as a second line, so the glyph has to speak.
    private var statusGlyphDescription: String {
        if showsUnreadDot { return "Unread result" }
        switch task.status {
        case .running:        return "Running"
        case .pendingUser:    return "Needs input"
        case .failed:         return "Needs retry"
        case .budgetExceeded: return "Budget hit"
        case .cancelled:      return "Cancelled"
        case .completed:      return "Completed"
        case .queued:         return "Queued"
        case .draft:          return "Draft"
        }
    }

    private var titlePresentation: Formatters.SidebarTaskTitlePresentation {
        Formatters.sidebarTaskTitlePresentation(task.title)
    }

    var body: some View {
        HStack(alignment: .center, spacing: SidebarThreadRowLayout.statusIconTitleSpacing) {
            if showIcon {
                statusIcon
                    .frame(
                        width: SidebarThreadRowLayout.statusIconWidth,
                        height: SidebarThreadRowLayout.statusIconWidth
                    )
                    .opacity(isActionableStatus && !isSelected && !isHovered ? 0.6 : 1)
                    .padding(.leading, contentLeadingPadding)
                    .help(statusGlyphDescription)
                    .accessibilityLabel(statusGlyphDescription)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    SidebarTaskTitleText(
                        presentation: titlePresentation,
                        font: Stanford.ui(SidebarThreadRowLayout.titleFontSize, weight: titleWeight)
                    )
                    .layoutPriority(1)

                    if attemptCount > 1 {
                        Text("\(attemptCount) attempts")
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(Stanford.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .fixedSize()
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, showIcon ? 0 : contentLeadingPadding)

            Spacer(minLength: 6)

            // Right-side metadata is hidden on
            // hover so the three-dots context-menu overlay (added by
            // `compactTaskRow`) can render without overlapping text.
            // Keep the layout in place (no width shift) by using opacity,
            // not conditional removal.
            if showsTimestamp {
                HStack(spacing: 5) {
                    if task.isPinned && showsPinIndicator {
                        // Tells the user "this row also appears in the
                        // Pinned section" — reachable only from the
                        // Unreads row (pinned tasks are excluded from
                        // their workspace's own list, so they no longer
                        // render there too).
                        Image(systemName: "pin.fill")
                            .font(Stanford.ui(9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.58))
                            .help("Pinned")
                            .accessibilityLabel("Pinned")
                    }
                    // TimelineView keeps "now"/"5m" honest: the label used to
                    // refresh only when task data changed, so a quiet row
                    // could claim "now" for an hour.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(relativeTime(task.updatedAt, now: context.date))
                            .font(Stanford.caption(11).weight(metadataWeight))
                            .foregroundStyle(task.shouldShowUnread ? Color.primary : Stanford.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 24, alignment: .trailing)
                            .accessibilityLabel(relativeTimeSpoken(task.updatedAt, now: context.date))
                    }
                }
                .opacity(isHovered ? 0 : 1)
                // Fades the timestamp out at the same rate as the
                // hover-only overlay buttons (`unpin`, `taskOptionsMenu`)
                // fade in, so the right gutter swaps smoothly instead of
                // one element snapping while the other animates.
                .animation(metadataAnimation, value: isHovered)
            }
        }
        .padding(.horizontal, SidebarThreadRowLayout.rowHorizontalPadding)
        .padding(.vertical, 5)
        .frame(minHeight: Stanford.sidebarThreadRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .fill(rowFill)
                .animation(selectionAnimation, value: isSelected)
                .animation(hoverAnimation, value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
                .animation(selectionAnimation, value: isSelected)
                .animation(hoverAnimation, value: isHovered)
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier("TaskRow_\(task.title)")
    }

    private var rowFill: Color {
        if isSelected { return Stanford.selectionFill }
        if isHovered { return Color.primary.opacity(0.052) }
        return .clear
    }

    private var rowStroke: Color {
        if isSelected { return Color.primary.opacity(0.10) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }

    @ViewBuilder
    private var statusIcon: some View {
        if showsUnreadDot {
            // Same dot the Unreads section header wears, so "red dot =
            // unseen result" stays one vocabulary across the rail.
            Image(systemName: "circle.fill")
                .font(Stanford.ui(6, weight: .medium))
                .foregroundStyle(Stanford.cardinalRed)
        } else {
            statusGlyph
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch task.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(Stanford.lagunita)
                .scaleEffect(0.8)
        case .completed:
            Image(systemName: "checkmark.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.completed)
        case .pendingUser:
            Image(systemName: "person.crop.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.pendingUser)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.failed)
        case .budgetExceeded:
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.poppy)
        case .cancelled:
            Image(systemName: "minus.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock")
                .font(Stanford.ui(12))
                .foregroundStyle(.secondary)
        case .draft:
            Image(systemName: "pencil")
                .font(Stanford.ui(11))
                .foregroundStyle(.secondary)
        }
    }

    private func relativeTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        if interval < 2592000 { return "\(Int(interval / 604800))w" }
        return "\(Int(interval / 2592000))mo"
    }

    /// VoiceOver counterpart of `relativeTime` — "4d" reads as noise, so the
    /// label speaks "Updated 4 days ago".
    private func relativeTimeSpoken(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        func spoken(_ value: Int, _ unit: String) -> String {
            "Updated \(value) \(unit)\(value == 1 ? "" : "s") ago"
        }
        if interval < 60 { return "Updated just now" }
        if interval < 3600 { return spoken(Int(interval / 60), "minute") }
        if interval < 86400 { return spoken(Int(interval / 3600), "hour") }
        if interval < 604800 { return spoken(Int(interval / 86400), "day") }
        if interval < 2592000 { return spoken(Int(interval / 604800), "week") }
        return spoken(Int(interval / 2592000), "month")
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
