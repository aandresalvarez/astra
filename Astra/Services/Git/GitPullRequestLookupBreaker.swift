import Foundation
import ASTRACore

/// How a failed `gh pr list` lookup should affect future polling.
enum GitPullRequestLookupFailureKind: Equatable, Sendable {
    /// The credential itself was rejected — SAML SSO enforcement, HTTP 401, a
    /// signed-out `gh`. No amount of retrying succeeds until the user
    /// re-authorizes, so polling must stop.
    case authorization(String)
    /// Everything else: connection resets, DNS/TCP timeouts, unreadable output.
    /// The next poll may well succeed, so polling must continue.
    case transient

    /// Classifies the verbatim `gh` stderr that `GitService` wraps into
    /// `GitHubPullRequestLookupResult.unavailable`. Reuses the shared
    /// `GitHubCLIError` matchers so the panel, the capability probe and the
    /// repair coordinator all agree on what "auth failure" means.
    static func classify(_ detail: String) -> GitPullRequestLookupFailureKind {
        let error = GitHubCLIError.classify(detail)
        switch error {
        case .authorizationRequired, .notAuthenticated:
            return .authorization(error.localizedDescription)
        case .notInstalled, .commandFailed:
            return .transient
        }
    }
}

/// Suppresses polled pull-request lookups for a (branch, repository) pair whose
/// last `gh pr list` failed on authorization.
///
/// The repository panel refreshes every 30s behind a 60s time throttle, so an
/// unauthorized credential used to re-spawn the same doomed ~0.9s subprocess
/// every 60–90s indefinitely — 524 identical SAML failures over 11.2 hours in
/// one recorded session. Only auth-class failures open the breaker; transient
/// network errors stay retryable so a real open pull request is never hidden
/// behind a stale "no PR" state.
struct GitPullRequestLookupBreaker: Equatable, Sendable {
    /// How long a rejected credential is trusted to stay rejected. Long enough
    /// that an unattended panel stops polling, short enough that a user who
    /// fixed access elsewhere recovers without touching the panel.
    static let authCooldown: TimeInterval = 900
    /// Foregrounding re-probes only once the breaker has been open this long,
    /// so frequent app switching cannot turn a paused poll back into a busy one.
    static let foregroundRearmDelay: TimeInterval = 60

    private(set) var openedAt: Date?
    private(set) var reason: String?
    private(set) var branch: String?
    private(set) var repoPath: String?

    var isOpen: Bool { openedAt != nil }

    /// True when a polled lookup for this exact branch and repository should be
    /// skipped. A different branch or repository always probes: the breaker
    /// records where the failure happened, not a global outage.
    func shouldSkip(branch: String, repoPath: String, now: Date = Date()) -> Bool {
        guard let openedAt, self.branch == branch, self.repoPath == repoPath else { return false }
        return now.timeIntervalSince(openedAt) < Self.authCooldown
    }

    /// Records a failed lookup and reports how it was classified. A failed
    /// half-open probe re-stamps `openedAt`, so the cooldown restarts instead of
    /// letting every subsequent poll through.
    @discardableResult
    mutating func recordFailure(
        detail: String,
        branch: String,
        repoPath: String,
        now: Date = Date()
    ) -> GitPullRequestLookupFailureKind {
        let kind = GitPullRequestLookupFailureKind.classify(detail)
        switch kind {
        case let .authorization(message):
            openedAt = now
            reason = message
            self.branch = branch
            self.repoPath = repoPath
        case .transient:
            reset()
        }
        return kind
    }

    mutating func recordSuccess() {
        reset()
    }

    /// Re-probes on app activation or panel re-appearance, the strongest
    /// *ambient* signal that the user just authorized in the browser. The
    /// delay keeps app-switching (or rail churn) from turning a paused poll
    /// back into the 90s failure poll this breaker exists to stop.
    mutating func rearmAfterForeground(now: Date = Date()) {
        guard let openedAt, now.timeIntervalSince(openedAt) >= Self.foregroundRearmDelay else { return }
        reset()
    }

    /// True when a repaired GitHub repository access covers the checkout this
    /// breaker is holding open. The capability rail repairs the workspace root
    /// while the panel may be polling a nested repository or a worktree under
    /// it, so an ancestor (or descendant) directory counts as the same repair.
    func coversRepairedDirectory(_ directory: String) -> Bool {
        guard let repoPath else { return false }
        let repaired = WorkspacePathPresentation.standardizedPath(directory)
        let held = WorkspacePathPresentation.standardizedPath(repoPath)
        guard !repaired.isEmpty, !held.isEmpty else { return false }
        return repaired == held
            || held.hasPrefix(repaired + "/")
            || repaired.hasPrefix(held + "/")
    }

    mutating func reset() {
        openedAt = nil
        reason = nil
        branch = nil
        repoPath = nil
    }

    #if DEBUG
    /// Ages an open breaker so tests can drive `rearmAfterForeground` through
    /// the production call sites instead of sleeping out `foregroundRearmDelay`.
    mutating func backdateOpenedAtForTesting(by interval: TimeInterval) {
        guard let openedAt else { return }
        self.openedAt = openedAt.addingTimeInterval(-interval)
    }
    #endif
}
