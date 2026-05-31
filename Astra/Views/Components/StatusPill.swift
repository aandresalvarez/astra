import SwiftUI

/// Small coloured pill used across the app to describe a task's outcome
/// state compactly — "Run finished", "Needs input", "Run failed", etc. It
/// consolidates what used to be three different ad-hoc chip renderings
/// (the Kanban card's outcomeChip, any inline `Text` status labels, and
/// so on) into one shape so status language reads consistently.
///
/// Callers usually use the `StatusPill.forStatus(_:)` factory, which
/// picks the right icon / label / color for an `TaskStatus` in one
/// place. Only pass raw values if you need a pill for something that
/// isn't on the standard status enum.
struct StatusPill: View {
    let icon: String
    let label: String
    let color: Color
    /// Long-form tooltip shown on hover. Explains what the state means
    /// and what the user can do about it — useful for power users who
    /// hover to orient themselves.
    var help: String? = nil
    var size: Size = .regular

    enum Size {
        /// Smaller variant for dense lists (e.g. sidebar rows). 10pt text.
        case compact
        /// Card / inline default. 11pt text.
        case regular
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(iconFont)
            Text(label)
                .font(textFont)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help(help ?? "")
        .accessibilityLabel("Status: \(label)")
        .accessibilityHint(help ?? "")
    }

    private var iconFont: Font {
        switch size {
        case .compact: Stanford.caption(9).weight(.semibold)
        case .regular: Stanford.caption(10).weight(.semibold)
        }
    }

    private var textFont: Font {
        switch size {
        case .compact: Stanford.caption(10).weight(.semibold)
        case .regular: Stanford.caption(11).weight(.semibold)
        }
    }
}

// MARK: - Semantic factories

extension StatusPill {
    /// Standard pill per task status. Returns `nil` for quiet states
    /// (draft / queued / running) that the design language chose not to
    /// surface as pills — they either get no chip at all (draft, queued)
    /// or a richer affordance elsewhere (running gets an animated bar).
    static func forStatus(
        _ status: TaskStatus,
        size: Size = .regular
    ) -> StatusPill? {
        switch status {
        case .pendingUser:
            return StatusPill(
                icon: "hand.raised.circle.fill",
                label: "Needs input",
                color: Stanford.pendingUser,
                help: "The agent paused waiting for your input. Open the card to reply so it can resume.",
                size: size
            )
        case .completed:
            return StatusPill(
                icon: "checkmark.circle.fill",
                label: "Run finished",
                color: Stanford.completed,
                help: "The agent finished its run without errors. Review the output to confirm, then close the task.",
                size: size
            )
        case .failed:
            return StatusPill(
                icon: "exclamationmark.triangle.fill",
                label: "Run failed",
                color: Stanford.failed,
                help: "The agent hit an error and stopped. Open the card to see the failure, then retry or close the task.",
                size: size
            )
        case .cancelled:
            return StatusPill(
                icon: "xmark.circle.fill",
                label: "Cancelled",
                color: Stanford.cancelled,
                help: "You stopped this task before it finished. Requeue to retry, or close the task.",
                size: size
            )
        case .budgetExceeded:
            return StatusPill(
                icon: "dollarsign.circle.fill",
                label: "Budget hit",
                color: Stanford.failed,
                help: "The agent ran out of token budget before finishing. Raise the budget and retry, or close the task.",
                size: size
            )
        case .draft, .queued, .running:
            return nil
        }
    }
}
