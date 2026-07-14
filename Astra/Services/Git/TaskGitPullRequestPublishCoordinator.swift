import Foundation
import SwiftData
import ASTRACore
import ASTRAGitContracts
import ASTRAModels
import ASTRAPersistence

enum TaskGitPullRequestPublishCoordinatorError: LocalizedError, Equatable {
    case noPendingPublication
    case repositoryUnavailable
    case commitUnavailable
    case noTaskOwnedChanges
    case unownedDirtyChanges([String])

    var errorDescription: String? {
        switch self {
        case .noPendingPublication:
            "This task no longer has a pending pull request publication."
        case .repositoryUnavailable:
            "ASTRA could not resolve the task's Git repository and remote."
        case .commitUnavailable:
            "ASTRA could not resolve the exact starting commit."
        case .noTaskOwnedChanges:
            "The latest run has no changed files inside the task repository to publish."
        case let .unownedDirtyChanges(paths):
            "The repository contains dirty files ASTRA cannot attribute to this task: \(paths.joined(separator: ", ")). Commit, stash, or revert them before publishing."
        }
    }
}

@MainActor
final class TaskGitPullRequestPublishCoordinator {
    typealias DurableEventSave = @MainActor (
        _ workspace: Workspace?,
        _ modelContext: ModelContext,
        _ taskID: UUID,
        _ auditFields: [String: String]
    ) throws -> Void

    private let modelContext: ModelContext
    private let git: GitRepositoryOperating
    private let durableEventSave: DurableEventSave

    init(
        modelContext: ModelContext,
        git: GitRepositoryOperating = GitService.shared,
        durableEventSave: @escaping DurableEventSave = { workspace, modelContext, taskID, auditFields in
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace,
                modelContext: modelContext,
                taskID: taskID,
                auditFields: auditFields
            )
        }
    ) {
        self.modelContext = modelContext
        self.git = git
        self.durableEventSave = durableEventSave
    }

    func prepare(task: AgentTask) async throws -> GitPullRequestPublishProposal {
        guard let requirement = TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task),
              let run = task.runs.first(where: { $0.id == requirement.runID }) else {
            throw TaskGitPullRequestPublishCoordinatorError.noPendingPublication
        }

        let checkpointStore = checkpointStore(for: task)
        if let persistedProposal = await Self.persistedProposalForResume(
            task: task,
            runID: run.id,
            checkpointStore: checkpointStore
        ) {
            return persistedProposal
        }

        let repositoryPath = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        guard !repositoryPath.isEmpty,
              let remote = await git.getDefaultRemote(at: repositoryPath),
              await git.getRemoteURL(at: repositoryPath, remote: remote) != nil else {
            throw TaskGitPullRequestPublishCoordinatorError.repositoryUnavailable
        }
        guard let expectedHeadSHA = await git.getCommitSHA("HEAD", at: repositoryPath) else {
            throw TaskGitPullRequestPublishCoordinatorError.commitUnavailable
        }

        // The run summary is presentation data and may be capped. Git status is
        // the authoritative publication scope so every currently dirty path is
        // disclosed in the review instead of being silently omitted.
        let recordedPaths = run.fileChanges.map(\.path)
        let statusFiles = await git.getStatusFiles(at: repositoryPath)
        let unownedDirtyPaths = Self.unrecordedDirtyPaths(
            recordedPaths: recordedPaths,
            statusFiles: statusFiles,
            repositoryPath: repositoryPath
        )
        guard unownedDirtyPaths.isEmpty else {
            throw TaskGitPullRequestPublishCoordinatorError.unownedDirtyChanges(unownedDirtyPaths)
        }
        let selectedPaths = Self.reconciledSelectedPaths(
            recordedPaths: recordedPaths,
            statusFiles: statusFiles,
            repositoryPath: repositoryPath
        )
        guard !selectedPaths.isEmpty else {
            throw TaskGitPullRequestPublishCoordinatorError.noTaskOwnedChanges
        }
        let preexistingDirtySelection = Self.preexistingDirtySelection(
            task: task,
            runID: run.id,
            repositoryPath: repositoryPath,
            selectedPaths: selectedPaths
        )
        guard preexistingDirtySelection.isEmpty else {
            throw TaskGitPullRequestPublishCoordinatorError.unownedDirtyChanges(preexistingDirtySelection)
        }

        let baseBranch = await git.getDefaultBaseBranch(at: repositoryPath, remote: remote)
        let headBranch = Self.headBranch(for: task)
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = title.isEmpty ? "ASTRA task \(task.id.uuidString.prefix(8))" : title
        let body = """
        ## Summary

        \(task.goal.trimmingCharacters(in: .whitespacesAndNewlines))

        ---
        Published through ASTRA task `\(task.id.uuidString)` after exact user review.
        """
        let publishRequest = GitPullRequestPublishRequest(
            repositoryPath: repositoryPath,
            remote: remote,
            baseBranch: baseBranch,
            headBranch: headBranch,
            expectedHeadSHA: expectedHeadSHA,
            selectedPaths: selectedPaths,
            commitMessage: effectiveTitle,
            pullRequestTitle: effectiveTitle,
            pullRequestBody: body,
            authorizationRequirement: .explicitApproval
        )
        let proposal = try await service(checkpointStore: checkpointStore).prepare(publishRequest)
        let previousUpdatedAt = task.updatedAt
        let proposedEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationProposed,
            payload: proposal,
            run: run
        )
        try persistBeforeExternalBoundary(
            proposedEvent,
            task: task,
            previousUpdatedAt: previousUpdatedAt,
            operation: "git_publish_proposal"
        )
        return proposal
    }

    func publish(
        task: AgentTask,
        proposal: GitPullRequestPublishProposal
    ) async throws -> GitPullRequestPublishReceipt {
        guard let requirement = TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task),
              let run = task.runs.first(where: { $0.id == requirement.runID }) else {
            throw TaskGitPullRequestPublishCoordinatorError.noPendingPublication
        }
        let authorization = GitPublishAuthorization(
            repository: proposal.repositoryPath,
            baseBranch: proposal.baseBranch,
            headBranch: proposal.headBranch,
            expectedHeadSHA: proposal.expectedHeadSHA,
            requestDigest: proposal.proposalID,
            isDraft: proposal.isDraft
        )
        let previousUpdatedAt = task.updatedAt
        let approvalEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationApproved,
            payload: authorization,
            run: run
        )
        try persistBeforeExternalBoundary(
            approvalEvent,
            task: task,
            previousUpdatedAt: previousUpdatedAt,
            operation: "git_publish_approval"
        )

        do {
            let checkpointStore = checkpointStore(for: task)
            let receipt = try await service(checkpointStore: checkpointStore).publish(
                proposal,
                approval: GitPullRequestPublishApproval(proposalID: proposal.proposalID)
            )
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: TaskExternalOutcomeEventTypes.publicationReceipt,
                payload: receipt,
                run: run
            ))
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Task.approved,
                payload: "Published draft pull request #\(receipt.pullRequestNumber): \(receipt.pullRequestURL)",
                run: run
            ))
            _ = TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
                task: task,
                run: run,
                modelContext: modelContext
            )
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "git_publish_receipt"]
            )
            // The checkpoint remains recovery authority until the receipt and
            // resulting task transition are durably committed together.
            await checkpointStore.removeCheckpoint(for: proposal.proposalID)
            return receipt
        } catch {
            let payload = TaskEvent.payloadString([
                "proposal_id": proposal.proposalID,
                "message": String(error.localizedDescription.prefix(1_000))
            ])
            modelContext.insert(TaskEvent(
                task: task,
                type: TaskExternalOutcomeEventTypes.publicationFailed,
                payload: payload,
                run: run
            ))
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext
            )
            throw error
        }
    }

    private func service(
        checkpointStore: any GitPullRequestPublishCheckpointStoring
    ) -> GitPullRequestPublishService {
        GitPullRequestPublishService(git: git, checkpointStore: checkpointStore)
    }

    /// Proposal and approval events are recovery authority. They must become
    /// durable before the UI exposes an approval or the service crosses a Git
    /// mutation boundary. A failed save removes the in-memory event so a later
    /// unrelated save cannot accidentally persist an unacknowledged action.
    func persistBeforeExternalBoundary(
        _ event: TaskEvent,
        task: AgentTask,
        previousUpdatedAt: Date,
        operation: String
    ) throws {
        modelContext.insert(event)
        do {
            try durableEventSave(
                task.workspace,
                modelContext,
                task.id,
                ["operation": operation]
            )
        } catch {
            task.events.removeAll { $0.id == event.id }
            modelContext.delete(event)
            task.updatedAt = previousUpdatedAt
            throw error
        }
    }

    private func checkpointStore(
        for task: AgentTask
    ) -> FileGitPullRequestPublishCheckpointStore {
        let taskFolder = TaskWorkspaceAccess(task: task).canonicalTaskFolder
        let checkpointDirectory = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent("git-publish-checkpoints", isDirectory: true)
        return FileGitPullRequestPublishCheckpointStore(
            directoryURL: checkpointDirectory
        )
    }

    /// A proposal becomes resume authority only after the publish service has
    /// written its matching checkpoint. This avoids reviving an abandoned
    /// review proposal while preserving the exact pre-commit approval across
    /// app restarts after commit or push.
    static func persistedProposalForResume(
        task: AgentTask,
        runID: UUID,
        checkpointStore: any GitPullRequestPublishCheckpointStoring
    ) async -> GitPullRequestPublishProposal? {
        let proposedEvents = task.events
            .filter {
                $0.type == TaskExternalOutcomeEventTypes.publicationProposed
                    && $0.run?.id == runID
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                return lhs.id.uuidString > rhs.id.uuidString
            }

        for event in proposedEvents {
            guard let data = event.payload.data(using: .utf8),
                  let proposal = try? TaskEventPayloadCodec.makeDecoder().decode(
                    GitPullRequestPublishProposal.self,
                    from: data
                  ),
                  await checkpointStore.checkpoint(for: proposal.proposalID) != nil else {
                continue
            }
            return proposal
        }
        return nil
    }

    static func taskOwnedRelativePaths(
        _ paths: [String],
        repositoryPath: String
    ) -> [String] {
        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let repositoryPrefix = repositoryURL.path.hasSuffix("/")
            ? repositoryURL.path
            : repositoryURL.path + "/"

        var seen = Set<String>()
        return paths.compactMap { rawPath in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let relativePath: String
            if trimmed.hasPrefix("/") {
                let filePath = URL(fileURLWithPath: trimmed)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                guard filePath.hasPrefix(repositoryPrefix) else { return nil }
                relativePath = String(filePath.dropFirst(repositoryPrefix.count))
            } else {
                relativePath = trimmed
            }
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  seen.insert(relativePath).inserted else { return nil }
            return relativePath
        }.sorted()
    }

    /// Keeps the durable run change set as the ownership boundary while
    /// filtering out paths that are no longer dirty.
    static func reconciledSelectedPaths(
        recordedPaths: [String],
        statusFiles: [GitStatusFile],
        repositoryPath: String
    ) -> [String] {
        let recorded = Set(taskOwnedRelativePaths(recordedPaths, repositoryPath: repositoryPath))
        return statusFiles.compactMap { file in
            let paths = taskOwnedRelativePaths(
                [file.relativePath, file.originalPath].compactMap { $0 },
                repositoryPath: repositoryPath
            )
            return paths.contains(where: recorded.contains) ? file.relativePath : nil
        }.sorted()
    }

    /// Dirty files without durable run ownership are never silently swept into
    /// a publication. They may be pre-existing user work, so ambiguity is a
    /// blocking condition rather than implicit consent.
    static func unrecordedDirtyPaths(
        recordedPaths: [String],
        statusFiles: [GitStatusFile],
        repositoryPath: String
    ) -> [String] {
        let recorded = Set(taskOwnedRelativePaths(recordedPaths, repositoryPath: repositoryPath))
        return statusFiles.compactMap { file in
            let paths = taskOwnedRelativePaths(
                [file.relativePath, file.originalPath].compactMap { $0 },
                repositoryPath: repositoryPath
            )
            return paths.contains(where: recorded.contains) ? nil : file.relativePath
        }.sorted()
    }

    /// A path that was already dirty before the provider started cannot be
    /// published safely at path granularity: staging it would also include the
    /// user's pre-existing hunks. The durable launch baseline therefore keeps
    /// the entire path outside the typed publication authority.
    static func preexistingDirtyPaths(
        task: AgentTask,
        runID: UUID,
        repositoryPath: String
    ) -> [String] {
        let baseline = task.events
            .filter {
                $0.run?.id == runID
                    && $0.type == TaskExternalOutcomeEventTypes.publicationWorkspaceBaseline
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .last
            .flatMap { event -> TaskGitPublicationWorkspaceBaseline? in
                guard let data = event.payload.data(using: .utf8) else { return nil }
                return try? TaskEventPayloadCodec.makeDecoder().decode(
                    TaskGitPublicationWorkspaceBaseline.self,
                    from: data
                )
            }
        guard let baseline, baseline.runID == runID else { return [] }
        return taskOwnedRelativePaths(baseline.dirtyPaths, repositoryPath: repositoryPath)
    }

    static func preexistingDirtySelection(
        task: AgentTask,
        runID: UUID,
        repositoryPath: String,
        selectedPaths: [String]
    ) -> [String] {
        let selected = Set(selectedPaths)
        return preexistingDirtyPaths(
            task: task,
            runID: runID,
            repositoryPath: repositoryPath
        ).filter(selected.contains)
    }

    static func headBranch(for task: AgentTask) -> String {
        let slug = task.title
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let boundedSlug = String((slug.isEmpty ? "task" : slug).prefix(40))
        return "astra/\(boundedSlug)-\(task.id.uuidString.lowercased().prefix(8))"
    }
}
