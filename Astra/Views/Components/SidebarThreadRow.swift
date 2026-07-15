import SwiftUI
import ASTRAModels
import ASTRACore

/// Resolves task-row chrome without baking light-mode colors into the policy.
/// The view maps these semantic roles to adaptive SwiftUI/theme colors.
enum SidebarThreadRowSurfaceStyle {
    enum Fill: Equatable {
        case clear
        case adaptiveNeutral(opacity: Double)
        case keyboardFocus
        case selection
    }

    enum Stroke: Equatable {
        case clear
        case keyboardFocus
        case selection
    }

    struct Resolution: Equatable {
        let fill: Fill
        let stroke: Stroke
        let strokeWidth: CGFloat
    }

    static let hoverFillOpacity = 0.03

    static func resolve(
        isSelected: Bool,
        isHovered: Bool,
        isKeyboardFocused: Bool
    ) -> Resolution {
        let fill: Fill
        if isSelected {
            fill = .selection
        } else if isKeyboardFocused {
            fill = .keyboardFocus
        } else if isHovered {
            fill = .adaptiveNeutral(opacity: hoverFillOpacity)
        } else {
            fill = .clear
        }

        if isKeyboardFocused {
            return Resolution(fill: fill, stroke: .keyboardFocus, strokeWidth: 2)
        }
        if isSelected {
            return Resolution(fill: fill, stroke: .selection, strokeWidth: 1)
        }
        return Resolution(fill: fill, stroke: .clear, strokeWidth: 0)
    }
}

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
    /// True while either the row button or its trailing accessory owns
    /// keyboard focus. Focus is deliberately distinct from pointer hover so
    /// the active control remains visible without relying on a gray shade.
    var isKeyboardFocused: Bool = false
    var contentLeadingPadding: CGFloat = 0
    var attemptCount: Int = 1
    var subtitle: String?
    /// Optional context shown when hovering the title. Pinned tasks use this
    /// for workspace identity instead of spending a second line on it.
    var titleHelp: String?
    /// Hidden when the row is rendered inside the Pinned section — the
    /// section already implies "pinned" and the unpin overlay button
    /// covers the same gutter on hover, so showing the glyph there
    /// would just add noise. Pinned tasks are excluded from their
    /// workspace's own list entirely (`SidebarTaskIndex` groups them into
    /// `pinnedTasks` instead of the per-workspace groups), so in practice
    /// this glyph now only fires in the Unreads row, for a task that is
    /// both pinned and unread.
    var showsPinIndicator: Bool = true
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

    private var showIcon: Bool {
        SidebarThreadRowLayout.showsStatusIcon(
            for: task.status,
            isUnread: task.shouldShowUnread,
            isHovered: isHovered,
            isKeyboardFocused: isKeyboardFocused,
            isSelected: isSelected
        )
    }

    private var isActionableStatus: Bool {
        SidebarThreadRowLayout.isActionableStatus(task.status)
    }

    private var showsHoverChrome: Bool {
        isHovered || isKeyboardFocused
    }

    private var surfaceStyle: SidebarThreadRowSurfaceStyle.Resolution {
        SidebarThreadRowSurfaceStyle.resolve(
            isSelected: isSelected,
            isHovered: isHovered,
            isKeyboardFocused: isKeyboardFocused
        )
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
        SidebarTaskActionPresentation.rowTitle(for: task.title)
    }

    var body: some View {
        HStack(alignment: .center, spacing: SidebarThreadRowLayout.statusIconTitleSpacing) {
            // The status gutter is always laid out; only the glyph's
            // opacity changes. Conditional insertion used to shove the
            // title 23pt sideways when hover/selection revealed the glyph
            // on a quiet row — same no-width-shift rule as the trailing
            // timestamp ↔ options swap below, and it keeps titles on one
            // left edge across glyph and bare rows.
            ZStack {
                if showIcon {
                    statusIcon
                        .opacity(isActionableStatus && !isSelected && !isHovered ? 0.6 : 1)
                        .help(statusGlyphDescription)
                        .accessibilityLabel(statusGlyphDescription)
                        .transition(.opacity)
                }
            }
            .frame(
                width: SidebarThreadRowLayout.statusIconWidth,
                height: SidebarThreadRowLayout.statusIconWidth
            )
            .padding(.leading, contentLeadingPadding)
            .animation(metadataAnimation, value: showIcon)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    SidebarTaskTitleText(
                        presentation: titlePresentation,
                        font: Stanford.ui(SidebarThreadRowLayout.titleFontSize, weight: titleWeight),
                        helpText: titleHelp
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        colors: [
                            .black,
                            showsHoverChrome ? .clear : .black
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: SidebarTaskAccessoryPresentation.trailingFadeWidth)
                }
                .animation(metadataAnimation, value: showsHoverChrome)
            }

            if task.isPinned && showsPinIndicator {
                // Preserve the Unreads row's cross-section signal without
                // reserving a trailing slot on every task. Workspace rows
                // never reach this branch because pinned tasks live in the
                // Pinned section, where the caller suppresses the glyph.
                Image(systemName: "pin.fill")
                    .font(Stanford.ui(9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.58))
                    .help("Pinned")
                    .accessibilityLabel("Pinned")
                    .opacity(showsHoverChrome ? 0 : 1)
                    .animation(metadataAnimation, value: showsHoverChrome)
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
                .animation(hoverAnimation, value: isKeyboardFocused)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .stroke(rowStroke, lineWidth: surfaceStyle.strokeWidth)
                .animation(selectionAnimation, value: isSelected)
                .animation(hoverAnimation, value: isHovered)
                .animation(hoverAnimation, value: isKeyboardFocused)
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier("TaskRow_\(task.title)")
    }

    private var rowFill: Color {
        switch surfaceStyle.fill {
        case .clear:
            return .clear
        case .adaptiveNeutral(let opacity):
            return Color.primary.opacity(opacity)
        case .keyboardFocus:
            return Stanford.focusRing.opacity(0.08)
        case .selection:
            return Stanford.selectionFill
        }
    }

    private var rowStroke: Color {
        switch surfaceStyle.stroke {
        case .clear:
            return .clear
        case .keyboardFocus:
            return Stanford.focusRing.opacity(0.82)
        case .selection:
            return Color.primary.opacity(0.10)
        }
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

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
