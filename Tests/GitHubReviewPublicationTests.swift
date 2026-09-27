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
        var responseURL = "https://github.com/example/repo/pull/12#pullrequestreview-42"
        var replacementOnNextGet: (URL, Data)?

        func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String {
            guard let hostnameIndex = arguments.firstIndex(of: "--hostname"),
                  arguments.indices.contains(hostnameIndex + 1),
                  arguments[hostnameIndex + 1] == "github.com" else {
                throw NSError(domain: "WrongGitHubHost", code: 1)
            }
            if arguments.contains("POST") {
                guard let inputIndex = arguments.firstIndex(of: "--input") else {
                    throw NSError(domain: "Test", code: 1)
                }
                postedPayloads.append(try Data(contentsOf: URL(fileURLWithPath: arguments[inputIndex + 1])))
                return "{\"id\":42,\"html_url\":\"\(responseURL)\",\"state\":\"COMMENTED\",\"commit_id\":\"\(GitHubReviewPublicationTests.head)\",\"submitted_at\":\"2026-09-25T00:00:00Z\"}"
            }
            if let (url, data) = replacementOnNextGet {
                replacementOnNextGet = nil
                try data.write(to: url, options: .atomic)
            }
            return "{\"state\":\"open\",\"head\":{\"sha\":\"\(head)\"}}"
        }

        func setHead(_ value: String) { head = value }
        func replaceOnNextGet(_ url: URL, with data: Data) { replacementOnNextGet = (url, data) }
        func postCount() -> Int { postedPayloads.count }
        func postedPayload() -> Data? { postedPayloads.first }
    }

    @Test("review files can be versioned for a later separate review")
    func recognizesVersionedReviewFiles() {
        #expect(GitHubReviewArtifactPolicy.isReviewFile("/tmp/pr1139_review.json"))
        #expect(GitHubReviewArtifactPolicy.isReviewFile("/tmp/pr1139_review_2.json"))
        #expect(!GitHubReviewArtifactPolicy.isReviewFile("/tmp/pr1139_review.txt"))
    }

    @Test("approval displays both ends of a multiline comment")
    func displaysMultilinePosition() {
        let comment = GitHubReviewPayload.Comment(
            path: "src/main.swift", line: 14, side: "RIGHT", body: "Fix this.",
            startLine: 12, startSide: "RIGHT"
        )
        #expect(GitHubReviewPublicationSheet.position(for: comment) ==
            "src/main.swift:12 · RIGHT → 14 · RIGHT")
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

    @Test("a confirmed review completes a task waiting for that external outcome")
    func confirmedReviewCompletesPendingTask() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        run.recordExternalOutcomePending()
        fixture.task.status = .pendingUser
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post the PR review comments",
            run: run
        ))
        try fixture.context.save()

        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        _ = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(fixture.task.status == .completed)
        #expect(run.typedStopReason == .completed)
    }

    @Test("publication sends the bytes verified before the final network metadata check")
    func postsRevalidatedBytesWhenFileChangesDuringCheck() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cli = FakeCLI()
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        await cli.replaceOnNextGet(fixture.file, with: Data("{\"body\":\"Unapproved\"}".utf8))
        _ = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(await cli.postedPayload() == fixture.data)
    }

    @Test("a confirmed post with a failed receipt save is not marked indeterminate")
    func confirmedPostWithReceiptSaveFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        run.recordExternalOutcomePending()
        fixture.task.status = .pendingUser
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post the PR review comments",
            run: run
        ))
        try fixture.context.save()
        let cli = FakeCLI()
        let service = GitHubReviewPublicationService(
            modelContext: fixture.context,
            cli: cli,
            saveReceipt: { _, _ in throw NSError(domain: "SaveFailure", code: 1) }
        )
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.publish(task: fixture.task, proposal: proposal)
        }
        #expect(await cli.postCount() == 1)
        #expect(GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
        #expect(!fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.receipt })
        #expect(!fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.indeterminate })
        #expect(fixture.task.status == .pendingUser)
        #expect(run.typedStopReason == .externalOutcomePending)
        try fixture.context.save()
        let persistedTask = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<AgentTask>()).first)
        #expect(persistedTask.status == .pendingUser)
        #expect(!persistedTask.events.contains { $0.type == GitHubReviewPublicationEventTypes.receipt })
    }

    @Test("canonical GitHub repository casing still yields a confirmed receipt")
    func acceptsCanonicalReceiptURL() async throws {
        let fixture = try makeFixture(goal: "Review https://github.com/Example/Repo/pull/12")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cli = FakeCLI()
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        let receipt = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(receipt.reviewID == 42)
    }

    @Test("Markdown PR links can supply the review target")
    func acceptsMarkdownLink() async throws {
        let fixture = try makeFixture(goal: "Review [PR](https://github.com/example/repo/pull/12)")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let proposal = try await GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
            .prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestNumber == 12)
        let angle = try makeFixture(goal: "Review <https://github.com/example/repo/pull/12>")
        defer { try? FileManager.default.removeItem(at: angle.root) }
        let angleProposal = try await GitHubReviewPublicationService(modelContext: angle.context, cli: FakeCLI())
            .prepare(task: angle.task, filePath: angle.file.path)
        #expect(angleProposal.pullRequestNumber == 12)
    }

    @Test("a later posting request chooses its PR instead of an older goal URL")
    func targetComesFromPostingRequest() async throws {
        let fixture = try makeFixture(goal: "Review https://github.com/example/repo/pull/11")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let posting = TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post comments to https://github.com/example/repo/pull/12",
            run: nil
        )
        posting.timestamp = Date(timeIntervalSince1970: 1_000)
        fixture.context.insert(posting)
        let followUp = TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "yes",
            run: nil
        )
        followUp.timestamp = Date(timeIntervalSince1970: 1_001)
        fixture.context.insert(followUp)
        try fixture.context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        let proposal = try await GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
            .prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestURL == "https://github.com/example/repo/pull/12")
    }

    @Test("an invalid earlier artifact does not hide a later valid proposal")
    func skipsUnusableCandidate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bad = fixture.file.deletingLastPathComponent().appendingPathComponent("pr12_review_old.json")
        try Data("{bad json".utf8).write(to: bad)
        let proposal = try await GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
            .prepareFirstAvailable(task: fixture.task, filePaths: [bad.path, fixture.file.path])
        #expect(proposal.filePath == fixture.file.path)
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

    @Test("posting intent binds the action to comments and honors negation")
    func publicationIntent() {
        #expect(GitHubReviewPublicationRequirement.requestsPublication(in: "Please add the comments to the PR"))
        #expect(GitHubReviewPublicationRequirement.requestsPublication(in: "Publish this review"))
        #expect(!GitHubReviewPublicationRequirement.requestsPublication(in: "Review this GitHub PR and add tests"))
        #expect(!GitHubReviewPublicationRequirement.requestsPublication(in: "Do not post this PR review"))
        #expect(!GitHubReviewPublicationRequirement.requestsPublication(in: "Review the PR without posting comments"))
    }

    @Test("unrelated follow-ups preserve posting intent until cancellation or receipt")
    func postingIntentSurvivesFollowUps() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(
            title: "Review",
            goal: "Post the PR review comments https://github.com/example/repo/pull/12"
        )
        context.insert(task)
        let followUp = TaskEvent(
            task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "yes", run: nil
        )
        followUp.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(followUp)
        try context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: task))

        let cancellation = TaskEvent(
            task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Do not post the PR review comments", run: nil
        )
        cancellation.timestamp = Date(timeIntervalSince1970: 1_001)
        context.insert(cancellation)
        try context.save()
        #expect(!GitHubReviewPublicationRequirement.isPending(task: task))

        let newRequest = TaskEvent(
            task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Please post the PR review comments", run: nil
        )
        newRequest.timestamp = Date(timeIntervalSince1970: 1_002)
        context.insert(newRequest)
        try context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: task))

        let receipt = TaskEvent.structuredPayloadEvent(
            task: task,
            type: GitHubReviewPublicationEventTypes.receipt,
            payload: GitHubReviewPublicationRecord(
                proposalID: "review", filePath: "/tmp/review.json",
                pullRequestURL: "https://github.com/example/repo/pull/12",
                reviewURL: "https://github.com/example/repo/pull/12#pullrequestreview-42",
                reviewID: 42
            ),
            run: nil
        )
        receipt.timestamp = Date(timeIntervalSince1970: 1_003)
        context.insert(receipt)
        try context.save()
        #expect(!GitHubReviewPublicationRequirement.isPending(task: task))
    }

    @Test("a PR publication receipt does not complete a task still awaiting review comments")
    func publicationReceiptRechecksReviewRequirement() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review and publish", goal: "Review https://github.com/example/repo/pull/12")
        let run = TaskRun(task: task)
        run.recordExternalOutcomePending()
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post the PR review comments",
            run: run
        ))
        let request = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(
                kind: .githubPullRequest, runID: run.id, message: "Publish draft PR"
            ),
            run: run
        )
        request.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(request)
        let publicationReceipt = TaskEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationReceipt,
            payload: "{}",
            run: run
        )
        publicationReceipt.timestamp = Date(timeIntervalSince1970: 1_001)
        context.insert(publicationReceipt)
        try context.save()

        #expect(!TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task, run: run, modelContext: context
        ))
        #expect(task.status != .completed)

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
        #expect(TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task, run: run, modelContext: context
        ))
    }

    @Test("a validation pause cannot be cleared by posting a GitHub review")
    func validationPauseRemainsPending() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Review https://github.com/example/repo/pull/12")
        let run = TaskRun(task: task)
        run.recordCompletionBlocked(stopReason: .validationContractFailed)
        context.insert(task)
        context.insert(run)
        try context.save()

        #expect(!TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task, run: run, modelContext: context
        ))
        #expect(run.typedStopReason == .validationContractFailed)
        #expect(task.status != .completed)
    }

    private func makeFixture(goal: String = "review this pr in detail https://github.com/example/repo/pull/12") throws -> (
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
        let task = AgentTask(title: "Review", goal: goal, workspace: workspace)
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
