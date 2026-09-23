import Foundation

enum WorktreeReclaimMode: String, Equatable, Sendable {
    /// Triggered by ASTRA (launch, a finished task, a recheck). Conservative.
    case automatic
    /// The user pressed Reclaim.
    case manual
}

enum WorktreeMergeState: Equatable, Sendable {
    case merged
    case notMerged
    /// A lookup failed or was skipped. Never suggests removal.
    case unknown(String)
}

struct WorktreeReclaimThresholds: Equatable, Sendable {
    var reclaimAfter: TimeInterval
    var suggestRemovalAfter: TimeInterval

    static let standard = WorktreeReclaimThresholds(
        reclaimAfter: 48 * 60 * 60,
        suggestRemovalAfter: 7 * 24 * 60 * 60
    )
}

/// Everything the policy needs, gathered by the service. Pure data.
struct WorktreeReclaimInput: Equatable, Sendable {
    var worktree: GitWorktreeInfo
    /// The workspace's own root, which can itself be a linked worktree.
    /// Automatic mode keeps it like the primary checkout.
    var isWorkspaceRoot = false
    var artifactBytes: Int64
    var lastActivity: Date?
    var buildSignal: WorktreeBuildSignal?
    /// Nil when not resolved; treated as unknown.
    var mergeState: WorktreeMergeState?
    /// Nil when unknown; treated as dirty.
    var isDirty: Bool?
    /// Why a task holds this worktree, if one does.
    var inUse: String?
    var mode: WorktreeReclaimMode
    var thresholds: WorktreeReclaimThresholds = .standard
    var now: Date
}

struct WorktreeReclaimDecision: Equatable, Sendable {
    var reclaimArtifacts: Bool
    var suggestRemoval: Bool
    /// Human-readable: why the artifacts are kept, or why they go.
    var reason: String
    /// When time alone can change the answer, so automatic mode can look
    /// again then instead of polling.
    var recheckAt: Date?
}

/// Decides what may happen to a worktree's build artifacts, and whether to
/// suggest removing the worktree. Pure: no I/O, no clock, no globals.
///
/// Artifacts are never source, so an idle *dirty* worktree still has its
/// artifacts reclaimed. Removing a worktree is only ever *suggested*, and only
/// for a merged, clean, unused, stale linked worktree.
enum WorktreeReclaimPolicy {
    static func decide(_ input: WorktreeReclaimInput) -> WorktreeReclaimDecision {
        let suggest = suggestsRemoval(input)
        func keep(_ reason: String, recheckAt: Date? = nil) -> WorktreeReclaimDecision {
            WorktreeReclaimDecision(reclaimArtifacts: false, suggestRemoval: suggest, reason: reason, recheckAt: recheckAt)
        }

        if input.worktree.isLocked { return keep("Locked") }
        if input.worktree.isPrunable { return keep("Missing on disk") }
        if let inUse = input.inUse { return keep(inUse) }
        if let signal = input.buildSignal {
            return keep(signal.summary.capitalizedFirst, recheckAt: input.now.addingTimeInterval(WorktreeActivityProbe.recentWriteWindow))
        }
        if input.mode == .automatic, input.worktree.isPrimary { return keep("Primary checkout") }
        if input.mode == .automatic, input.isWorkspaceRoot { return keep("Workspace checkout") }
        guard input.artifactBytes > 0 else { return keep("No build artifacts") }

        switch input.mode {
        case .manual:
            return WorktreeReclaimDecision(reclaimArtifacts: true, suggestRemoval: suggest, reason: "Reclaim requested", recheckAt: nil)
        case .automatic:
            guard let lastActivity = input.lastActivity else { return keep("Last activity unknown") }
            let idle = input.now.timeIntervalSince(lastActivity)
            guard idle >= input.thresholds.reclaimAfter else {
                return keep(
                    "Active \(WorktreeStorageFormat.duration(idle)) ago",
                    recheckAt: lastActivity.addingTimeInterval(input.thresholds.reclaimAfter)
                )
            }
            return WorktreeReclaimDecision(
                reclaimArtifacts: true,
                suggestRemoval: suggest,
                reason: "Idle \(WorktreeStorageFormat.duration(idle))",
                recheckAt: nil
            )
        }
    }

    /// True when the worktree would be suggested for removal once it proves
    /// clean and merged. Those two checks cost git and network calls, so
    /// callers make them only for candidates.
    static func isRemovalCandidate(_ input: WorktreeReclaimInput) -> Bool {
        let worktree = input.worktree
        guard !worktree.isPrimary, !input.isWorkspaceRoot, !worktree.isLocked, !worktree.isPrunable,
              input.inUse == nil, input.buildSignal == nil,
              let lastActivity = input.lastActivity else { return false }
        return input.now.timeIntervalSince(lastActivity) >= input.thresholds.suggestRemovalAfter
    }

    private static func suggestsRemoval(_ input: WorktreeReclaimInput) -> Bool {
        isRemovalCandidate(input) && input.isDirty == false && input.mergeState == .merged
    }
}

/// Shared wording for sizes and durations, so the policy's reasons and the
/// panel read the same.
enum WorktreeStorageFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "45 min", "5 h", "9 d".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
