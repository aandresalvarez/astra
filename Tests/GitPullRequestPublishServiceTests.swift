import Foundation
import Testing
import ASTRAGitContracts
@testable import ASTRA

@Suite("Typed Git Pull Request Publication")
struct GitPullRequestPublishServiceTests {
    private static let baseSHA = String(repeating: "a", count: 40)
    private static let commitSHA = String(repeating: "b", count: 40)
    private static let reviewedTreeSHA = String(repeating: "c", count: 40)
    private static let repositoryPath = "/Users/test/astra-publish-repo"

    private actor FailingCheckpointStore: GitPullRequestPublishCheckpointStoring {
        func checkpoint(for proposalID: String) -> GitPullRequestPublishCheckpoint? { nil }

        func save(_ checkpoint: GitPullRequestPublishCheckpoint) throws {
            throw NSError(domain: "CheckpointStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "checkpoint write failed"
            ])
        }

        func removeCheckpoint(for proposalID: String) {}
    }

    private final class FakeGit: GitRepositoryOperating {
        var headSHA = GitPullRequestPublishServiceTests.baseSHA
        var refSHAs: [String: String] = [
            "origin/main": GitPullRequestPublishServiceTests.baseSHA
        ]
        var remoteRefSHAs: [String: String] = [
            "origin/main": GitPullRequestPublishServiceTests.baseSHA
        ]
        var remoteLookupFailure: String?
        var currentBranch = "main"
        var statusFiles = [
            GitStatusFile(relativePath: "Sources/Feature.swift", status: "M", isStaged: false),
            GitStatusFile(relativePath: "Tests/FeatureTests.swift", status: "?", isStaged: false)
        ]
        var diffByPath = [
            "Sources/Feature.swift": "diff --git a/Sources/Feature.swift b/Sources/Feature.swift\n+feature",
            "Tests/FeatureTests.swift": "diff --git a/Tests/FeatureTests.swift b/Tests/FeatureTests.swift\n+test"
        ]
        var diffByFileID: [String: String] = [:]
        var workingTreeDigestByPath: [String: String] = [:]
        var restoredIndexStatusFiles: [GitStatusFile]?
        var capturedIndexStatusFiles: [GitStatusFile]?
        var lookupResult: GitHubPullRequestLookupResult = .none
        var remoteURL: String? = "https://github.com/example/repo"
        var existingBranches: Set<String> = []
        var indexAvailable = true
        var calls: [String] = []
        var commitFailureCount = 0
        var indexTreeSHA: String? = GitPullRequestPublishServiceTests.reviewedTreeSHA
        var committedTreeSHA: String? = GitPullRequestPublishServiceTests.reviewedTreeSHA
        var createPullRequestFailureCount = 0
        var createPullRequestURL = "https://github.com/example/repo/pull/42"
        var createPullRequestDraftValues: [Bool] = []
        var lookupRemoteURLs: [String] = []
        var lookupBases: [String] = []
        var createRemoteURLs: [String] = []
        var remoteHeadSHAAfterFoundPullRequestLookup: String?

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

        func getIndexTreeSHA(at repoPath: String) async -> String? {
            if capturedIndexStatusFiles == nil {
                capturedIndexStatusFiles = statusFiles
            }
            return indexTreeSHA
        }
        func getCommitTreeSHA(_ commit: String, at repoPath: String) async -> String? { committedTreeSHA }
        func restoreIndexTreeSHA(_ treeSHA: String, at repoPath: String) async throws {
            calls.append("restore-index:\(treeSHA)")
            if let states = restoredIndexStatusFiles ?? capturedIndexStatusFiles {
                statusFiles = states
            }
        }
        func getWorkingTreeContentDigest(relativePath: String, at repoPath: String) async -> String? {
            workingTreeDigestByPath[relativePath]
        }

        func lookupRemoteCommitSHA(
            remote: String,
            branch: String,
            at repoPath: String
        ) async -> GitRemoteCommitLookupResult {
            calls.append("remote-lookup:\(remote):\(branch)")
            if let remoteLookupFailure { return .unavailable(remoteLookupFailure) }
            guard let sha = remoteRefSHAs["\(remote)/\(branch)"] else { return .missing }
            return .found(sha)
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
            statusFiles = statusFiles.map { current in
                guard current.relativePath == file.relativePath else { return current }
                return GitStatusFile(
                    relativePath: current.relativePath,
                    status: current.status,
                    isStaged: true,
                    originalPath: current.originalPath
                )
            }
        }

        func stageAll(at repoPath: String) async throws {}
        func unstageFile(_ file: GitStatusFile, at repoPath: String) async throws {
            calls.append("unstage:\(file.relativePath)")
            statusFiles = statusFiles.map { current in
                guard current.relativePath == file.relativePath else { return current }
                return GitStatusFile(
                    relativePath: current.relativePath,
                    status: current.status,
                    isStaged: false,
                    originalPath: current.originalPath
                )
            }
        }
        func unstageAll(at repoPath: String) async throws {}
        func resetBranchPreservingChanges(to commit: String, at repoPath: String) async throws {
            calls.append("reset-preserving:\(commit)")
            headSHA = commit
            refSHAs[currentBranch] = commit
        }
        func applyDiffPatchToIndex(_ patch: String, at repoPath: String, reverse: Bool) async throws {}

        func commit(message: String, at repoPath: String) async throws {
            calls.append("commit:\(message)")
            if commitFailureCount > 0 {
                commitFailureCount -= 1
                throw NSError(domain: "FakeGit", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "pre-commit hook rejected commit"
                ])
            }
            headSHA = GitPullRequestPublishServiceTests.commitSHA
            refSHAs[currentBranch] = headSHA
            statusFiles = []
        }

        func pullRebase(at repoPath: String) async throws {}
        func push(at repoPath: String) async throws {}

        func pushSetUpstream(branch: String, remote: String, at repoPath: String) async throws {
            calls.append("push:\(remote):\(branch)")
            remoteRefSHAs["\(remote)/\(branch)"] = refSHAs[branch] ?? headSHA
        }

        func hasRemote(at repoPath: String) async -> Bool { remoteURL != nil }

        func lookupOpenPullRequest(
            repoPath: String,
            head: String,
            ghPathOverride: String?
        ) async -> GitHubPullRequestLookupResult {
            calls.append("lookup:\(head)")
            if case .found = lookupResult,
               let replacement = remoteHeadSHAAfterFoundPullRequestLookup {
                remoteRefSHAs["origin/\(head)"] = replacement
                remoteHeadSHAAfterFoundPullRequestLookup = nil
            }
            return lookupResult
        }

        func lookupOpenPullRequest(
            repoPath: String,
            remoteURL: String,
            base: String,
            head: String,
            ghPathOverride: String?
        ) async -> GitHubPullRequestLookupResult {
            lookupRemoteURLs.append(remoteURL)
            lookupBases.append(base)
            return await lookupOpenPullRequest(
                repoPath: repoPath,
                head: head,
                ghPathOverride: ghPathOverride
            )
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
            let value = diffByFileID[file.id] ?? diffByPath[file.relativePath] ?? ""
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
            if let reference = GitHubPullRequestRef.fromCreatedURL(createPullRequestURL) {
                lookupResult = .found(GitHubPullRequestRef(
                    number: reference.number,
                    url: reference.url,
                    title: title,
                    isDraft: isDraft,
                    state: "OPEN"
                ))
            }
            return createPullRequestURL
        }

        func createPullRequest(
            repoPath: String,
            remoteURL: String,
            base: String,
            head: String,
            title: String,
            body: String,
            isDraft: Bool,
            ghPathOverride: String?
        ) async throws -> String {
            createRemoteURLs.append(remoteURL)
            return try await createPullRequest(
                repoPath: repoPath,
                base: base,
                head: head,
                title: title,
                body: body,
                isDraft: isDraft,
                ghPathOverride: ghPathOverride
            )
        }

        func normalizeBaseBranch(_ raw: String) -> String { GitService.normalizeBaseBranch(raw) }
    }

    private func request(
        authorization: GitPullRequestPublishAuthorizationRequirement = .explicitApproval,
        paths: [String] = ["Tests/FeatureTests.swift", "Sources/Feature.swift"],
        remote: String = "origin",
        baseBranch: String = "origin/main"
    ) -> GitPullRequestPublishRequest {
        GitPullRequestPublishRequest(
            repositoryPath: Self.repositoryPath,
            remote: remote,
            baseBranch: baseBranch,
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
        store: any GitPullRequestPublishCheckpointStoring = InMemoryGitPullRequestPublishCheckpointStore()
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
        #expect(receipt.verification == .createdPullRequestLookup)
        #expect(receipt.completedAt == Date(timeIntervalSince1970: 1234))
        #expect(git.calls.filter { $0.hasPrefix("branch:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("pr:") }.count == 1)
        #expect(git.createPullRequestDraftValues == [true])
        #expect(git.lookupRemoteURLs.allSatisfy { $0 == "https://github.com/example/repo" })
        #expect(git.lookupBases.allSatisfy { $0 == "main" })
        #expect(git.createRemoteURLs == ["https://github.com/example/repo"])
        #expect(await store.checkpoint(for: proposal.proposalID)?.state == .pushed)
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
        git.remoteRefSHAs["origin/feature/typed-publish"] = Self.commitSHA
        git.statusFiles = []
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

    @Test("existing draft publication is bound to the reviewed remote head")
    func existingDraftRemoteHeadDriftFailsClosed() async throws {
        let git = FakeGit()
        git.lookupResult = .found(GitHubPullRequestRef(
            number: 17,
            url: "https://github.com/example/repo/pull/17",
            title: "Existing",
            isDraft: true,
            state: "OPEN"
        ))
        git.remoteRefSHAs["origin/feature/typed-publish"] = Self.commitSHA
        git.statusFiles = []
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request())
        #expect(proposal.existingPullRequestHeadSHA == Self.commitSHA)

        git.remoteRefSHAs["origin/feature/typed-publish"] = String(repeating: "c", count: 40)

        do {
            _ = try await publisher.publish(proposal)
            Issue.record("A force-pushed existing draft unexpectedly satisfied the reviewed proposal")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .proposalChanged)
        }
    }

    @Test("an existing draft cannot hide selected local work")
    func existingDraftWithSelectedDirtyChangesFailsClosed() async throws {
        let git = FakeGit()
        git.lookupResult = .found(GitHubPullRequestRef(
            number: 17,
            url: "https://github.com/example/repo/pull/17",
            title: "Existing",
            isDraft: true,
            state: "OPEN"
        ))
        git.remoteRefSHAs["origin/feature/typed-publish"] = Self.commitSHA

        do {
            _ = try await service(git: git).prepare(request())
            Issue.record("Dirty selected work was incorrectly treated as already published")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .existingPullRequestHasUnpublishedChanges(
                number: 17,
                paths: ["Sources/Feature.swift", "Tests/FeatureTests.swift"]
            ))
        }
    }

    @Test("an existing draft is rechecked for dirty selected work at publication time")
    func existingDraftRaceFailsClosed() async throws {
        let git = FakeGit()
        git.lookupResult = .found(GitHubPullRequestRef(
            number: 17,
            url: "https://github.com/example/repo/pull/17",
            title: "Existing",
            isDraft: true,
            state: "OPEN"
        ))
        git.remoteRefSHAs["origin/feature/typed-publish"] = Self.commitSHA
        git.statusFiles = []
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request())
        git.statusFiles = [
            GitStatusFile(relativePath: "Sources/Feature.swift", status: "M", isStaged: false)
        ]

        do {
            _ = try await publisher.publish(proposal)
            Issue.record("Dirty work added after review was incorrectly skipped")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .existingPullRequestHasUnpublishedChanges(
                number: 17,
                paths: ["Sources/Feature.swift"]
            ))
        }
    }

    @Test("a non-draft existing PR cannot satisfy a draft publication")
    func existingReadyPullRequestFailsDraftWorkflow() async throws {
        let git = FakeGit()
        git.lookupResult = .found(GitHubPullRequestRef(
            number: 18,
            url: "https://github.com/example/repo/pull/18",
            title: "Ready",
            isDraft: false,
            state: "OPEN"
        ))

        do {
            _ = try await service(git: git).prepare(request())
            Issue.record("A ready PR unexpectedly satisfied draft publication")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .existingPullRequestIsNotDraft(
                number: 18,
                url: "https://github.com/example/repo/pull/18"
            ))
        }
    }

    @Test("the selected non-origin remote is removed from the GitHub base branch")
    func nonOriginBaseNormalizationUsesSelectedRemote() async throws {
        let git = FakeGit()
        git.remoteRefSHAs["upstream/main"] = Self.baseSHA
        git.remoteURL = "https://github.com/upstream/repository"

        let proposal = try await service(git: git).prepare(request(
            remote: "upstream",
            baseBranch: "upstream/main"
        ))

        #expect(proposal.remote == "upstream")
        #expect(proposal.baseBranch == "main")
        #expect(git.calls.contains("remote-lookup:upstream:main"))
        #expect(git.lookupRemoteURLs == ["https://github.com/upstream/repository"])
    }

    @Test("credentialed remote URLs are sanitized before durable proposal state")
    func credentialedRemoteURLIsSanitized() async throws {
        let git = FakeGit()
        git.remoteURL = "https://user:secret-token@github.com/example/repo.git"

        let proposal = try await service(git: git).prepare(request())

        #expect(proposal.remoteURL == "https://github.com/example/repo")
        #expect(!proposal.proposalID.contains("secret-token"))
        #expect(git.lookupRemoteURLs == ["https://github.com/example/repo"])
    }

    @Test("checkpoint save failure stops before branch creation or external mutation")
    func checkpointSaveFailureStopsIrreversibleContinuation() async throws {
        let git = FakeGit()
        let publisher = service(git: git, store: FailingCheckpointStore())
        let proposal = try await publisher.prepare(request())

        do {
            _ = try await publisher.publish(
                proposal,
                approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
            )
            Issue.record("Publication continued after its checkpoint failed")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .operationFailed(
                phase: .checkpoint,
                message: "checkpoint write failed"
            ))
        }

        #expect(!git.calls.contains { $0.hasPrefix("branch:") })
        #expect(!git.calls.contains { $0.hasPrefix("commit:") })
        #expect(!git.calls.contains { $0.hasPrefix("push:") })
        #expect(!git.calls.contains { $0.hasPrefix("pr:") })
    }

    @Test("commit hook failure resumes from the prepared checkpoint")
    func commitFailureRetryIsResumable() async throws {
        let git = FakeGit()
        git.commitFailureCount = 1
        let store = InMemoryGitPullRequestPublishCheckpointStore()
        let publisher = service(git: git, store: store)
        let proposal = try await publisher.prepare(request())
        let approval = GitPullRequestPublishApproval(proposalID: proposal.proposalID)

        do {
            _ = try await publisher.publish(proposal, approval: approval)
            Issue.record("First commit unexpectedly succeeded")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .operationFailed(
                phase: .commit,
                message: "pre-commit hook rejected commit"
            ))
        }
        #expect(await store.checkpoint(for: proposal.proposalID)?.state == .prepared)
        #expect(git.existingBranches.contains(proposal.headBranch))

        let receipt = try await publisher.publish(proposal, approval: approval)

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(git.calls.filter { $0.hasPrefix("branch:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 2)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("pr:") }.count == 1)
        #expect(await store.checkpoint(for: proposal.proposalID)?.state == .pushed)
    }

    @Test("prepared retry restores the exact mixed staged and unstaged index")
    func mixedIndexCommitFailureRetryRestoresReviewedTree() async throws {
        let git = FakeGit()
        let staged = GitStatusFile(
            relativePath: "Sources/Mixed.swift",
            status: "M",
            isStaged: true
        )
        let unstaged = GitStatusFile(
            relativePath: "Sources/Mixed.swift",
            status: "M",
            isStaged: false
        )
        git.statusFiles = [staged, unstaged]
        git.diffByFileID = [
            staged.id: "diff --git a/Sources/Mixed.swift b/Sources/Mixed.swift\n+staged",
            unstaged.id: "diff --git a/Sources/Mixed.swift b/Sources/Mixed.swift\n+unstaged"
        ]
        git.restoredIndexStatusFiles = [staged, unstaged]
        git.commitFailureCount = 1
        let store = InMemoryGitPullRequestPublishCheckpointStore()
        let publisher = service(git: git, store: store)
        let proposal = try await publisher.prepare(request(paths: ["Sources/Mixed.swift"]))
        let approval = GitPullRequestPublishApproval(proposalID: proposal.proposalID)

        do {
            _ = try await publisher.publish(proposal, approval: approval)
            Issue.record("First mixed-index commit unexpectedly succeeded")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .operationFailed(
                phase: .commit,
                message: "pre-commit hook rejected commit"
            ))
        }

        let receipt = try await publisher.publish(proposal, approval: approval)

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(git.calls.contains("restore-index:\(Self.reviewedTreeSHA)"))
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 2)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
    }

    @Test("commit hook content mutation stops before push and restores the reviewed branch")
    func commitHookContentMutationFailsClosed() async throws {
        let git = FakeGit()
        git.committedTreeSHA = String(repeating: "d", count: 40)
        let store = InMemoryGitPullRequestPublishCheckpointStore()
        let publisher = service(git: git, store: store)
        let proposal = try await publisher.prepare(request())

        do {
            _ = try await publisher.publish(
                proposal,
                approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
            )
            Issue.record("Hook-mutated committed content unexpectedly reached publication")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .operationFailed(
                phase: .commit,
                message: "A Git commit hook changed the reviewed content; publication stopped before push."
            ))
        }

        #expect(git.calls.contains("reset-preserving:\(Self.baseSHA)"))
        #expect(git.headSHA == Self.baseSHA)
        #expect(!git.calls.contains { $0.hasPrefix("push:") })
        #expect(!git.calls.contains { $0.hasPrefix("pr:") })
        #expect(await store.checkpoint(for: proposal.proposalID)?.state == .prepared)
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

        // Simulate another task checking out a different branch while the
        // local remote-tracking ref remains stale. The authoritative remote is
        // already at the checkpointed commit.
        git.currentBranch = "main"
        git.headSHA = Self.baseSHA
        git.refSHAs["origin/feature/typed-publish"] = Self.baseSHA

        let receipt = try await publisher.publish(proposal, approval: approval)

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(git.calls.filter { $0.hasPrefix("branch:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("pr:") }.count == 2)
        #expect(git.currentBranch == "main")
        #expect(git.calls.filter { $0 == "remote-lookup:origin:feature/typed-publish" }.count >= 2)
        #expect(await store.checkpoint(for: proposal.proposalID)?.state == .pushed)
    }

    @Test("retry after PR creation uses the pushed checkpoint as reviewed head authority")
    func receiptPersistenceRetryUsesPushedCheckpoint() async throws {
        let git = FakeGit()
        let store = InMemoryGitPullRequestPublishCheckpointStore()
        let publisher = service(git: git, store: store)
        let proposal = try await publisher.prepare(request())
        let approval = GitPullRequestPublishApproval(proposalID: proposal.proposalID)

        _ = try await publisher.publish(proposal, approval: approval)
        let receipt = try await publisher.publish(proposal, approval: approval)

        #expect(receipt.commitSHA == Self.commitSHA)
        #expect(receipt.source == .existing)
        #expect(git.calls.filter { $0.hasPrefix("branch:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("commit:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("push:") }.count == 1)
        #expect(git.calls.filter { $0.hasPrefix("pr:") }.count == 1)
    }

    @Test("created PR receipt rechecks the authoritative remote head")
    func createdPullRequestRemoteHeadRaceFailsClosed() async throws {
        let git = FakeGit()
        let changedRemoteHead = String(repeating: "d", count: 40)
        git.remoteHeadSHAAfterFoundPullRequestLookup = changedRemoteHead
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request())

        do {
            _ = try await publisher.publish(
                proposal,
                approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
            )
            Issue.record("A created PR with a changed remote head unexpectedly produced a receipt")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .remoteCommitMismatch(
                ref: "origin/feature/typed-publish",
                expected: Self.commitSHA,
                actual: changedRemoteHead
            ))
        }
    }

    @Test("untracked binary content is fingerprinted and remains drift protected")
    func untrackedBinaryUsesWorkingTreeDigest() async throws {
        let git = FakeGit()
        let binaryPath = "Assets/Preview.png"
        git.statusFiles = [GitStatusFile(
            relativePath: binaryPath,
            status: "?",
            isStaged: false
        )]
        git.diffByPath[binaryPath] = ""
        git.workingTreeDigestByPath[binaryPath] = "binary-object-v1"
        let publisher = service(git: git)
        let proposal = try await publisher.prepare(request(paths: [binaryPath]))
        #expect(proposal.selectedFileStates.count == 1)

        git.workingTreeDigestByPath[binaryPath] = "binary-object-v2"
        do {
            _ = try await publisher.publish(
                proposal,
                approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
            )
            Issue.record("Changed binary content unexpectedly passed revalidation")
        } catch let error as GitPullRequestPublishError {
            #expect(error == .proposalChanged)
        }

        git.workingTreeDigestByPath[binaryPath] = "binary-object-v1"
        let receipt = try await publisher.publish(
            proposal,
            approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
        )
        #expect(receipt.commitSHA == Self.commitSHA)
    }
}
