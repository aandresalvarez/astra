import Foundation
import Testing
import ASTRAGitContracts
@testable import ASTRA

@Suite("Typed Git Pull Request Publication")
struct GitPullRequestPublishServiceTests {
    private static let baseSHA = String(repeating: "a", count: 40)
    private static let commitSHA = String(repeating: "b", count: 40)
    private static let repositoryPath = "/Users/test/astra-publish-repo"

    private final class FakeGit: GitRepositoryOperating {
        var headSHA = GitPullRequestPublishServiceTests.baseSHA
        var refSHAs: [String: String] = [
            "origin/main": GitPullRequestPublishServiceTests.baseSHA
        ]
        var currentBranch = "main"
        var statusFiles = [
            GitStatusFile(relativePath: "Sources/Feature.swift", status: "M", isStaged: false),
            GitStatusFile(relativePath: "Tests/FeatureTests.swift", status: "?", isStaged: false)
        ]
        var diffByPath = [
            "Sources/Feature.swift": "diff --git a/Sources/Feature.swift b/Sources/Feature.swift\n+feature",
            "Tests/FeatureTests.swift": "diff --git a/Tests/FeatureTests.swift b/Tests/FeatureTests.swift\n+test"
        ]
        var lookupResult: GitHubPullRequestLookupResult = .none
        var remoteURL: String? = "https://github.com/example/repo"
        var existingBranches: Set<String> = []
        var indexAvailable = true
        var calls: [String] = []
        var createPullRequestFailureCount = 0
        var createPullRequestURL = "https://github.com/example/repo/pull/42"
        var createPullRequestDraftValues: [Bool] = []

        func acquireIndexGuard() -> Bool {
            calls.append("acquire")
            return indexAvailable
        }

        func releaseIndexGuard() { calls.append("release") }
        func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] { [] }
        func getCurrentBranch(at repoPath: String) async -> String { currentBranch }

        func getCommitSHA(_ ref: String, at repoPath: String) async -> String? {
            if ref == "HEAD" { return headSHA }
            return refSHAs[ref]
        }

        func getLocalBranches(at repoPath: String) async -> [String] { Array(existingBranches) }
        func checkoutBranch(_ branch: String, at repoPath: String) async throws { currentBranch = branch }

        func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws {
            calls.append("branch:\(branch):\(base ?? "")")
            currentBranch = branch
            existingBranches.insert(branch)
            refSHAs[branch] = headSHA
        }

        func getStatusFiles(at repoPath: String) async -> [GitStatusFile] { statusFiles }

        func stageFile(_ file: GitStatusFile, at repoPath: String) async throws {
            calls.append("stage:\(file.relativePath)")
        }

        func stageAll(at repoPath: String) async throws {}
        func unstageFile(_ file: GitStatusFile, at repoPath: String) async throws {}
        func unstageAll(at repoPath: String) async throws {}
        func applyDiffPatchToIndex(_ patch: String, at repoPath: String, reverse: Bool) async throws {}

        func commit(message: String, at repoPath: String) async throws {
            calls.append("commit:\(message)")
            headSHA = GitPullRequestPublishServiceTests.commitSHA
            refSHAs[currentBranch] = headSHA
        }

        func pullRebase(at repoPath: String) async throws {}
        func push(at repoPath: String) async throws {}

        func pushSetUpstream(branch: String, remote: String, at repoPath: String) async throws {
            calls.append("push:\(remote):\(branch)")
            refSHAs["\(remote)/\(branch)"] = headSHA
        }

        func hasRemote(at repoPath: String) async -> Bool { remoteURL != nil }

        func lookupOpenPullRequest(
            repoPath: String,
            head: String,
            ghPathOverride: String?
        ) async -> GitHubPullRequestLookupResult {
            calls.append("lookup:\(head)")
            return lookupResult
        }

        func lookupPullRequestComments(
            repoPath: String,
            pullRequest: GitHubPullRequestRef,
            ghPathOverride: String?
        ) async -> GitHubPullRequestCommentLookupResult { .unavailable("unused") }

        func lookupPullRequestChecks(
            repoPath: String,
            pullRequest: GitHubPullRequestRef,
            ghPathOverride: String?
        ) async -> GitHubPullRequestCheckLookupResult { .unavailable("unused") }

        func getUnpushedCommitCount(at repoPath: String) async -> Int { 0 }
        func getAheadBehind(at repoPath: String) async -> (ahead: Int, behind: Int)? { (0, 0) }
        func hasUpstream(at repoPath: String) async -> Bool { false }
        func getDefaultRemote(at repoPath: String) async -> String? { "origin" }
        func getStagedDiff(at repoPath: String, limit: Int) async -> String { "" }

        func getFileDiff(at repoPath: String, file: GitStatusFile, limit: Int) async -> GitFileDiff {
            let value = diffByPath[file.relativePath] ?? ""
            return GitFileDiff(
                id: file.id,
                file: file,
                kind: file.isStaged ? .staged : (file.isUntracked ? .untracked : .unstaged),
                diff: value,
                isTruncated: value.utf8.count > limit,
                message: nil
            )
        }

        func getRecentCommitSubjects(at repoPath: String, count: Int) async -> [String] { [] }
        func getDefaultBaseBranch(at repoPath: String, remote: String?) async -> String { "origin/main" }

        func getBranchLog(
            at repoPath: String,
            base: String,
            branch: String,
            limit: Int,
            maxBytes: Int
        ) async -> String { "" }

        func getBranchDiffStat(at repoPath: String, base: String, branch: String, maxBytes: Int) async -> String { "" }
        func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int) { (0, 0) }
        func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo] { [] }
        func localBranchExists(_ branch: String, at repoPath: String) async -> Bool { existingBranches.contains(branch) }

        func addWorktree(
            repoPath: String,
            branch: String,
            createBranch: Bool,
            base: String?,
            worktreesRoot: String
        ) async throws -> String { repoPath }

        func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {}
        func getRemoteURL(at repoPath: String, remote: String?) async -> String? { remoteURL }

        func createPullRequest(
            repoPath: String,
            base: String,
            head: String,
            title: String,
            body: String,
            ghPathOverride: String?
        ) async throws -> String {
            try await createPullRequest(
                repoPath: repoPath,
                base: base,
                head: head,
                title: title,
                body: body,
                isDraft: false,
                ghPathOverride: ghPathOverride
            )
        }

        func createPullRequest(
            repoPath: String,
            base: String,
            head: String,
            title: String,
            body: String,
            isDraft: Bool,
            ghPathOverride: String?
        ) async throws -> String {
            calls.append("pr:\(base):\(head)")
            createPullRequestDraftValues.append(isDraft)
            if createPullRequestFailureCount > 0 {
                createPullRequestFailureCount -= 1
                throw NSError(domain: "FakeGit", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "temporary GitHub failure"
                ])
            }
            return createPullRequestURL
        }

        func normalizeBaseBranch(_ raw: String) -> String { GitService.normalizeBaseBranch(raw) }
    }

    private func request(
        authorization: GitPullRequestPublishAuthorizationRequirement = .explicitApproval,
        paths: [String] = ["Tests/FeatureTests.swift", "Sources/Feature.swift"]
    ) -> GitPullRequestPublishRequest {
        GitPullRequestPublishRequest(
            repositoryPath: Self.repositoryPath,
            baseBranch: "origin/main",
            headBranch: "feature/typed-publish",
            expectedHeadSHA: Self.baseSHA,
            selectedPaths: paths,
            commitMessage: "Add typed publication",
            pullRequestTitle: "Add typed publication",
            pullRequestBody: "Creates a deterministic draft PR.",
            authorizationRequirement: authorization
        )
    }

    private func service(
        git: FakeGit,
        store: InMemoryGitPullRequestPublishCheckpointStore = .init()
    ) -> GitPullRequestPublishService {
        GitPullRequestPublishService(
            git: git,
            checkpointStore: store,
            now: { Date(timeIntervalSince1970: 1234) }
        )
    }

    @Test("preflight normalizes scope and produces a deterministic approval id")
    func deterministicPreflight() async throws {
        let git = FakeGit()
        let publisher = service(git: git)

        let first = try await publisher.prepare(request(paths: [
            "Tests/FeatureTests.swift",
            "Sources/Feature.swift",
            "Sources/Feature.swift"
        ]))
        let second = try await publisher.prepare(request(paths: [
            "Sources/Feature.swift",
            "Tests/FeatureTests.swift"
        ]))

        #expect(first.proposalID == second.proposalID)
        #expect(first.selectedPaths == ["Sources/Feature.swift", "Tests/FeatureTests.swift"])
        #expect(first.selectedFileStates.count == 2)
        #expect(first.baseBranch == "main")
        #expect(first.baseSHA == Self.baseSHA)
        #expect(first.requiresExplicitApproval)
        #expect(first.isDraft)
    }

    @Test("Ask publication requires approval bound to the proposal")
    func explicitApprovalIsRequired() async throws {
        let git = FakeGit()
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request())

        do {
            _ = try await publisher.publish(proposal)
            Issue.record("Publication unexpectedly proceeded without approval")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .approvalRequired(proposal.proposalID))
        }

        #expect(!git.calls.contains { $0.hasPrefix("branch:") })
        #expect(!git.calls.contains { $0.hasPrefix("pr:") })
    }

    @Test("approved publication stages only selected paths and returns a draft receipt")
    func approvedPublicationSucceeds() async throws {
        let git = FakeGit()
        let store = InMemoryGitPullRequestPublishCheckpointStore()
        let publisher = service(git: git, store: store)
        let proposal = try await publisher.prepare(request())

        let receipt = try await publisher.publish(
            proposal,
            approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
        )

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(receipt.pullRequestNumber == 42)
        #expect(receipt.pullRequestURL == "https://github.com/example/repo/pull/42")
        #expect(receipt.isDraft)
        #expect(receipt.source == .created)
        #expect(receipt.verification == .createResponseURL)
        #expect(receipt.completedAt == Date(timeIntervalSince1970: 1234))
        #expect(git.calls.filter { $0.hasPrefix("branch:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("pr:") }.count == 1)
        #expect(git.createPullRequestDraftValues == [true])
        #expect(await store.checkpoint(for: proposal.proposalID) == nil)
    }

    @Test("file drift after approval fails before branch creation")
    func fileDriftFailsClosed() async throws {
        let git = FakeGit()
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request())
        git.diffByPath["Sources/Feature.swift"] = "different content"

        do {
            _ = try await publisher.publish(
                proposal,
                approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
            )
            Issue.record("Drifted content unexpectedly published")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .proposalChanged)
        }

        #expect(!git.calls.contains { $0.hasPrefix("branch:") })
        #expect(git.calls.filter { $0 == "acquire" }.count == 1)
        #expect(git.calls.filter { $0 == "release" }.count == 1)
    }

    @Test("unselected staged files fail preflight")
    func unrelatedStagedFileFailsPreflight() async throws {
        let git = FakeGit()
        git.statusFiles.append(GitStatusFile(
            relativePath: "Notes/private.txt",
            status: "M",
            isStaged: true
        ))

        do {
            _ = try await service(git: git).prepare(request())
            Issue.record("Unselected staged content unexpectedly passed preflight")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .unrelatedStagedChanges(["Notes/private.txt"]))
        }
    }

    @Test("existing PR is idempotent and receipt uses the remote head SHA")
    func existingPullRequestReturnsExactRemoteHeadReceipt() async throws {
        let git = FakeGit()
        git.lookupResult = .found(GitHubPullRequestRef(
            number: 17,
            url: "https://github.com/example/repo/pull/17",
            title: "Existing",
            isDraft: true,
            state: "OPEN"
        ))
        git.refSHAs["origin/feature/typed-publish"] = Self.commitSHA
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request())

        let receipt = try await publisher.publish(proposal)

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(receipt.commitSHA != proposal.expectedHeadSHA)
        #expect(receipt.pullRequestNumber == 17)
        #expect(receipt.source == .existing)
        #expect(receipt.verification == .existingPullRequestLookup)
        #expect(!git.calls.contains("acquire"))
        #expect(!git.calls.contains { $0.hasPrefix("pr:") })
    }

    @Test("retry after PR failure resumes from pushed checkpoint without duplicate Git mutations")
    func pullRequestFailureRetryIsIdempotent() async throws {
        let git = FakeGit()
        git.createPullRequestFailureCount = 1
        let store = InMemoryGitPullRequestPublishCheckpointStore()
        let publisher = service(git: git, store: store)
        let proposal = try await publisher.prepare(request())
        let approval = GitPullRequestPublishApproval(proposalID: proposal.proposalID)

        do {
            _ = try await publisher.publish(proposal, approval: approval)
            Issue.record("First PR attempt unexpectedly succeeded")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .operationFailed(
                phase: .createPullRequest,
                message: "temporary GitHub failure"
            ))
        }
        #expect(await store.checkpoint(for: proposal.proposalID)?.state == .pushed)

        let receipt = try await publisher.publish(proposal, approval: approval)

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(git.calls.filter { $0.hasPrefix("branch:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("pr:") }.count == 2)
        #expect(await store.checkpoint(for: proposal.proposalID) == nil)
    }
}
