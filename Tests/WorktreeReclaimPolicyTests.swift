import Foundation
import Testing
@testable import ASTRA

/// The decision table from docs/specs/2026-09-23-worktree-storage-hygiene.md
/// §5, one case per row plus the spec's edge cases. Pure: no I/O.
@Suite("Worktree Reclaim Policy")
struct WorktreeReclaimPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * hour

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let input: WorktreeReclaimInput
        let reclaims: Bool
        let suggestsRemoval: Bool
        let reason: String

        var testDescription: String { name }
    }

    private static func worktree(primary: Bool = false, locked: Bool = false, prunable: Bool = false) -> GitWorktreeInfo {
        GitWorktreeInfo(
            path: primary ? "/repos/app" : "/worktrees/app/feature",
            branch: primary ? "main" : "feature",
            head: "0123abcd",
            isPrimary: primary,
            isDetached: false,
            isLocked: locked,
            isPrunable: prunable
        )
    }

    /// An idle linked worktree with artifacts, in automatic mode.
    private static func input(
        _ worktree: GitWorktreeInfo = worktree(),
        idle: TimeInterval = 3 * day,
        mode: WorktreeReclaimMode = .automatic,
        change: (inout WorktreeReclaimInput) -> Void = { _ in }
    ) -> WorktreeReclaimInput {
        var input = WorktreeReclaimInput(
            worktree: worktree,
            artifactBytes: 3_000_000_000,
            lastActivity: now.addingTimeInterval(-idle),
            mode: mode,
            now: now
        )
        change(&input)
        return input
    }

    static let rows: [Case] = [
        Case(name: "locked worktree is kept",
             input: input(worktree(locked: true)), reclaims: false, suggestsRemoval: false, reason: "Locked"),
        Case(name: "prunable worktree is kept and reads as missing",
             input: input(worktree(prunable: true)), reclaims: false, suggestsRemoval: false, reason: "Missing on disk"),
        Case(name: "worktree held by a task is kept",
             input: input { $0.inUse = "In use by task “Fix login”" },
             reclaims: false, suggestsRemoval: false, reason: "In use by task “Fix login”"),
        Case(name: "build in progress is kept",
             input: input { $0.buildSignal = .swiftPMLockHeld(lockPath: "/tmp/x.lock") },
             reclaims: false, suggestsRemoval: false, reason: "Build in progress (SwiftPM holds its lock)"),
        Case(name: "primary is kept in automatic mode",
             input: input(worktree(primary: true)), reclaims: false, suggestsRemoval: false, reason: "Primary checkout"),
        Case(name: "idle past the threshold is reclaimed",
             input: input(idle: 3 * day), reclaims: true, suggestsRemoval: false, reason: "Idle 3 d"),
        Case(name: "manual mode reclaims a recently active worktree",
             input: input(idle: hour, mode: .manual), reclaims: true, suggestsRemoval: false, reason: "Reclaim requested"),
        Case(name: "merged, clean, unused and stale also suggests removal",
             input: input(idle: 9 * day) { $0.mergeState = .merged; $0.isDirty = false },
             reclaims: true, suggestsRemoval: true, reason: "Idle 9 d"),

        // Edge cases the spec names.
        Case(name: "idle 47 h is kept",
             input: input(idle: 47 * hour), reclaims: false, suggestsRemoval: false, reason: "Active 47 h ago"),
        Case(name: "idle 49 h is reclaimed",
             input: input(idle: 49 * hour), reclaims: true, suggestsRemoval: false, reason: "Idle 2 d"),
        Case(name: "dirty and idle reclaims artifacts but suggests nothing",
             input: input(idle: 9 * day) { $0.mergeState = .merged; $0.isDirty = true },
             reclaims: true, suggestsRemoval: false, reason: "Idle 9 d"),
        Case(name: "unknown cleanliness suggests nothing",
             input: input(idle: 9 * day) { $0.mergeState = .merged; $0.isDirty = nil },
             reclaims: true, suggestsRemoval: false, reason: "Idle 9 d"),
        Case(name: "unknown merge state suggests nothing",
             input: input(idle: 9 * day) { $0.mergeState = .unknown("gh unavailable"); $0.isDirty = false },
             reclaims: true, suggestsRemoval: false, reason: "Idle 9 d"),
        Case(name: "unmerged suggests nothing",
             input: input(idle: 9 * day) { $0.mergeState = .notMerged; $0.isDirty = false },
             reclaims: true, suggestsRemoval: false, reason: "Idle 9 d"),
        Case(name: "merged and clean but not yet stale suggests nothing",
             input: input(idle: 6 * day) { $0.mergeState = .merged; $0.isDirty = false },
             reclaims: true, suggestsRemoval: false, reason: "Idle 6 d"),
        Case(name: "manual mode reclaims the primary",
             input: input(worktree(primary: true), idle: hour, mode: .manual),
             reclaims: true, suggestsRemoval: false, reason: "Reclaim requested"),
        Case(name: "primary is never suggested for removal",
             input: input(worktree(primary: true), idle: 30 * day, mode: .manual) { $0.mergeState = .merged; $0.isDirty = false },
             reclaims: true, suggestsRemoval: false, reason: "Reclaim requested"),
        Case(name: "workspace root is kept like the primary",
             input: input { $0.isWorkspaceRoot = true }, reclaims: false, suggestsRemoval: false, reason: "Primary checkout"),
        Case(name: "manual mode still keeps a worktree held by a task",
             input: input(mode: .manual) { $0.inUse = "In use by task “A”" },
             reclaims: false, suggestsRemoval: false, reason: "In use by task “A”"),
        Case(name: "manual mode still keeps a build in progress",
             input: input(mode: .manual) { $0.buildSignal = .recentlyModified(now) },
             reclaims: false, suggestsRemoval: false, reason: "Build in progress (written in the last 15 minutes)"),
        Case(name: "nothing to reclaim is kept",
             input: input { $0.artifactBytes = 0 }, reclaims: false, suggestsRemoval: false, reason: "No build artifacts"),
        Case(name: "unknown activity is kept in automatic mode",
             input: input { $0.lastActivity = nil }, reclaims: false, suggestsRemoval: false, reason: "Last activity unknown"),
        Case(name: "a kept worktree can still be suggested for removal",
             input: input(idle: 9 * day) { $0.mergeState = .merged; $0.isDirty = false; $0.artifactBytes = 0 },
             reclaims: false, suggestsRemoval: true, reason: "No build artifacts"),
    ]

    @Test("Decision table", arguments: rows)
    func decisionTable(_ row: Case) {
        let decision = WorktreeReclaimPolicy.decide(row.input)
        #expect(decision.reclaimArtifacts == row.reclaims)
        #expect(decision.suggestRemoval == row.suggestsRemoval)
        #expect(decision.reason == row.reason)
    }

    @Test("A worktree that isn't idle yet asks to be rechecked at the threshold")
    func recheckAtThreshold() {
        let input = Self.input(idle: 47 * Self.hour)
        let decision = WorktreeReclaimPolicy.decide(input)
        #expect(decision.recheckAt == input.lastActivity?.addingTimeInterval(48 * Self.hour))
    }

    @Test("A build in progress asks to be rechecked after the recent-write window")
    func recheckAfterBuild() {
        let decision = WorktreeReclaimPolicy.decide(Self.input { $0.buildSignal = .swiftPMProcessAlive(pid: 42) })
        #expect(decision.recheckAt == Self.now.addingTimeInterval(WorktreeActivityProbe.recentWriteWindow))
    }

    @Test("Removal candidates exclude everything that can't be suggested before git is asked")
    func removalCandidates() {
        #expect(WorktreeReclaimPolicy.isRemovalCandidate(Self.input(idle: 8 * Self.day)))
        #expect(!WorktreeReclaimPolicy.isRemovalCandidate(Self.input(idle: 6 * Self.day)))
        #expect(!WorktreeReclaimPolicy.isRemovalCandidate(Self.input(Self.worktree(primary: true), idle: 8 * Self.day)))
        #expect(!WorktreeReclaimPolicy.isRemovalCandidate(Self.input(Self.worktree(locked: true), idle: 8 * Self.day)))
        #expect(!WorktreeReclaimPolicy.isRemovalCandidate(Self.input(idle: 8 * Self.day) { $0.inUse = "In use" }))
    }

    @Test("Thresholds follow the settings")
    func thresholdsFollowSettings() {
        let defaults = InMemoryDefaults()
        #expect(WorktreeStorageSettings.thresholds(in: defaults) == .standard)
        WorktreeStorageSettings.setIdleThresholdHours(24, in: defaults)
        let input = Self.input(idle: 25 * Self.hour) { $0.thresholds = WorktreeStorageSettings.thresholds(in: defaults) }
        #expect(WorktreeReclaimPolicy.decide(input).reclaimArtifacts)
    }

    @Test("Durations read as minutes, hours, then days")
    func durations() {
        #expect(WorktreeStorageFormat.duration(30) == "1 min")
        #expect(WorktreeStorageFormat.duration(45 * 60) == "45 min")
        #expect(WorktreeStorageFormat.duration(5 * Self.hour) == "5 h")
        #expect(WorktreeStorageFormat.duration(47 * Self.hour) == "47 h")
        #expect(WorktreeStorageFormat.duration(9 * Self.day) == "9 d")
    }
}
