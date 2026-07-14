import Foundation
import Testing
import ASTRAGitContracts
import ASTRAModels
@testable import ASTRA

@Suite("Task Git pull request publication")
@MainActor
struct TaskGitPullRequestPublishCoordinatorTests {
    @Test("Only task-owned paths inside the repository are selected")
    func taskOwnedPathsStayInsideRepository() {
        let repository = "/tmp/astra-publish/repo"

        let paths = TaskGitPullRequestPublishCoordinator.taskOwnedRelativePaths(
            [
                "/tmp/astra-publish/repo/Sources/App.swift",
                "Tests/AppTests.swift",
                "/tmp/astra-publish/other/Secret.txt",
                "../outside.txt",
                "Tests/AppTests.swift"
            ],
            repositoryPath: repository
        )

        #expect(paths == ["Sources/App.swift", "Tests/AppTests.swift"])
    }

    @Test("Live Git status keeps only dirty paths owned by the run")
    func selectedPathsKeepRunOwnershipBoundary() {
        let repository = "/tmp/astra-publish/repo"

        let paths = TaskGitPullRequestPublishCoordinator.reconciledSelectedPaths(
            recordedPaths: [
                "/tmp/astra-publish/repo/Sources/App.swift",
                "/tmp/astra-publish/repo/Sources/AlreadyClean.swift"
            ],
            statusFiles: [
                GitStatusFile(relativePath: "Sources/App.swift", status: " M", isStaged: false),
                GitStatusFile(relativePath: "Sources/Unrecorded.swift", status: "??", isStaged: false),
                GitStatusFile(relativePath: "Tests/UnrecordedTests.swift", status: "??", isStaged: false)
            ],
            repositoryPath: repository
        )

        #expect(paths == ["Sources/App.swift"])
        #expect(TaskGitPullRequestPublishCoordinator.unrecordedDirtyPaths(
            recordedPaths: [
                "/tmp/astra-publish/repo/Sources/App.swift",
                "/tmp/astra-publish/repo/Sources/AlreadyClean.swift"
            ],
            statusFiles: [
                GitStatusFile(relativePath: "Sources/App.swift", status: " M", isStaged: false),
                GitStatusFile(relativePath: "Sources/Unrecorded.swift", status: "??", isStaged: false),
                GitStatusFile(relativePath: "Tests/UnrecordedTests.swift", status: "??", isStaged: false)
            ],
            repositoryPath: repository
        ) == ["Sources/Unrecorded.swift", "Tests/UnrecordedTests.swift"])
    }

    @Test("A task-owned rename is selected without treating its old path as unrelated work")
    func taskOwnedRenameKeepsStatusRecordTogether() {
        let repository = "/tmp/astra-publish/repo"
        let statusFiles = [
            GitStatusFile(
                relativePath: "Sources/NewName.swift",
                status: "R ",
                isStaged: true,
                originalPath: "Sources/OldName.swift"
            )
        ]

        #expect(TaskGitPullRequestPublishCoordinator.reconciledSelectedPaths(
            recordedPaths: ["/tmp/astra-publish/repo/Sources/NewName.swift"],
            statusFiles: statusFiles,
            repositoryPath: repository
        ) == ["Sources/NewName.swift"])
        #expect(TaskGitPullRequestPublishCoordinator.unrecordedDirtyPaths(
            recordedPaths: ["/tmp/astra-publish/repo/Sources/NewName.swift"],
            statusFiles: statusFiles,
            repositoryPath: repository
        ).isEmpty)
    }

    @Test("Publication branch is deterministic and task-scoped")
    func branchIsDeterministic() {
        let task = AgentTask(title: "Fix PR Publication!", goal: "Create a pull request")

        let first = TaskGitPullRequestPublishCoordinator.headBranch(for: task)
        let second = TaskGitPullRequestPublishCoordinator.headBranch(for: task)

        #expect(first == second)
        #expect(first.hasPrefix("astra/fix-pr-publication-"))
        #expect(first.hasSuffix(task.id.uuidString.lowercased().prefix(8)))
    }

    @Test("Checkpoint store survives a new store instance")
    func durableCheckpointRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-publish-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proposalID = String(repeating: "a", count: 64)
        let checkpoint = GitPullRequestPublishCheckpoint(
            proposalID: proposalID,
            repositoryPath: "/tmp/repo",
            remote: "origin",
            baseBranch: "main",
            headBranch: "astra/test",
            commitSHA: String(repeating: "b", count: 40),
            state: .pushed
        )

        let writer = FileGitPullRequestPublishCheckpointStore(directoryURL: root)
        try await writer.save(checkpoint)
        let reader = FileGitPullRequestPublishCheckpointStore(directoryURL: root)

        #expect(await reader.checkpoint(for: proposalID) == checkpoint)
        await reader.removeCheckpoint(for: proposalID)
        #expect(await reader.checkpoint(for: proposalID) == nil)
    }

    @Test("Restart resumes the persisted proposal only when its checkpoint exists")
    func persistedProposalRequiresMatchingCheckpoint() async throws {
        let task = AgentTask(title: "Publish", goal: "Create the pull request")
        let run = TaskRun(task: task)
        let proposal = GitPullRequestPublishProposal(
            proposalID: String(repeating: "a", count: 64),
            repositoryPath: "/tmp/repo",
            remote: "origin",
            remoteURL: "https://github.com/example/repo.git",
            baseBranch: "main",
            baseSHA: String(repeating: "b", count: 40),
            headBranch: "astra/publish",
            expectedHeadSHA: String(repeating: "c", count: 40),
            selectedPaths: ["Astra/App.swift"],
            selectedFileStates: [],
            commitMessage: "Publish",
            pullRequestTitle: "Publish",
            pullRequestBody: "Body",
            isDraft: true,
            authorizationRequirement: .explicitApproval,
            existingPullRequest: nil
        )
        let proposedEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationProposed,
            payload: proposal,
            run: run
        )
        task.runs.append(run)
        task.events.append(proposedEvent)

        let store = InMemoryGitPullRequestPublishCheckpointStore()
        #expect(await TaskGitPullRequestPublishCoordinator.persistedProposalForResume(
            task: task,
            runID: run.id,
            checkpointStore: store
        ) == nil)

        try await store.save(GitPullRequestPublishCheckpoint(
            proposalID: proposal.proposalID,
            repositoryPath: proposal.repositoryPath,
            remote: proposal.remote,
            baseBranch: proposal.baseBranch,
            headBranch: proposal.headBranch,
            commitSHA: String(repeating: "d", count: 40),
            state: .pushed
        ))

        #expect(await TaskGitPullRequestPublishCoordinator.persistedProposalForResume(
            task: task,
            runID: run.id,
            checkpointStore: store
        ) == proposal)
    }
}
