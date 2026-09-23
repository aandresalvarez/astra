import Foundation
import Testing
@testable import ASTRA

/// Merged / not merged / unknown, for the removal suggestion only. ASTRA
/// squash-merges, so a merged pull request is required evidence, but it only
/// counts when it actually carries the worktree's HEAD.
@Suite("Worktree Merge State Resolver")
@MainActor
struct WorktreeMergeStateResolverTests {
    private let repo = "/repos/app"
    private let head = "aaa111"

    private func worktree(branch: String? = "feature") -> GitWorktreeInfo {
        GitWorktreeInfo(
            path: "/worktrees/app/feature",
            branch: branch,
            head: head,
            isPrimary: false,
            isDetached: branch == nil,
            isLocked: false,
            isPrunable: false
        )
    }

    private func merged(headRefOid: String) -> GitMergedPullRequestLookupResult {
        .found(GitMergedPullRequest(number: 413, url: "https://github.com/o/r/pull/413", headRefOid: headRefOid, mergedAt: nil))
    }

    @Test("A fast-forward merged branch is merged without asking GitHub")
    func fastForwardMerged() async {
        let git = StubWorktreeGit()
        git.ancestry["\(head)>origin/main"] = .ancestor
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .merged)
        #expect(git.lookupCalls.isEmpty)
    }

    @Test("A squash-merged branch is merged when its PR's head is the worktree's HEAD")
    func squashMerged() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = merged(headRefOid: head)
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .merged)
        #expect(git.lookupCalls == ["feature"])
    }

    @Test("A PR head that contains the worktree's HEAD counts as merged")
    func pullRequestHeadDescends() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = merged(headRefOid: "bbb222")
        git.ancestry["\(head)>bbb222"] = .ancestor
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .merged)
    }

    @Test("Commits added after the merge make the branch not merged")
    func commitsAfterMerge() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = merged(headRefOid: "bbb222")
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .notMerged)
    }

    @Test("An unmerged branch without a merged PR is not merged")
    func unmerged() async {
        let git = StubWorktreeGit()
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .notMerged)
    }

    @Test("A PR head missing from the local objects is unknown")
    func missingPullRequestHead() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = merged(headRefOid: "ccc333")
        git.ancestry["\(head)>ccc333"] = .unknown("fatal: Not a valid commit name ccc333")
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .unknown("fatal: Not a valid commit name ccc333"))
    }

    @Test("A lookup failure is unknown, and the rest of the pass doesn't ask GitHub again")
    func lookupFailure() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = .unavailable("error connecting to api.github.com")
        let resolver = WorktreeMergeStateResolver(git: git)
        resolver.beginPass()
        #expect(await resolver.resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
            == .unknown("error connecting to api.github.com"))
        #expect(await resolver.resolve(worktree: worktree(branch: "other"), repoPath: repo, defaultBranch: "origin/main")
            == .unknown("GitHub lookup unavailable"))
        #expect(git.lookupCalls == ["feature"])

        // A transient failure doesn't open the breaker: the next pass asks again.
        resolver.beginPass()
        _ = await resolver.resolve(worktree: worktree(branch: "other"), repoPath: repo, defaultBranch: "origin/main")
        #expect(git.lookupCalls == ["feature", "other"])
    }

    @Test("An authorization failure pauses lookups for the whole repository")
    func authorizationFailure() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = .unavailable("HTTP 401: Bad credentials (https://api.github.com/graphql)")
        let resolver = WorktreeMergeStateResolver(git: git)
        resolver.beginPass()
        _ = await resolver.resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        resolver.beginPass()
        let state = await resolver.resolve(worktree: worktree(branch: "other"), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .unknown("GitHub lookups paused after an authorization failure"))
        #expect(git.lookupCalls == ["feature"])
    }

    @Test("A detached HEAD relies on ancestry alone")
    func detachedHead() async {
        let git = StubWorktreeGit()
        let state = await WorktreeMergeStateResolver(git: git).resolve(worktree: worktree(branch: nil), repoPath: repo, defaultBranch: "origin/main")
        #expect(state == .notMerged)
        #expect(git.lookupCalls.isEmpty)
    }

    @Test("An ancestry merge is rechecked, so a rewritten base is noticed")
    func ancestryIsNotCached() async {
        let git = StubWorktreeGit()
        git.ancestry["\(head)>origin/main"] = .ancestor
        let resolver = WorktreeMergeStateResolver(git: git)
        #expect(await resolver.resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main") == .merged)

        git.ancestry["\(head)>origin/main"] = .notAncestor
        #expect(await resolver.resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main") == .notMerged)
    }

    @Test("A confirmed merge is remembered for the same HEAD")
    func mergedIsCached() async {
        let git = StubWorktreeGit()
        git.mergedPullRequests["feature"] = merged(headRefOid: head)
        let resolver = WorktreeMergeStateResolver(git: git)
        _ = await resolver.resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main")
        let calls = git.ancestryCalls.count
        #expect(await resolver.resolve(worktree: worktree(), repoPath: repo, defaultBranch: "origin/main") == .merged)
        #expect(git.ancestryCalls.count == calls)
        #expect(git.lookupCalls == ["feature"])
    }
}

/// The new `GitService` reads against a real repository, and the merged-PR
/// lookup against a fake `gh`.
@Suite("Git Service Worktree Storage Reads")
struct GitServiceWorktreeStorageTests {
    @Test("isAncestor answers yes, no and unknown")
    func isAncestor() async throws {
        let fixture = try WorktreeStorageFixture("ancestry")
        defer { fixture.cleanUp() }
        let repo = try WorktreeStorageGit.makeRepository(in: fixture)
        let base = WorktreeStorageGit.head(of: repo)
        WorktreeStorageGit.run(["switch", "-q", "-c", "feature"], in: repo)
        try fixture.file("repo/Sources/App/extra.swift", bytes: 30)
        WorktreeStorageGit.run(["add", "."], in: repo)
        WorktreeStorageGit.run(["commit", "-q", "-m", "feature"], in: repo)
        let tip = WorktreeStorageGit.head(of: repo)

        #expect(await GitService.shared.isAncestor(base, of: tip, at: repo) == .ancestor)
        #expect(await GitService.shared.isAncestor(tip, of: "main", at: repo) == .notAncestor)
        guard case .unknown = await GitService.shared.isAncestor("0000000000000000000000000000000000000001", of: "main", at: repo) else {
            Issue.record("A missing commit must be unknown")
            return
        }
    }

    @Test("commitDate and hasUncommittedChanges read the checkout")
    func commitDateAndDirtiness() async throws {
        let fixture = try WorktreeStorageFixture("dirtiness")
        defer { fixture.cleanUp() }
        let repo = try WorktreeStorageGit.makeRepository(in: fixture)
        let date = try #require(await GitService.shared.commitDate(of: WorktreeStorageGit.head(of: repo), at: repo))
        #expect(abs(date.timeIntervalSinceNow) < 600)

        #expect(await GitService.shared.hasUncommittedChanges(at: repo) == false)
        try fixture.file("repo/.build/debug/App", bytes: 10)
        #expect(await GitService.shared.hasUncommittedChanges(at: repo) == false, "ignored artifacts aren't changes")
        try fixture.file("repo/notes.txt", bytes: 10)
        #expect(await GitService.shared.hasUncommittedChanges(at: repo) == true)
        #expect(await GitService.shared.hasUncommittedChanges(at: fixture.path("missing")) == nil)
    }

    @Test("The merged lookup asks gh for merged PRs and decodes the head commit")
    func mergedLookup() async throws {
        let fixture = try WorktreeStorageFixture("gh")
        defer { fixture.cleanUp() }
        let argsFile = fixture.path("gh-args.txt")
        let json = #"[{"number":414,"url":"https://github.com/o/r/pull/414","headRefOid":"45ee7b0d","mergedAt":"2026-09-23T17:32:36Z"}]"#
        let gh = try fakeGH(in: fixture, body: "printf '%s\\n' \"$@\" > '\(argsFile)'\nprintf '%s' '\(json)'\nexit 0")

        let result = await GitService.shared.lookupMergedPullRequest(repoPath: fixture.root.path, head: "feature", ghPathOverride: gh)

        #expect(result == .found(GitMergedPullRequest(
            number: 414, url: "https://github.com/o/r/pull/414", headRefOid: "45ee7b0d", mergedAt: "2026-09-23T17:32:36Z"
        )))
        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.starts(with: ["pr", "list", "--head", "feature", "--state", "merged"]))
    }

    @Test("No merged PR is none; a gh failure is unavailable")
    func mergedLookupEmptyAndFailure() async throws {
        let fixture = try WorktreeStorageFixture("gh")
        defer { fixture.cleanUp() }
        let empty = try fakeGH(in: fixture, name: "gh-empty", body: "printf '[]'\nexit 0")
        #expect(await GitService.shared.lookupMergedPullRequest(repoPath: fixture.root.path, head: "feature", ghPathOverride: empty) == .none)

        let failing = try fakeGH(in: fixture, name: "gh-fail", body: "echo 'HTTP 401: Bad credentials' >&2\nexit 1")
        guard case .unavailable = await GitService.shared.lookupMergedPullRequest(
            repoPath: fixture.root.path, head: "feature", ghPathOverride: failing
        ) else {
            Issue.record("A failing gh must be unavailable")
            return
        }
    }

    private func fakeGH(in fixture: WorktreeStorageFixture, name: String = "gh", body: String) throws -> String {
        let path = fixture.path(name)
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
