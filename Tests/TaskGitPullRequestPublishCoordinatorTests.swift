import Foundation
import Testing
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
        await writer.save(checkpoint)
        let reader = FileGitPullRequestPublishCheckpointStore(directoryURL: root)

        #expect(await reader.checkpoint(for: proposalID) == checkpoint)
        await reader.removeCheckpoint(for: proposalID)
        #expect(await reader.checkpoint(for: proposalID) == nil)
    }
}
