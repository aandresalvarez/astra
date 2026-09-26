import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("GitHub review publication", .serialized)
@MainActor
struct GitHubReviewPublicationTests {
    nonisolated private static let head = String(repeating: "a", count: 40)

    private actor FakeCLI: GitHubReviewCLI {
        var head = GitHubReviewPublicationTests.head
        var postedPayloads: [Data] = []

        func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String {
            if arguments.contains("POST") {
                guard let inputIndex = arguments.firstIndex(of: "--input") else {
                    throw NSError(domain: "Test", code: 1)
                }
                postedPayloads.append(try Data(contentsOf: URL(fileURLWithPath: arguments[inputIndex + 1])))
                return "{\"id\":42,\"html_url\":\"https://github.com/example/repo/pull/12#pullrequestreview-42\",\"state\":\"COMMENTED\",\"commit_id\":\"\(GitHubReviewPublicationTests.head)\",\"submitted_at\":\"2026-09-25T00:00:00Z\"}"
            }
            return "{\"state\":\"open\",\"head\":{\"sha\":\"\(head)\"}}"
        }

        func setHead(_ value: String) { head = value }
        func postCount() -> Int { postedPayloads.count }
        func postedPayload() -> Data? { postedPayloads.first }
    }

    @Test("review files can be versioned for a later separate review")
    func recognizesVersionedReviewFiles() {
        #expect(GitHubReviewArtifactPolicy.isReviewFile("/tmp/pr1139_review.json"))
        #expect(GitHubReviewArtifactPolicy.isReviewFile("/tmp/pr1139_review_2.json"))
        #expect(!GitHubReviewArtifactPolicy.isReviewFile("/tmp/pr1139_review.txt"))
    }

    @Test("a summary-only review does not require an inline comments array")
    func acceptsSummaryOnlyReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data("{\"event\":\"COMMENT\",\"commit_id\":\"\(Self.head)\",\"body\":\"Summary only\"}".utf8)
        try data.write(to: fixture.file)
        let proposal = try await GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
            .prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.payload.comments.isEmpty)
    }

    @Test("hidden API fields are rejected before the user can approve a review")
    func rejectsUnreviewedFields() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data("{\"event\":\"COMMENT\",\"commit_id\":\"\(Self.head)\",\"body\":\"Summary\",\"unshown_field\":\"value\"}".utf8)
        try data.write(to: fixture.file)
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        }
    }

    @Test("review is posted once from exactly the approved bytes and leaves a receipt")
    func publishesOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cli = FakeCLI()
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.payload.comments.count == 1)
        let receipt = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(receipt.reviewURL == "https://github.com/example/repo/pull/12#pullrequestreview-42")
        #expect(await cli.postCount() == 1)
        #expect(await cli.postedPayload() == fixture.data)
        #expect(GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.publish(task: fixture.task, proposal: proposal)
        }
        #expect(await cli.postCount() == 1)
    }

    @Test("changed PR head or edited payload stops publication before dispatch")
    func rejectsStaleReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cli = FakeCLI()
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        await cli.setHead(String(repeating: "b", count: 40))
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.publish(task: fixture.task, proposal: proposal)
        }
        #expect(await cli.postCount() == 0)
        await cli.setHead(Self.head)
        try Data(fixture.data + Data(" ".utf8)).write(to: fixture.file)
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.publish(task: fixture.task, proposal: proposal)
        }
        #expect(await cli.postCount() == 0)
    }

    @Test("explicit request to add PR comments needs a GitHub receipt")
    func completionRequiresReceipt() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "review this pr in detail https://github.com/example/repo/pull/12")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "can you add the comments to the pr?",
            run: run
        ))
        try context.save()
        let blocked = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)
        #expect(blocked.gate == .requiredExternalOutcome)
        #expect(blocked.shouldBlockCompletion)

        context.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: GitHubReviewPublicationEventTypes.receipt,
            payload: GitHubReviewPublicationRecord(
                proposalID: "review", filePath: "/tmp/review.json",
                pullRequestURL: "https://github.com/example/repo/pull/12",
                reviewURL: "https://github.com/example/repo/pull/12#pullrequestreview-42",
                reviewID: 42
            ),
            run: run
        ))
        try context.save()
        let allowed = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)
        #expect(allowed.canComplete)
    }

    private func makeFixture() throws -> (
        root: URL, container: ModelContainer, context: ModelContext, task: AgentTask, file: URL, data: Data
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-review-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Review", primaryPath: root.path)
        let task = AgentTask(title: "Review", goal: "review this pr in detail https://github.com/example/repo/pull/12", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        try context.save()
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let file = URL(fileURLWithPath: folder).appendingPathComponent("pr12_review.json")
        let data = Data("""
            {"event":"COMMENT","commit_id":"\(Self.head)","body":"Summary",\
            "comments":[{"path":"src/main.swift","line":12,"side":"RIGHT","body":"Fix this."}]}
            """.utf8)
        try data.write(to: file)
        return (root, container, context, task, file, data)
    }
}
