import SwiftUI

/// The worktree list's header row: what the Reclaim button would free, the
/// button itself, and the outcome of the last manual and automatic passes.
/// State reads as quiet text; Reclaim is the one verb.
struct WorktreeStorageHeader: View {
    @ObservedObject var storage: WorktreeReclaimService
    let worktrees: [GitWorktreeInfo]
    let onReclaim: () -> Void

    @State private var confirmsReclaim = false
    @State private var showsSkipped = false

    private var reclaimable: Int64 { storage.reclaimableBytes(in: worktrees) }
    private var isMeasuring: Bool { worktrees.contains { storage.measuringPaths.contains($0.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Worktrees")
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                status
            }
            if let manual = storage.lastManualReclaim {
                manualSummary(manual)
            }
            if let automatic = storage.lastAutomaticReclaim {
                Text("Reclaimed \(WorktreeStorageFormat.bytes(automatic.freedBytes)) from \(Self.worktreeCount(automatic.reclaimedWorktreeCount, idle: true)) · \(Self.when(automatic.finishedAt))")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
            }
        }
        .confirmationDialog(
            "Reclaim \(WorktreeStorageFormat.bytes(reclaimable)) of build artifacts?",
            isPresented: $confirmsReclaim
        ) {
            Button("Reclaim", action: onReclaim)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes .build, target and node_modules folders next to their manifests. They are rebuilt on the next build; source files are not touched.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if storage.isReclaiming || isMeasuring {
            ProgressView().controlSize(.mini)
            Text(storage.isReclaiming ? "Reclaiming…" : "Measuring…")
                .font(Stanford.caption(10))
                .foregroundStyle(.secondary)
        } else if reclaimable > 0 {
            Text("Build artifacts: \(WorktreeStorageFormat.bytes(reclaimable)) reclaimable")
                .font(Stanford.caption(10))
                .foregroundStyle(.secondary)
            Button("Reclaim") { confirmsReclaim = true }
                .buttonStyle(.plain)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
        }
    }

    @ViewBuilder
    private func manualSummary(_ summary: WorktreeReclaimSummary) -> some View {
        let reasons = summary.skipReasons
        HStack(spacing: 4) {
            Text(summary.freedBytes > 0
                 ? "Reclaimed \(WorktreeStorageFormat.bytes(summary.freedBytes)) from \(Self.worktreeCount(summary.reclaimedWorktreeCount, idle: false))"
                 : "Nothing reclaimed")
            if reasons.count >= 2 {
                Text("·")
                Button(showsSkipped ? "Hide skipped" : "Show skipped (\(reasons.count))") { showsSkipped.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.lagunita)
            }
        }
        .font(Stanford.caption(10))
        .foregroundStyle(.tertiary)
        // A lone reason is shown outright; hiding one item saves nothing.
        if reasons.count == 1 || showsSkipped {
            ForEach(reasons, id: \.self) { reason in
                Text(reason)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private static func worktreeCount(_ count: Int, idle: Bool) -> String {
        let noun = count == 1 ? "worktree" : "worktrees"
        return idle ? "\(count) idle \(noun)" : "\(count) \(noun)"
    }

    /// "today 10:42", "yesterday 18:05", else the short date and time.
    static func when(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Trailing size label on a worktree row: "3.1 GB · 2.9 GB build".
struct WorktreeStorageRowSize: View {
    @ObservedObject var storage: WorktreeReclaimService
    let worktree: GitWorktreeInfo

    var body: some View {
        if let report = storage.statuses[worktree.path]?.report, report.exists {
            Text(Self.label(for: report))
                .font(Stanford.caption(10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        } else if storage.measuringPaths.contains(worktree.path) {
            ProgressView().controlSize(.mini)
        }
    }

    static func label(for report: WorktreeStorageReport) -> String {
        let total = WorktreeStorageFormat.bytes(report.totalBytes)
        guard report.artifactBytes > 0 else { return total }
        return "\(total) · \(WorktreeStorageFormat.bytes(report.artifactBytes)) build"
    }
}

/// Quiet third line on a worktree row: a stale entry, or the removal
/// suggestion ("Merged · idle 9 d · Remove"), which goes through the existing
/// removal flow and its dirty/force confirmation.
struct WorktreeStorageRowNote: View {
    @ObservedObject var storage: WorktreeReclaimService
    let worktree: GitWorktreeInfo
    let onRemove: () -> Void

    var body: some View {
        if worktree.isPrunable {
            Text("Missing on disk")
                .font(Stanford.caption(10))
                .foregroundStyle(.secondary)
        } else if let status = storage.statuses[worktree.path], status.decision.suggestRemoval {
            HStack(spacing: 4) {
                Text("Merged · idle \(WorktreeStorageFormat.duration(status.idle ?? 0)) ·")
                    .foregroundStyle(.secondary)
                Button("Remove", action: onRemove)
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.lagunita)
            }
            .font(Stanford.caption(10))
        }
    }
}
