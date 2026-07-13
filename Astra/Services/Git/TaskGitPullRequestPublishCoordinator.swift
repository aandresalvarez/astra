import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskGitPullRequestPublishCoordinatorError: LocalizedError, Equatable {
    case noPendingPublication
    case repositoryUnavailable
    case commitUnavailable
    case noTaskOwnedChanges

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
        }
    }
}

@MainActor
final class TaskGitPullRequestPublishCoordinator {
    private let modelContext: ModelContext
    private let git: GitRepositoryOperating

    init(
        modelContext: ModelContext,
        git: GitRepositoryOperating = GitService.shared
    ) {
        self.modelContext = modelContext
        self.git = git
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

        let selectedPaths = Self.taskOwnedRelativePaths(
            run.fileChanges.map(\.path),
            repositoryPath: repositoryPath
        )
        guard !selectedPaths.isEmpty else {
            throw TaskGitPullRequestPublishCoordinatorError.noTaskOwnedChanges
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
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationProposed,
            payload: proposal,
            run: run
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext
        )
        return proposal
    }

    func publish(
        task: AgentTask,
        proposal: GitPullRequestPublishProposal
    ) async throws -> GitPullRequestPublishReceipt {
        guard TaskExternalOutcomeRequirementResolver.hasPendingGitHubPullRequest(task: task) else {
            throw TaskGitPullRequestPublishCoordinatorError.noPendingPublication
        }
        let run = task.runs.sorted(by: TaskRun.isChronologicallyOrdered).last
        let authorization = GitPublishAuthorization(
            repository: proposal.repositoryPath,
            baseBranch: proposal.baseBranch,
            headBranch: proposal.headBranch,
            expectedHeadSHA: proposal.expectedHeadSHA,
            requestDigest: proposal.proposalID,
            isDraft: proposal.isDraft
        )
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationApproved,
            payload: authorization,
            run: run
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext
        )

        do {
            let receipt = try await service(for: task).publish(
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
            TaskStateMachine.completeFromUserApproval(task, modelContext: modelContext)
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext
            )
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

    private func service(for task: AgentTask) -> GitPullRequestPublishService {
        service(checkpointStore: checkpointStore(for: task))
    }

    private func service(
        checkpointStore: any GitPullRequestPublishCheckpointStoring
    ) -> GitPullRequestPublishService {
        GitPullRequestPublishService(git: git, checkpointStore: checkpointStore)
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
