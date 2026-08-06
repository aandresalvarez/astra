import Foundation
import Testing
@testable import ASTRA

@Suite("Git Pull Request Lookup Breaker")
struct GitPullRequestLookupBreakerTests {
    /// Verbatim `gh pr list` stderr from the 524 identical production failures.
    private static let samlStderr = """
    GraphQL: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization. (repository) Authorize in your web browser: https://github.com/orgs/example/sso?authorization_request=ABC123
    """
    private static let branch = "feature/login"
    private static let repoPath = "/repos/example"

    private func openedBreaker(at now: Date = Date(timeIntervalSince1970: 1_000)) -> GitPullRequestLookupBreaker {
        var breaker = GitPullRequestLookupBreaker()
        breaker.recordFailure(
            detail: Self.samlStderr,
            branch: Self.branch,
            repoPath: Self.repoPath,
            now: now
        )
        return breaker
    }

    @Test("SAML enforcement stderr classifies as an authorization failure")
    func samlEnforcementIsAuthorizationFailure() {
        let kind = GitPullRequestLookupFailureKind.classify(Self.samlStderr)

        guard case let .authorization(message) = kind else {
            Issue.record("Expected an authorization failure, got \(kind)")
            return
        }
        #expect(message.contains("Repair access"))
        #expect(!message.contains("authorization_request"))
    }

    @Test("Network failures stay retryable")
    func networkFailuresStayRetryable() {
        // Both strings are verbatim from the same production session as the
        // SAML failures; they must never pause polling.
        let transientDetails = [
            "Post \"https://api.github.com/graphql\": read tcp 10.240.91.10:54034->140.82.116.5:443: read: connection reset by peer",
            "Post \"https://api.github.com/graphql\": dial tcp 140.82.116.6:443: i/o timeout"
        ]

        for detail in transientDetails {
            #expect(GitPullRequestLookupFailureKind.classify(detail) == .transient)

            var breaker = GitPullRequestLookupBreaker()
            let kind = breaker.recordFailure(detail: detail, branch: Self.branch, repoPath: Self.repoPath)
            #expect(kind == .transient)
            #expect(!breaker.isOpen)
            #expect(!breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath))
        }
    }

    @Test("A transient failure after an open breaker re-arms polling")
    func transientFailureClosesAnOpenBreaker() {
        var breaker = openedBreaker()
        #expect(breaker.isOpen)

        breaker.recordFailure(
            detail: "Post \"https://api.github.com/graphql\": dial tcp 140.82.116.6:443: i/o timeout",
            branch: Self.branch,
            repoPath: Self.repoPath
        )

        #expect(!breaker.isOpen)
    }

    @Test("HTTP 401 and not-logged-in stderr open the breaker")
    func rejectedCredentialsOpenTheBreaker() {
        let authDetails = [
            "HTTP 401: Bad credentials (https://api.github.com/graphql)",
            "To authenticate, please run gh auth login."
        ]

        for detail in authDetails {
            var breaker = GitPullRequestLookupBreaker()
            let kind = breaker.recordFailure(detail: detail, branch: Self.branch, repoPath: Self.repoPath)

            guard case .authorization = kind else {
                Issue.record("Expected an authorization failure for \(detail), got \(kind)")
                continue
            }
            #expect(breaker.isOpen)
            #expect(breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath))
        }
    }

    @Test("gh-not-installed stays transient")
    func missingGitHubCLIStaysTransient() {
        #expect(GitPullRequestLookupFailureKind.classify("GitHub CLI (gh) is not installed.") == .transient)
    }

    @Test("Open breaker suppresses same-branch polls until the cooldown elapses")
    func openBreakerSuppressesPollsForTheCooldown() {
        let openedAt = Date(timeIntervalSince1970: 1_000)
        let breaker = openedBreaker(at: openedAt)

        #expect(breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath, now: openedAt.addingTimeInterval(1)))
        #expect(breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath, now: openedAt.addingTimeInterval(899)))
        #expect(!breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath, now: openedAt.addingTimeInterval(901)))
    }

    @Test("Branch and repository changes re-arm the breaker")
    func branchAndRepositoryChangesProbeAgain() {
        let openedAt = Date(timeIntervalSince1970: 1_000)
        let breaker = openedBreaker(at: openedAt)
        let now = openedAt.addingTimeInterval(1)

        #expect(!breaker.shouldSkip(branch: "feature/other", repoPath: Self.repoPath, now: now))
        #expect(!breaker.shouldSkip(branch: Self.branch, repoPath: "/repos/other", now: now))
    }

    @Test("A failed half-open probe reopens the breaker")
    func failedHalfOpenProbeReopensTheBreaker() {
        let openedAt = Date(timeIntervalSince1970: 1_000)
        var breaker = openedBreaker(at: openedAt)
        let probedAt = openedAt.addingTimeInterval(901)
        #expect(!breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath, now: probedAt))

        breaker.recordFailure(
            detail: Self.samlStderr,
            branch: Self.branch,
            repoPath: Self.repoPath,
            now: probedAt
        )

        #expect(breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath, now: probedAt.addingTimeInterval(1)))
        #expect(!breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath, now: probedAt.addingTimeInterval(901)))
    }

    @Test("A successful lookup closes the breaker")
    func successClosesTheBreaker() {
        var breaker = openedBreaker()
        breaker.recordSuccess()

        #expect(!breaker.isOpen)
        #expect(!breaker.shouldSkip(branch: Self.branch, repoPath: Self.repoPath))
    }

    @Test("Foregrounding re-arms a settled breaker but ignores rapid app switching")
    func foregroundRearmIgnoresRapidAppSwitching() {
        let openedAt = Date(timeIntervalSince1970: 1_000)

        var switched = openedBreaker(at: openedAt)
        switched.rearmAfterForeground(now: openedAt.addingTimeInterval(5))
        #expect(switched.isOpen)

        var returned = openedBreaker(at: openedAt)
        returned.rearmAfterForeground(now: openedAt.addingTimeInterval(61))
        #expect(!returned.isOpen)
    }

    @Test("A repaired directory covers the held checkout, its parents, and its worktrees")
    func repairedDirectoryScoping() {
        let breaker = openedBreaker()

        // The capability rail repairs the workspace root; the panel may be
        // polling the repository itself or a checkout nested under it.
        #expect(breaker.coversRepairedDirectory(Self.repoPath))
        #expect(breaker.coversRepairedDirectory("/repos"))
        #expect(breaker.coversRepairedDirectory("/repos/example/worktrees/login"))
        #expect(breaker.coversRepairedDirectory("/repos/example/"))
        // A repair of some other organization's checkout says nothing about
        // this one, so the cooldown must survive it.
        #expect(!breaker.coversRepairedDirectory("/repos/example-two"))
        #expect(!breaker.coversRepairedDirectory("/other"))
        #expect(!breaker.coversRepairedDirectory(""))
        #expect(!GitPullRequestLookupBreaker().coversRepairedDirectory(Self.repoPath))
    }
}
