import CryptoKit
import Foundation
import ASTRAGitContracts

/// Deterministic GitHub publication orchestrator. GitRepositoryOperating is the
/// only mutation boundary: this service never invokes git, gh, or a shell
/// directly.
final class GitPullRequestPublishService {
    private static let maximumCapturedDiffBytes = 16 * 1024 * 1024

    private let git: GitRepositoryOperating
    private let checkpointStore: any GitPullRequestPublishCheckpointStoring
    private let now: @Sendable () -> Date

    init(
        git: GitRepositoryOperating = GitService.shared,
        checkpointStore: any GitPullRequestPublishCheckpointStoring = InMemoryGitPullRequestPublishCheckpointStore.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.git = git
        self.checkpointStore = checkpointStore
        self.now = now
    }

    /// Resolves and validates every mutable input before Ask mode presents an
    /// approval. Only a clean remote-base starting point is accepted, ensuring
    /// an earlier local-only commit cannot silently enter the pull request.
    func prepare(_ request: GitPullRequestPublishRequest) async throws -> GitPullRequestPublishProposal {
        let scope: NormalizedRequest
        do {
            scope = try normalize(request)
        } catch {
            logFailure(operation: "publish_prepare", proposalID: nil, error: error)
            throw error
        }

        AppLogger.audit(.gitAuthoringStarted, category: "Git", fields: auditFields(
            operation: "publish_prepare",
            repositoryPath: scope.repositoryPath,
            headBranch: scope.headBranch,
            proposalID: nil
        ), level: .info)

        do {
            guard let actualHead = await git.getCommitSHA("HEAD", at: scope.repositoryPath) else {
                throw GitPullRequestPublishError.unableToResolveCommit("HEAD")
            }
            guard actualHead.caseInsensitiveCompare(scope.expectedHeadSHA) == .orderedSame else {
                throw GitPullRequestPublishError.expectedHeadMismatch(
                    expected: scope.expectedHeadSHA,
                    actual: actualHead
                )
            }

            guard let rawRemoteURL = await git.getRemoteURL(
                at: scope.repositoryPath,
                remote: scope.remote
            ), let remoteURL = GitService.webURLFromRemoteURL(rawRemoteURL) else {
                throw GitPullRequestPublishError.remoteUnavailable(scope.remote)
            }

            let baseSHA = try await authoritativeRemoteCommitSHA(
                remote: scope.remote,
                branch: scope.baseBranch,
                repositoryPath: scope.repositoryPath
            )

            let existingPullRequest: GitHubPullRequestRef?
            let existingPullRequestHeadSHA: String?
            switch await git.lookupOpenPullRequest(
                repoPath: scope.repositoryPath,
                remoteURL: remoteURL,
                head: scope.headBranch,
                ghPathOverride: nil
            ) {
            case let .found(reference):
                guard reference.isDraft else {
                    throw GitPullRequestPublishError.existingPullRequestIsNotDraft(
                        number: reference.number,
                        url: reference.url
                    )
                }
                try await ensureSelectedPathsAreCleanForExistingPullRequest(
                    repositoryPath: scope.repositoryPath,
                    selectedPaths: scope.selectedPaths,
                    pullRequest: reference
                )
                existingPullRequest = reference
                existingPullRequestHeadSHA = try await authoritativeRemoteCommitSHA(
                    remote: scope.remote,
                    branch: scope.headBranch,
                    repositoryPath: scope.repositoryPath
                )
            case .none:
                existingPullRequest = nil
                existingPullRequestHeadSHA = nil
            case let .unavailable(reason):
                throw GitPullRequestPublishError.pullRequestLookupUnavailable(reason)
            }

            let selectedFileStates: [GitPullRequestPublishFileState]
            if existingPullRequest != nil {
                // Idempotent retry after success: the working-tree changes have
                // already been committed, so there is nothing left to snapshot.
                selectedFileStates = []
            } else {
                guard baseSHA.caseInsensitiveCompare(scope.expectedHeadSHA) == .orderedSame else {
                    throw GitPullRequestPublishError.remoteBaseMismatch(
                        expectedHead: scope.expectedHeadSHA,
                        remoteBase: baseSHA
                    )
                }
                guard !(await git.localBranchExists(scope.headBranch, at: scope.repositoryPath)) else {
                    throw GitPullRequestPublishError.headBranchAlreadyExists(scope.headBranch)
                }
                selectedFileStates = try await captureSelectedFileStates(
                    repositoryPath: scope.repositoryPath,
                    selectedPaths: scope.selectedPaths
                )
            }

            let proposalID = Self.makeProposalID(
                repositoryPath: scope.repositoryPath,
                remote: scope.remote,
                remoteURL: remoteURL,
                baseBranch: scope.baseBranch,
                baseSHA: baseSHA,
                headBranch: scope.headBranch,
                expectedHeadSHA: scope.expectedHeadSHA,
                selectedPaths: scope.selectedPaths,
                selectedFileStates: selectedFileStates,
                commitMessage: scope.commitMessage,
                pullRequestTitle: scope.pullRequestTitle,
                pullRequestBody: scope.pullRequestBody,
                authorizationRequirement: scope.authorizationRequirement,
                existingPullRequest: existingPullRequest,
                existingPullRequestHeadSHA: existingPullRequestHeadSHA
            )
            let proposal = GitPullRequestPublishProposal(
                proposalID: proposalID,
                repositoryPath: scope.repositoryPath,
                remote: scope.remote,
                remoteURL: remoteURL,
                baseBranch: scope.baseBranch,
                baseSHA: baseSHA,
                headBranch: scope.headBranch,
                expectedHeadSHA: scope.expectedHeadSHA,
                selectedPaths: scope.selectedPaths,
                selectedFileStates: selectedFileStates,
                commitMessage: scope.commitMessage,
                pullRequestTitle: scope.pullRequestTitle,
                pullRequestBody: scope.pullRequestBody,
                isDraft: true,
                authorizationRequirement: scope.authorizationRequirement,
                existingPullRequest: existingPullRequest,
                existingPullRequestHeadSHA: existingPullRequestHeadSHA
            )
            AppLogger.audit(.gitAuthoringCompleted, category: "Git", fields: auditFields(
                operation: "publish_prepare",
                repositoryPath: scope.repositoryPath,
                headBranch: scope.headBranch,
                proposalID: proposalID,
                additional: [
                    "authorization": scope.authorizationRequirement.rawValue,
                    "selected_path_count": "\(scope.selectedPaths.count)",
                    "existing_pr": existingPullRequest == nil ? "false" : "true"
                ]
            ), level: .info)
            return proposal
        } catch {
            logFailure(operation: "publish_prepare", proposalID: nil, error: error)
            throw error
        }
    }

    /// Executes exactly the approved proposal. Ask mode must pass a matching
    /// approval token; Auto mode passes nil. Existing PRs return a receipt
    /// without acquiring the index or changing repository state.
    func publish(
        _ proposal: GitPullRequestPublishProposal,
        approval: GitPullRequestPublishApproval? = nil
    ) async throws -> GitPullRequestPublishReceipt {
        guard proposal.isDraft else {
            throw GitPullRequestPublishError.invalidRequest("Only draft pull requests are supported.")
        }
        guard proposal.proposalID == Self.makeProposalID(for: proposal) else {
            throw GitPullRequestPublishError.proposalChanged
        }

        if let existing = proposal.existingPullRequest {
            let verified = try await verifiedExistingPullRequest(
                proposal: proposal,
                expected: existing
            )
            let result = try await receiptForExistingPullRequest(proposal: proposal, pullRequest: verified)
            logSuccess(result)
            return result
        }

        try validateApproval(for: proposal, approval: approval)

        AppLogger.audit(.gitAuthoringStarted, category: "Git", fields: auditFields(
            operation: "publish_execute",
            repositoryPath: proposal.repositoryPath,
            headBranch: proposal.headBranch,
            proposalID: proposal.proposalID
        ), level: .info)

        // Recheck idempotency immediately before local mutations. A PR created
        // after preparation is success, not a reason to create a duplicate.
        switch await git.lookupOpenPullRequest(
            repoPath: proposal.repositoryPath,
            remoteURL: proposal.remoteURL,
            head: proposal.headBranch,
            ghPathOverride: nil
        ) {
        case let .found(reference):
            try await ensureSelectedPathsAreCleanForExistingPullRequest(
                repositoryPath: proposal.repositoryPath,
                selectedPaths: proposal.selectedPaths,
                pullRequest: reference
            )
            let result = try await receiptForExistingPullRequest(proposal: proposal, pullRequest: reference)
            logSuccess(result)
            return result
        case .none:
            break
        case let .unavailable(reason):
            let error = GitPullRequestPublishError.pullRequestLookupUnavailable(reason)
            logFailure(operation: "publish_execute", proposalID: proposal.proposalID, error: error)
            throw error
        }

        guard git.acquireIndexGuard() else {
            let error = GitPullRequestPublishError.repositoryBusy
            logFailure(operation: "publish_execute", proposalID: proposal.proposalID, error: error)
            throw error
        }
        defer { git.releaseIndexGuard() }

        var phase = GitPullRequestPublishPhase.preflight
        do {
            if let checkpoint = await checkpointStore.checkpoint(for: proposal.proposalID) {
                let result = try await resumeFromCheckpoint(proposal: proposal, checkpoint: checkpoint)
                logSuccess(result)
                return result
            }

            try await revalidate(proposal)

            phase = .checkpoint
            try await checkpointStore.save(GitPullRequestPublishCheckpoint(
                proposalID: proposal.proposalID,
                repositoryPath: proposal.repositoryPath,
                remote: proposal.remote,
                baseBranch: proposal.baseBranch,
                headBranch: proposal.headBranch,
                commitSHA: proposal.expectedHeadSHA,
                state: .prepared
            ))
            phase = .createBranch
            try await git.createBranch(
                proposal.headBranch,
                from: proposal.expectedHeadSHA,
                at: proposal.repositoryPath
            )

            phase = .stageFiles
            for state in Self.uniqueFileStatesForStaging(proposal.selectedFileStates) {
                try await git.stageFile(Self.statusFile(from: state), at: proposal.repositoryPath)
            }

            phase = .commit
            try await git.commit(message: proposal.commitMessage, at: proposal.repositoryPath)
            guard let commitSHA = await git.getCommitSHA("HEAD", at: proposal.repositoryPath) else {
                throw GitPullRequestPublishError.unableToResolveCommit("HEAD after commit")
            }
            guard commitSHA.caseInsensitiveCompare(proposal.expectedHeadSHA) != .orderedSame else {
                throw GitPullRequestPublishError.operationFailed(
                    phase: .commit,
                    message: "Git reported success but HEAD did not advance."
                )
            }
            phase = .checkpoint
            do {
                try await checkpointStore.save(GitPullRequestPublishCheckpoint(
                    proposalID: proposal.proposalID,
                    repositoryPath: proposal.repositoryPath,
                    remote: proposal.remote,
                    baseBranch: proposal.baseBranch,
                    headBranch: proposal.headBranch,
                    commitSHA: commitSHA,
                    state: .committed
                ))
            } catch {
                await rollbackUncheckpointedCommit(proposal: proposal)
                throw error
            }

            phase = .push
            try await git.pushSetUpstream(
                branch: proposal.headBranch,
                remote: proposal.remote,
                at: proposal.repositoryPath
            )
            phase = .verifyRemote
            try await verifyAuthoritativeRemoteCommit(
                proposal: proposal,
                expectedSHA: commitSHA
            )
            phase = .checkpoint
            try await checkpointStore.save(GitPullRequestPublishCheckpoint(
                proposalID: proposal.proposalID,
                repositoryPath: proposal.repositoryPath,
                remote: proposal.remote,
                baseBranch: proposal.baseBranch,
                headBranch: proposal.headBranch,
                commitSHA: commitSHA,
                state: .pushed
            ))

            phase = .createPullRequest
            let url = try await git.createPullRequest(
                repoPath: proposal.repositoryPath,
                remoteURL: proposal.remoteURL,
                base: proposal.baseBranch,
                head: proposal.headBranch,
                title: proposal.pullRequestTitle,
                body: proposal.pullRequestBody,
                isDraft: true,
                ghPathOverride: nil
            )
            guard let pullRequest = GitHubPullRequestRef.fromCreatedURL(url) else {
                throw GitPullRequestPublishError.invalidPullRequestURL(url)
            }
            phase = .verifyPullRequest
            let verifiedPullRequest = try await verifyDraftPullRequest(
                proposal: proposal,
                expected: pullRequest
            )

            let result = try receipt(
                proposal: proposal,
                pullRequest: verifiedPullRequest,
                commitSHA: commitSHA,
                source: .created,
                verification: .createdPullRequestLookup
            )
            logSuccess(result)
            return result
        } catch let error as GitPullRequestPublishError {
            logFailure(operation: "publish_execute", proposalID: proposal.proposalID, error: error)
            throw error
        } catch {
            let wrapped = GitPullRequestPublishError.operationFailed(
                phase: phase,
                message: String(error.localizedDescription.prefix(500))
            )
            logFailure(operation: "publish_execute", proposalID: proposal.proposalID, error: wrapped)
            throw wrapped
        }
    }

    // MARK: - Preflight

    private func revalidate(_ proposal: GitPullRequestPublishProposal) async throws {
        guard let actualHead = await git.getCommitSHA("HEAD", at: proposal.repositoryPath) else {
            throw GitPullRequestPublishError.unableToResolveCommit("HEAD")
        }
        guard actualHead.caseInsensitiveCompare(proposal.expectedHeadSHA) == .orderedSame else {
            throw GitPullRequestPublishError.expectedHeadMismatch(
                expected: proposal.expectedHeadSHA,
                actual: actualHead
            )
        }
        let baseSHA = try await authoritativeRemoteCommitSHA(
            remote: proposal.remote,
            branch: proposal.baseBranch,
            repositoryPath: proposal.repositoryPath
        )
        guard baseSHA.caseInsensitiveCompare(proposal.baseSHA) == .orderedSame else {
            throw GitPullRequestPublishError.remoteCommitMismatch(
                ref: "\(proposal.remote)/\(proposal.baseBranch)",
                expected: proposal.baseSHA,
                actual: baseSHA
            )
        }
        guard let rawRemoteURL = await git.getRemoteURL(
            at: proposal.repositoryPath,
            remote: proposal.remote
        ), GitService.webURLFromRemoteURL(rawRemoteURL) == proposal.remoteURL else {
            throw GitPullRequestPublishError.proposalChanged
        }
        guard !(await git.localBranchExists(proposal.headBranch, at: proposal.repositoryPath)) else {
            throw GitPullRequestPublishError.headBranchAlreadyExists(proposal.headBranch)
        }

        let currentFileStates = try await captureSelectedFileStates(
            repositoryPath: proposal.repositoryPath,
            selectedPaths: proposal.selectedPaths
        )
        guard currentFileStates == proposal.selectedFileStates else {
            throw GitPullRequestPublishError.proposalChanged
        }
    }

    /// Continues only the unfinished external portion of a prior execution.
    /// Exact local and remote ref checks bind the checkpoint to the approved
    /// commit before any retry is allowed.
    private func resumeFromCheckpoint(
        proposal: GitPullRequestPublishProposal,
        checkpoint: GitPullRequestPublishCheckpoint
    ) async throws -> GitPullRequestPublishReceipt {
        guard checkpoint.proposalID == proposal.proposalID,
              checkpoint.repositoryPath == proposal.repositoryPath,
              checkpoint.remote == proposal.remote,
              checkpoint.baseBranch == proposal.baseBranch,
              checkpoint.headBranch == proposal.headBranch else {
            throw GitPullRequestPublishError.proposalChanged
        }

        let effectiveCheckpoint: GitPullRequestPublishCheckpoint
        if checkpoint.state == .prepared {
            effectiveCheckpoint = try await resumePreparedCheckpoint(
                proposal: proposal,
                checkpoint: checkpoint
            )
        } else {
            effectiveCheckpoint = checkpoint
        }

        // Resume is bound to the named branch, not the user's current checkout.
        // Another task may have switched HEAD after the checkpoint was written.
        guard let localBranchSHA = await git.getCommitSHA(
            proposal.headBranch,
            at: proposal.repositoryPath
        ), localBranchSHA.caseInsensitiveCompare(effectiveCheckpoint.commitSHA) == .orderedSame else {
            throw GitPullRequestPublishError.proposalChanged
        }

        let remoteRef = "\(proposal.remote)/\(proposal.headBranch)"
        let remoteSHA: String?
        switch await git.lookupRemoteCommitSHA(
            remote: proposal.remote,
            branch: proposal.headBranch,
            at: proposal.repositoryPath
        ) {
        case let .found(sha):
            guard sha.caseInsensitiveCompare(effectiveCheckpoint.commitSHA) == .orderedSame else {
                throw GitPullRequestPublishError.remoteCommitMismatch(
                    ref: remoteRef,
                    expected: effectiveCheckpoint.commitSHA,
                    actual: sha
                )
            }
            remoteSHA = sha
        case .missing:
            guard effectiveCheckpoint.state == .committed else {
                throw GitPullRequestPublishError.remoteCommitMismatch(
                    ref: remoteRef,
                    expected: effectiveCheckpoint.commitSHA,
                    actual: "missing"
                )
            }
            remoteSHA = nil
        case let .unavailable(reason):
            throw GitPullRequestPublishError.remoteCommitLookupUnavailable(
                ref: remoteRef,
                reason: reason
            )
        }

        if effectiveCheckpoint.state == .committed && remoteSHA == nil {
            do {
                try await git.pushSetUpstream(
                    branch: proposal.headBranch,
                    remote: proposal.remote,
                    at: proposal.repositoryPath
                )
            } catch {
                throw GitPullRequestPublishError.operationFailed(
                    phase: .push,
                    message: String(error.localizedDescription.prefix(500))
                )
            }
            try await verifyAuthoritativeRemoteCommit(
                proposal: proposal,
                expectedSHA: effectiveCheckpoint.commitSHA
            )
        }
        do {
            try await checkpointStore.save(GitPullRequestPublishCheckpoint(
                proposalID: effectiveCheckpoint.proposalID,
                repositoryPath: effectiveCheckpoint.repositoryPath,
                remote: effectiveCheckpoint.remote,
                baseBranch: effectiveCheckpoint.baseBranch,
                headBranch: effectiveCheckpoint.headBranch,
                commitSHA: effectiveCheckpoint.commitSHA,
                state: .pushed
            ))
        } catch {
            throw GitPullRequestPublishError.operationFailed(
                phase: .checkpoint,
                message: String(error.localizedDescription.prefix(500))
            )
        }

        let url: String
        do {
            url = try await git.createPullRequest(
                repoPath: proposal.repositoryPath,
                remoteURL: proposal.remoteURL,
                base: proposal.baseBranch,
                head: proposal.headBranch,
                title: proposal.pullRequestTitle,
                body: proposal.pullRequestBody,
                isDraft: true,
                ghPathOverride: nil
            )
        } catch {
            throw GitPullRequestPublishError.operationFailed(
                phase: .createPullRequest,
                message: String(error.localizedDescription.prefix(500))
            )
        }
        guard let reference = GitHubPullRequestRef.fromCreatedURL(url) else {
            throw GitPullRequestPublishError.invalidPullRequestURL(url)
        }
        let verifiedReference = try await verifyDraftPullRequest(
            proposal: proposal,
            expected: reference
        )
        let result = try receipt(
            proposal: proposal,
            pullRequest: verifiedReference,
            commitSHA: effectiveCheckpoint.commitSHA,
            source: .created,
            verification: .createdPullRequestLookup
        )
        return result
    }

    /// Restores the reviewed index shape after a partial staging/commit failure,
    /// then deterministically completes the local commit before any push.
    private func resumePreparedCheckpoint(
        proposal: GitPullRequestPublishProposal,
        checkpoint: GitPullRequestPublishCheckpoint
    ) async throws -> GitPullRequestPublishCheckpoint {
        if !(await git.localBranchExists(proposal.headBranch, at: proposal.repositoryPath)) {
            try await revalidate(proposal)
            try await git.createBranch(
                proposal.headBranch,
                from: proposal.expectedHeadSHA,
                at: proposal.repositoryPath
            )
        }
        guard let branchSHA = await git.getCommitSHA(
            proposal.headBranch,
            at: proposal.repositoryPath
        ), branchSHA.caseInsensitiveCompare(proposal.expectedHeadSHA) == .orderedSame else {
            throw GitPullRequestPublishError.proposalChanged
        }
        if await git.getCurrentBranch(at: proposal.repositoryPath) != proposal.headBranch {
            try await git.checkoutBranch(proposal.headBranch, at: proposal.repositoryPath)
        }
        for state in Self.uniqueFileStatesForStaging(proposal.selectedFileStates) where !state.isStaged {
            try await git.unstageFile(Self.statusFile(from: state), at: proposal.repositoryPath)
        }
        let restoredStates = try await captureSelectedFileStates(
            repositoryPath: proposal.repositoryPath,
            selectedPaths: proposal.selectedPaths
        )
        guard restoredStates == proposal.selectedFileStates else {
            throw GitPullRequestPublishError.proposalChanged
        }
        for state in Self.uniqueFileStatesForStaging(proposal.selectedFileStates) {
            try await git.stageFile(Self.statusFile(from: state), at: proposal.repositoryPath)
        }
        do {
            try await git.commit(message: proposal.commitMessage, at: proposal.repositoryPath)
            guard let commitSHA = await git.getCommitSHA("HEAD", at: proposal.repositoryPath),
                  commitSHA.caseInsensitiveCompare(proposal.expectedHeadSHA) != .orderedSame else {
                throw GitPullRequestPublishError.operationFailed(
                    phase: .commit,
                    message: "Git reported success but HEAD did not advance."
                )
            }
            let committed = GitPullRequestPublishCheckpoint(
                proposalID: checkpoint.proposalID,
                repositoryPath: checkpoint.repositoryPath,
                remote: checkpoint.remote,
                baseBranch: checkpoint.baseBranch,
                headBranch: checkpoint.headBranch,
                commitSHA: commitSHA,
                state: .committed
            )
            do {
                try await checkpointStore.save(committed)
            } catch {
                await rollbackUncheckpointedCommit(proposal: proposal)
                throw error
            }
            return committed
        } catch let error as GitPullRequestPublishError {
            throw error
        } catch {
            throw GitPullRequestPublishError.operationFailed(
                phase: .commit,
                message: String(error.localizedDescription.prefix(500))
            )
        }
    }

    private func authoritativeRemoteCommitSHA(
        remote: String,
        branch: String,
        repositoryPath: String
    ) async throws -> String {
        let ref = "\(remote)/\(branch)"
        switch await git.lookupRemoteCommitSHA(
            remote: remote,
            branch: branch,
            at: repositoryPath
        ) {
        case let .found(sha):
            return sha
        case .missing:
            throw GitPullRequestPublishError.unableToResolveCommit(ref)
        case let .unavailable(reason):
            throw GitPullRequestPublishError.remoteCommitLookupUnavailable(
                ref: ref,
                reason: reason
            )
        }
    }

    private func verifyAuthoritativeRemoteCommit(
        proposal: GitPullRequestPublishProposal,
        expectedSHA: String
    ) async throws {
        let actualSHA = try await authoritativeRemoteCommitSHA(
            remote: proposal.remote,
            branch: proposal.headBranch,
            repositoryPath: proposal.repositoryPath
        )
        guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            throw GitPullRequestPublishError.remoteCommitMismatch(
                ref: "\(proposal.remote)/\(proposal.headBranch)",
                expected: expectedSHA,
                actual: actualSHA
            )
        }
    }

    private func verifyDraftPullRequest(
        proposal: GitPullRequestPublishProposal,
        expected: GitHubPullRequestRef
    ) async throws -> GitHubPullRequestRef {
        switch await git.lookupOpenPullRequest(
            repoPath: proposal.repositoryPath,
            remoteURL: proposal.remoteURL,
            head: proposal.headBranch,
            ghPathOverride: nil
        ) {
        case let .found(reference):
            guard reference.number == expected.number else {
                throw GitPullRequestPublishError.proposalChanged
            }
            guard reference.isDraft else {
                throw GitPullRequestPublishError.existingPullRequestIsNotDraft(
                    number: reference.number,
                    url: reference.url
                )
            }
            return reference
        case .none:
            throw GitPullRequestPublishError.pullRequestLookupUnavailable(
                "GitHub did not return the pull request after creation."
            )
        case let .unavailable(reason):
            throw GitPullRequestPublishError.pullRequestLookupUnavailable(reason)
        }
    }

    private func verifiedExistingPullRequest(
        proposal: GitPullRequestPublishProposal,
        expected: GitHubPullRequestRef
    ) async throws -> GitHubPullRequestRef {
        try await ensureSelectedPathsAreCleanForExistingPullRequest(
            repositoryPath: proposal.repositoryPath,
            selectedPaths: proposal.selectedPaths,
            pullRequest: expected
        )
        switch await git.lookupOpenPullRequest(
            repoPath: proposal.repositoryPath,
            remoteURL: proposal.remoteURL,
            head: proposal.headBranch,
            ghPathOverride: nil
        ) {
        case let .found(reference):
            guard reference.number == expected.number else {
                throw GitPullRequestPublishError.proposalChanged
            }
            guard reference.isDraft else {
                throw GitPullRequestPublishError.existingPullRequestIsNotDraft(
                    number: reference.number,
                    url: reference.url
                )
            }
            return reference
        case .none:
            throw GitPullRequestPublishError.pullRequestLookupUnavailable(
                "GitHub no longer reports the reviewed pull request as open."
            )
        case let .unavailable(reason):
            throw GitPullRequestPublishError.pullRequestLookupUnavailable(reason)
        }
    }

    private func ensureSelectedPathsAreCleanForExistingPullRequest(
        repositoryPath: String,
        selectedPaths: [String],
        pullRequest: GitHubPullRequestRef
    ) async throws {
        let selected = Set(selectedPaths)
        let dirtyPaths = Set(await git.getStatusFiles(at: repositoryPath).flatMap { file in
            [file.relativePath, file.originalPath].compactMap { $0 }
        }).intersection(selected).sorted()
        guard dirtyPaths.isEmpty else {
            throw GitPullRequestPublishError.existingPullRequestHasUnpublishedChanges(
                number: pullRequest.number,
                paths: dirtyPaths
            )
        }
    }

    private func captureSelectedFileStates(
        repositoryPath: String,
        selectedPaths: [String]
    ) async throws -> [GitPullRequestPublishFileState] {
        let statusFiles = await git.getStatusFiles(at: repositoryPath)
        let selected = Set(selectedPaths)
        let present = Set(statusFiles.map(\.relativePath)).intersection(selected)
        let missing = selected.subtracting(present).sorted()
        guard missing.isEmpty else {
            throw GitPullRequestPublishError.selectedChangesMissing(missing)
        }

        let conflicts = Set(statusFiles.filter {
            selected.contains($0.relativePath) && $0.isConflict
        }.map(\.relativePath)).sorted()
        guard conflicts.isEmpty else {
            throw GitPullRequestPublishError.selectedChangesConflicted(conflicts)
        }

        let unrelatedStaged = Set(statusFiles.filter {
            $0.isStaged && !selected.contains($0.relativePath)
        }.map(\.relativePath)).sorted()
        guard unrelatedStaged.isEmpty else {
            throw GitPullRequestPublishError.unrelatedStagedChanges(unrelatedStaged)
        }

        let scopedFiles = statusFiles.filter { selected.contains($0.relativePath) }.sorted {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            if $0.isStaged != $1.isStaged { return !$0.isStaged }
            if $0.status != $1.status { return $0.status < $1.status }
            return ($0.originalPath ?? "") < ($1.originalPath ?? "")
        }

        var states: [GitPullRequestPublishFileState] = []
        states.reserveCapacity(scopedFiles.count)
        for file in scopedFiles {
            let diff = await git.getFileDiff(
                at: repositoryPath,
                file: file,
                limit: Self.maximumCapturedDiffBytes
            )
            guard diff.kind != .unavailable, !diff.isTruncated, diff.hasDiff else {
                throw GitPullRequestPublishError.selectedContentUnavailable(file.relativePath)
            }
            states.append(GitPullRequestPublishFileState(
                relativePath: file.relativePath,
                originalPath: file.originalPath,
                status: file.status,
                isStaged: file.isStaged,
                diffSHA256: Self.sha256Hex(diff.diff)
            ))
        }
        return states
    }

    // MARK: - Validation and normalization

    private struct NormalizedRequest {
        let repositoryPath: String
        let remote: String
        let baseBranch: String
        let headBranch: String
        let expectedHeadSHA: String
        let selectedPaths: [String]
        let commitMessage: String
        let pullRequestTitle: String
        let pullRequestBody: String
        let authorizationRequirement: GitPullRequestPublishAuthorizationRequirement
    }

    private func normalize(_ request: GitPullRequestPublishRequest) throws -> NormalizedRequest {
        let rawRepositoryPath = request.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawRepositoryPath.hasPrefix("/") else {
            throw GitPullRequestPublishError.invalidRequest("Repository path must be absolute.")
        }
        let repositoryPath = URL(fileURLWithPath: rawRepositoryPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let remote = request.remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeRefComponent(remote) else {
            throw GitPullRequestPublishError.invalidRequest("Remote name is invalid.")
        }

        let baseBranch = git.normalizeBaseBranch(request.baseBranch, remote: remote)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headBranch = request.headBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeBranchName(baseBranch) else {
            throw GitPullRequestPublishError.invalidRequest("Base branch is invalid.")
        }
        guard Self.isSafeBranchName(headBranch) else {
            throw GitPullRequestPublishError.invalidRequest("Head branch is invalid.")
        }
        guard baseBranch != headBranch else {
            throw GitPullRequestPublishError.invalidRequest("Head branch must differ from the base branch.")
        }

        let expectedHeadSHA = request.expectedHeadSHA.lowercased()
        guard [40, 64].contains(expectedHeadSHA.count),
              expectedHeadSHA.allSatisfy(\.isHexDigit) else {
            throw GitPullRequestPublishError.invalidRequest("Expected HEAD must be a full Git commit SHA.")
        }

        let selectedPaths = Array(Set(request.selectedPaths.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })).sorted()
        guard !selectedPaths.isEmpty else {
            throw GitPullRequestPublishError.invalidRequest("At least one changed path must be selected.")
        }
        for path in selectedPaths where !Self.isSafeRelativePath(path) {
            throw GitPullRequestPublishError.invalidRequest("Selected path is unsafe: \(path)")
        }

        guard !request.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.commitMessage.contains("\0") else {
            throw GitPullRequestPublishError.invalidRequest("Commit message is empty or invalid.")
        }
        guard !request.pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.pullRequestTitle.contains("\n"),
              !request.pullRequestTitle.contains("\0") else {
            throw GitPullRequestPublishError.invalidRequest("Pull request title is empty or invalid.")
        }
        guard !request.pullRequestBody.contains("\0") else {
            throw GitPullRequestPublishError.invalidRequest("Pull request body is invalid.")
        }

        return NormalizedRequest(
            repositoryPath: repositoryPath,
            remote: remote,
            baseBranch: baseBranch,
            headBranch: headBranch,
            expectedHeadSHA: expectedHeadSHA,
            selectedPaths: selectedPaths,
            commitMessage: request.commitMessage,
            pullRequestTitle: request.pullRequestTitle,
            pullRequestBody: request.pullRequestBody,
            authorizationRequirement: request.authorizationRequirement
        )
    }

    private func validateApproval(
        for proposal: GitPullRequestPublishProposal,
        approval: GitPullRequestPublishApproval?
    ) throws {
        guard proposal.requiresExplicitApproval else { return }
        guard let approval else {
            throw GitPullRequestPublishError.approvalRequired(proposal.proposalID)
        }
        guard approval.proposalID == proposal.proposalID else {
            throw GitPullRequestPublishError.approvalMismatch(
                expected: proposal.proposalID,
                actual: approval.proposalID
            )
        }
    }

    private static func isSafeRefComponent(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("/")
            && !value.contains("..")
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
                    && !"~^:?*[\\".unicodeScalars.contains(scalar)
            }
    }

    private static func isSafeBranchName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "HEAD"
            && !value.hasPrefix("-")
            && !value.hasPrefix("/")
            && !value.hasSuffix("/")
            && !value.hasSuffix(".")
            && !value.hasSuffix(".lock")
            && !value.contains("//")
            && value.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { isSafeRefComponent(String($0)) }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\0"),
              !value.contains("\n") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    // MARK: - Receipts, fingerprints, and audit

    private func receiptForExistingPullRequest(
        proposal: GitPullRequestPublishProposal,
        pullRequest: GitHubPullRequestRef
    ) async throws -> GitPullRequestPublishReceipt {
        guard pullRequest.isDraft else {
            throw GitPullRequestPublishError.existingPullRequestIsNotDraft(
                number: pullRequest.number,
                url: pullRequest.url
            )
        }
        guard let rawCurrentRemoteURL = await git.getRemoteURL(
            at: proposal.repositoryPath,
            remote: proposal.remote
        ), GitService.webURLFromRemoteURL(rawCurrentRemoteURL) == proposal.remoteURL else {
            throw GitPullRequestPublishError.proposalChanged
        }
        try await ensureSelectedPathsAreCleanForExistingPullRequest(
            repositoryPath: proposal.repositoryPath,
            selectedPaths: proposal.selectedPaths,
            pullRequest: pullRequest
        )
        let remoteHeadSHA = try await authoritativeRemoteCommitSHA(
            remote: proposal.remote,
            branch: proposal.headBranch,
            repositoryPath: proposal.repositoryPath
        )
        guard let reviewedHeadSHA = proposal.existingPullRequestHeadSHA,
              reviewedHeadSHA.caseInsensitiveCompare(remoteHeadSHA) == .orderedSame else {
            throw GitPullRequestPublishError.proposalChanged
        }
        if let checkpoint = await checkpointStore.checkpoint(for: proposal.proposalID) {
            guard checkpoint.commitSHA.caseInsensitiveCompare(remoteHeadSHA) == .orderedSame else {
                throw GitPullRequestPublishError.proposalChanged
            }
        }
        let result = try receipt(
            proposal: proposal,
            pullRequest: pullRequest,
            commitSHA: remoteHeadSHA,
            source: .existing,
            verification: .existingPullRequestLookup
        )
        return result
    }

    private func receipt(
        proposal: GitPullRequestPublishProposal,
        pullRequest: GitHubPullRequestRef,
        commitSHA: String,
        source: GitPullRequestPublishReceiptSource,
        verification: GitPullRequestPublishReceiptVerification
    ) throws -> GitPullRequestPublishReceipt {
        guard !pullRequest.url.isEmpty, pullRequest.number > 0 else {
            throw GitPullRequestPublishError.invalidPullRequestURL(pullRequest.url)
        }
        return GitPullRequestPublishReceipt(
            proposalID: proposal.proposalID,
            repositoryPath: proposal.repositoryPath,
            remote: proposal.remote,
            remoteURL: proposal.remoteURL,
            baseBranch: proposal.baseBranch,
            baseSHA: proposal.baseSHA,
            headBranch: proposal.headBranch,
            commitSHA: commitSHA,
            selectedPaths: proposal.selectedPaths,
            commitMessage: proposal.commitMessage,
            pullRequestTitle: proposal.pullRequestTitle,
            pullRequestBody: proposal.pullRequestBody,
            pullRequestNumber: pullRequest.number,
            pullRequestURL: pullRequest.url,
            isDraft: pullRequest.isDraft,
            source: source,
            verification: verification,
            completedAt: now()
        )
    }

    private static func uniqueFileStatesForStaging(
        _ states: [GitPullRequestPublishFileState]
    ) -> [GitPullRequestPublishFileState] {
        var seen: Set<String> = []
        return states.filter { seen.insert($0.relativePath).inserted }
    }

    private static func statusFile(from state: GitPullRequestPublishFileState) -> GitStatusFile {
        GitStatusFile(
            relativePath: state.relativePath,
            status: state.status,
            isStaged: state.isStaged,
            originalPath: state.originalPath
        )
    }

    /// A commit is not allowed to outlive a failed durable checkpoint. Mixed
    /// reset preserves file contents; originally staged paths are then restored
    /// so the user's pre-publication index shape remains intact for retry.
    private func rollbackUncheckpointedCommit(
        proposal: GitPullRequestPublishProposal
    ) async {
        do {
            try await git.resetBranchPreservingChanges(
                to: proposal.expectedHeadSHA,
                at: proposal.repositoryPath
            )
            for state in Self.uniqueFileStatesForStaging(proposal.selectedFileStates) where state.isStaged {
                try await git.stageFile(Self.statusFile(from: state), at: proposal.repositoryPath)
            }
        } catch {
            logFailure(
                operation: "publish_checkpoint_rollback",
                proposalID: proposal.proposalID,
                error: error
            )
        }
    }

    private static func makeProposalID(for proposal: GitPullRequestPublishProposal) -> String {
        makeProposalID(
            repositoryPath: proposal.repositoryPath,
            remote: proposal.remote,
            remoteURL: proposal.remoteURL,
            baseBranch: proposal.baseBranch,
            baseSHA: proposal.baseSHA,
            headBranch: proposal.headBranch,
            expectedHeadSHA: proposal.expectedHeadSHA,
            selectedPaths: proposal.selectedPaths,
            selectedFileStates: proposal.selectedFileStates,
            commitMessage: proposal.commitMessage,
            pullRequestTitle: proposal.pullRequestTitle,
            pullRequestBody: proposal.pullRequestBody,
            authorizationRequirement: proposal.authorizationRequirement,
            existingPullRequest: proposal.existingPullRequest,
            existingPullRequestHeadSHA: proposal.existingPullRequestHeadSHA
        )
    }

    private static func makeProposalID(
        repositoryPath: String,
        remote: String,
        remoteURL: String,
        baseBranch: String,
        baseSHA: String,
        headBranch: String,
        expectedHeadSHA: String,
        selectedPaths: [String],
        selectedFileStates: [GitPullRequestPublishFileState],
        commitMessage: String,
        pullRequestTitle: String,
        pullRequestBody: String,
        authorizationRequirement: GitPullRequestPublishAuthorizationRequirement,
        existingPullRequest: GitHubPullRequestRef?,
        existingPullRequestHeadSHA: String?
    ) -> String {
        var components = [
            "git-publish-proposal-v1",
            repositoryPath,
            remote,
            remoteURL,
            baseBranch,
            baseSHA.lowercased(),
            headBranch,
            expectedHeadSHA.lowercased(),
            commitMessage,
            pullRequestTitle,
            pullRequestBody,
            authorizationRequirement.rawValue,
            "draft=true"
        ]
        components.append(contentsOf: selectedPaths.map { "path:\($0)" })
        for state in selectedFileStates {
            components.append(contentsOf: [
                "file:\(state.relativePath)",
                "original:\(state.originalPath ?? "")",
                "status:\(state.status)",
                "staged:\(state.isStaged)",
                "diff:\(state.diffSHA256)"
            ])
        }
        if let existingPullRequest {
            components.append(contentsOf: [
                "existing_number:\(existingPullRequest.number)",
                "existing_url:\(existingPullRequest.url)",
                "existing_draft:\(existingPullRequest.isDraft)",
                "existing_state:\(existingPullRequest.state)"
            ])
            components.append("existing_head:\(existingPullRequestHeadSHA?.lowercased() ?? "missing")")
        }
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return sha256Hex(canonical)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func auditFields(
        operation: String,
        repositoryPath: String,
        headBranch: String,
        proposalID: String?,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var fields: [String: String] = [
            "operation": operation,
            "repo": URL(fileURLWithPath: repositoryPath).lastPathComponent,
            "head": headBranch
        ]
        if let proposalID {
            fields["proposal_id"] = proposalID
        }
        fields.merge(additional) { _, new in new }
        return fields
    }

    private func logSuccess(_ receipt: GitPullRequestPublishReceipt) {
        AppLogger.audit(.gitAuthoringCompleted, category: "Git", fields: auditFields(
            operation: "publish_execute",
            repositoryPath: receipt.repositoryPath,
            headBranch: receipt.headBranch,
            proposalID: receipt.proposalID,
            additional: [
                "commit_sha": receipt.commitSHA,
                "pr_number": "\(receipt.pullRequestNumber)",
                "pr_url": receipt.pullRequestURL,
                "result": receipt.source.rawValue
            ]
        ), level: .info, fieldMaxLength: 240)
    }

    private func logFailure(operation: String, proposalID: String?, error: Error) {
        var fields: [String: String] = [
            "operation": operation,
            "reason": String(error.localizedDescription.prefix(500))
        ]
        if let proposalID {
            fields["proposal_id"] = proposalID
        }
        AppLogger.audit(
            .gitAuthoringFailed,
            category: "Git",
            fields: fields,
            level: .error,
            fieldMaxLength: 500
        )
    }
}
