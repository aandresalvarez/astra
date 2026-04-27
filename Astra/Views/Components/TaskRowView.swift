import SwiftUI

struct TaskRowView: View {
    let task: AgentTask
    let isSelected: Bool

    private var statusLabel: String? {
        switch task.status {
        case .running: return "Running"
        case .pendingUser: return "Needs input"
        case .failed: return "Needs retry"
        case .budgetExceeded: return "Budget hit"
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            statusDot
                .frame(width: 8, height: 8)

            Text(task.title)
                .font(Stanford.ui(16, weight: isSelected ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if task.originScheduleID != nil {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Stanford.ui(9))
                    .foregroundStyle(Stanford.poppy.opacity(0.7))
            }

            Spacer(minLength: 0)

            if let label = statusLabel {
                Text(label)
                    .font(Stanford.caption(13))
                    .foregroundStyle(statusColor.opacity(0.8))
            } else {
                Text(relativeTime(task.updatedAt))
                    .font(Stanford.caption(13))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("TaskRow_\(task.title)")
    }

    private var statusColor: Color {
        switch task.status {
        case .running: return Stanford.lagunita
        case .pendingUser: return Stanford.pendingUser
        case .failed, .budgetExceeded: return Stanford.failed
        default: return .secondary
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch task.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark")
                .font(Stanford.ui(8, weight: .bold))
                .foregroundStyle(Stanford.completed)
        case .pendingUser:
            Circle()
                .fill(Stanford.pendingUser)
                .frame(width: 7, height: 7)
        case .failed, .budgetExceeded:
            Circle()
                .fill(Stanford.failed)
                .frame(width: 7, height: 7)
        case .cancelled:
            Circle()
                .fill(.quaternary)
                .frame(width: 6, height: 6)
        case .queued:
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1.5)
                .frame(width: 7, height: 7)
        case .draft:
            Circle()
                .strokeBorder(.quaternary, lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        if interval < 2592000 { return "\(Int(interval / 604800))w" }
        return "\(Int(interval / 2592000))mo"
    }
}
