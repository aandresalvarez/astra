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
        var pullRequestState = "open"
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
            return "{\"state\":\"\(pullRequestState)\",\"head\":{\"sha\":\"\(head)\"}}"
        }

        func setHead(_ value: String) { head = value }
        func setPullRequestState(_ value: String) { pullRequestState = value }
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

    @Test("reversed multiline comments are rejected before dispatch")
    func rejectsReversedMultilineComment() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = Data("""
            {"event":"COMMENT","commit_id":"\(Self.head)","body":"Summary","comments":[{"path":"src/main.swift","start_line":14,"start_side":"RIGHT","line":12,"side":"RIGHT","body":"Fix this."}]}
            """.utf8)
        try invalid.write(to: fixture.file)
        let cli = FakeCLI()
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        }
        #expect(!GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
        #expect(await cli.postCount() == 0)
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

    @Test("a confirmed post recovers its receipt after the first save fails")
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
        let receipt = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(await cli.postCount() == 1)
        #expect(receipt.reviewID == 42)
        #expect(GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
        #expect(fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.receiptRecovery })
        #expect(!fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.indeterminate })
        #expect(fixture.task.status == .completed)
        #expect(run.typedStopReason == .completed)
        try fixture.context.save()
        let persistedTask = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<AgentTask>()).first)
        #expect(persistedTask.status == .completed)
        #expect(persistedTask.events.contains { $0.type == GitHubReviewPublicationEventTypes.receiptRecovery })
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

    @Test("a shorthand PR request strips a clone URL suffix from the task goal")
    func resolvesShorthandFromGoalRepository() async throws {
        let fixture = try makeFixture(goal: "Review https://github.com/example/repo.git")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12",
            run: nil
        ))
        try fixture.context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        let proposal = try await GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
            .prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestURL == "https://github.com/example/repo/pull/12")
    }

    @Test("a shorthand PR request can name its repository directly")
    func resolvesShorthandFromRequestRepository() async throws {
        let fixture = try makeFixture(goal: "Review the changes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12 in https://github.com/example/repo",
            run: nil
        ))
        try fixture.context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        let service = GitHubReviewPublicationService(
            modelContext: fixture.context,
            cli: FakeCLI(),
            originURL: { _ in nil }
        )
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestURL == "https://github.com/example/repo/pull/12")
    }

    @Test("a numbered review file can complete a repository-only task target")
    func resolvesNumberedFileFromGoalRepository() async throws {
        let fixture = try makeFixture(goal: "Review https://github.com/example/repo")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = GitHubReviewPublicationService(
            modelContext: fixture.context,
            cli: FakeCLI(),
            originURL: { _ in nil }
        )
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestURL == "https://github.com/example/repo/pull/12")
    }

    @Test("a shorthand PR request uses the workspace origin when the goal has no repository")
    func resolvesShorthandFromOrigin() async throws {
        let fixture = try makeFixture(goal: "Review the changes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12",
            run: nil
        ))
        try fixture.context.save()
        #expect(!GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        let service = GitHubReviewPublicationService(
            modelContext: fixture.context,
            cli: FakeCLI(),
            originURL: { _ in "https://github.com/example/repo" }
        )
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestURL == "https://github.com/example/repo/pull/12")
    }

    @Test("completion binds an origin-backed target before the review gate")
    func originTargetIsDurableBeforeCompletion() async throws {
        let fixture = try makeFixture(goal: "Review the changes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12",
            run: run
        ))
        try fixture.context.save()

        let completed = await TaskSuccessfulCompletionService.apply(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            successPayload: "Review prepared",
            permissionPolicy: .restricted,
            reviewOriginURL: { _ in "https://github.com/example/repo" }
        )
        try fixture.context.save()
        #expect(!completed)
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        #expect(fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.targetBound })
        let service = GitHubReviewPublicationService(
            modelContext: fixture.context,
            cli: FakeCLI(),
            originURL: { _ in nil }
        )
        let proposal = try await service.prepare(task: fixture.task, filePath: fixture.file.path)
        #expect(proposal.pullRequestURL == "https://github.com/example/repo/pull/12")
        _ = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(!GitHubReviewPublicationRequirement.isPending(task: fixture.task))
    }

    @Test("an unresolved GitHub origin keeps the requested review as a completion gate")
    func unresolvedOriginKeepsReviewGate() async throws {
        let fixture = try makeFixture(goal: "Review the changes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12",
            run: run
        ))
        let completed = await TaskSuccessfulCompletionService.apply(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            successPayload: "Review prepared",
            permissionPolicy: .restricted,
            reviewOriginURL: { _ in nil }
        )
        try fixture.context.save()
        #expect(!completed)
        #expect(GitHubReviewPublicationRequirement.hasUnresolvedTarget(task: fixture.task))
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        #expect(fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.targetUnresolved })
    }

    @Test("manual approval resolves an origin target before completing a paused task")
    func manualApprovalBindsOriginTarget() async throws {
        let fixture = try makeFixture(goal: "Review the changes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        run.recordExternalOutcomePending()
        fixture.task.status = .pendingUser
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12",
            run: run
        ))
        try fixture.context.save()

        let coordinator = TaskLifecycleCoordinator(
            modelContext: fixture.context,
            taskQueue: TaskQueue(),
            reviewOriginURL: { _ in "https://github.com/example/repo" }
        )
        let approval = try #require(coordinator.approveTask(fixture.task))
        await approval.value
        #expect(fixture.task.status == .pendingUser)
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        #expect(fixture.task.events.contains { $0.type == GitHubReviewPublicationEventTypes.targetBound })
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.Task.approved.rawValue })
    }

    @Test("a separate external receipt rechecks an origin-backed review")
    func externalReceiptBindsOriginTarget() async throws {
        let fixture = try makeFixture(goal: "Review the changes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        run.recordExternalOutcomePending()
        fixture.task.status = .pendingUser
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12",
            run: run
        ))
        try fixture.context.save()

        let completed = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            reviewOriginURL: { _ in "https://github.com/example/repo" }
        )
        #expect(!completed)
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        #expect(fixture.task.status == .pendingUser)
    }

    @Test("a review request does not also queue draft PR creation")
    func reviewDoesNotQueueDraftPR() async throws {
        let fixture = try makeFixture(goal: "Publish this PR review https://github.com/example/repo/pull/12")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        #expect(!AskGitPullRequestWorkflowPolicy.isActive(
            task: fixture.task, permissionPolicy: .restricted, contextText: ""
        ))
        let completed = await TaskSuccessfulCompletionService.apply(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            successPayload: "Review prepared",
            permissionPolicy: .restricted
        )
        try fixture.context.save()
        #expect(!completed)
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        #expect(!fixture.task.events.contains {
            $0.type == TaskExternalOutcomeEventTypes.publicationRequested
        })
    }

    @Test("an invalid earlier artifact does not hide a later valid proposal")
    func skipsUnusableCandidate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bad = fixture.file.deletingLastPathComponent().appendingPathComponent("pr12_review_old.json")
        try Data("{bad json".utf8).write(to: bad)
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI())
        let proposal = try await service
            .prepareFirstAvailable(task: fixture.task, filePaths: [bad.path, fixture.file.path])
        #expect(proposal.filePath == fixture.file.path)
        #expect(GitHubReviewPublicationService.hasDismissed(task: fixture.task, filePath: bad.path))
        #expect(GitHubReviewPublicationService.pendingCandidatePath(
            task: fixture.task, filePaths: [bad.path, fixture.file.path]
        ) == fixture.file.path)
        _ = try await service.publish(task: fixture.task, proposal: proposal)
        #expect(GitHubReviewPublicationService.pendingCandidatePath(
            task: fixture.task, filePaths: [bad.path, fixture.file.path]
        ) == nil)
        let persistedTask = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<AgentTask>()).first)
        #expect(GitHubReviewPublicationService.hasDismissed(task: persistedTask, filePath: bad.path))
    }

    @Test("a closed pull request proposal is removed from the ready cache")
    func dismissesClosedPullRequest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cli = FakeCLI()
        await cli.setPullRequestState("closed")
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await service.prepareFirstAvailable(task: fixture.task, filePaths: [fixture.file.path])
        }
        #expect(GitHubReviewPublicationService.hasDismissed(task: fixture.task, filePath: fixture.file.path))
        #expect(GitHubReviewPublicationService.pendingCandidatePath(
            task: fixture.task, filePaths: [fixture.file.path]
        ) == nil)
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
                proposalID: "other-review", filePath: "/tmp/other-review.json",
                pullRequestURL: "https://github.com/example/repo/pull/11",
                reviewURL: "https://github.com/example/repo/pull/11#pullrequestreview-41",
                reviewID: 41
            ),
            run: run
        ))
        try context.save()
        #expect(TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run).shouldBlockCompletion)

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
        #expect(!GitHubReviewPublicationRequirement.requestsPublication(in: "Please post no comments on this PR"))
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

    @Test("pronoun cancellation clears a pending review without removing unrelated follow-ups")
    func pronounCancellation() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Post the review on https://github.com/example/repo/pull/12")
        context.insert(task)
        let cancel = TaskEvent(
            task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "don't post it", run: nil
        )
        cancel.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(cancel)
        try context.save()
        #expect(!GitHubReviewPublicationRequirement.isPending(task: task))

        let newRequest = TaskEvent(
            task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Please post the review", run: nil
        )
        newRequest.timestamp = Date(timeIntervalSince1970: 1_001)
        context.insert(newRequest)
        try context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: task))

        let cancelAgain = TaskEvent(
            task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "cancel that", run: nil
        )
        cancelAgain.timestamp = Date(timeIntervalSince1970: 1_002)
        context.insert(cancelAgain)
        try context.save()
        #expect(!GitHubReviewPublicationRequirement.isPending(task: task))
    }

    @Test("plan-mode messages can request and cancel GitHub review publication")
    func planModePublicationIntent() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Review https://github.com/example/repo/pull/12")
        context.insert(task)
        context.insert(TaskEvent(
            task: task,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "Post the PR review comments"
        ))
        try context.save()
        #expect(GitHubReviewPublicationRequirement.isPending(task: task))

        context.insert(TaskEvent(
            task: task,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "Do not post the PR review comments"
        ))
        try context.save()
        #expect(!GitHubReviewPublicationRequirement.isPending(task: task))
    }

    @Test("a PR publication receipt does not complete a task still awaiting review comments")
    func publicationReceiptRechecksReviewRequirement() async throws {
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

        let blockedBeforeReview = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task, run: run, modelContext: context
        )
        #expect(!blockedBeforeReview)
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
        let completedAfterReview = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task, run: run, modelContext: context
        )
        #expect(completedAfterReview)
    }

    @Test("a validation pause cannot be cleared by posting a GitHub review")
    func validationPauseRemainsPending() async throws {
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

        let completed = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
            task: task, run: run, modelContext: context
        )
        #expect(!completed)
        #expect(run.typedStopReason == .validationContractFailed)
        #expect(task.status != .completed)
    }

    // Auto asks nothing (docs/specs/2026-10-07-permission-levels-harmonization.md):
    // the review the user asked to post goes out when the run finishes, through
    // the same service checks, and the receipt says Auto posted it.
    @Test("Auto posts the requested review when the run finishes and records that Auto did")
    func autoPostsTheRequestedReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try postingRun(fixture, request: "Post the PR review comments")
        let cli = FakeCLI()

        let completed = await TaskSuccessfulCompletionService.apply(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            successPayload: "Review prepared",
            permissionPolicy: .autonomous,
            reviewPublicationService: GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        )

        #expect(completed)
        #expect(await cli.postCount() == 1)
        #expect(await cli.postedPayload() == fixture.data)
        #expect(!GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        let receipt = try #require(fixture.task.events.first { $0.type == GitHubReviewPublicationEventTypes.receipt })
        let record = try #require(ExternalActionRecordProjection.record(
            type: receipt.type, payload: receipt.payload, eventID: receipt.id, timestamp: receipt.timestamp
        ))
        #expect(record.authorization == .autoPolicy)
    }

    @Test("Ask and Custom leave the requested review for the user")
    func askLeavesTheReviewForTheUser() async throws {
        for policy in [PermissionPolicy.restricted, .interactive] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let run = try postingRun(fixture, request: "Post the PR review comments")
            let cli = FakeCLI()

            let completed = await TaskSuccessfulCompletionService.apply(
                task: fixture.task,
                run: run,
                modelContext: fixture.context,
                successPayload: "Review prepared",
                permissionPolicy: policy,
                reviewPublicationService: GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
            )

            #expect(!completed, "\(policy.rawValue)")
            #expect(await cli.postCount() == 0, "\(policy.rawValue)")
            #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        }
    }

    @Test("Auto posts nothing nobody asked to post")
    func autoPostsNothingUnrequested() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try postingRun(fixture, request: "Thanks, that analysis is enough")
        let cli = FakeCLI()

        _ = await TaskSuccessfulCompletionService.apply(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            successPayload: "Review prepared",
            permissionPolicy: .autonomous,
            reviewPublicationService: GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        )

        #expect(await cli.postCount() == 0)
    }

    @Test("Auto leaves a review whose pull request moved on for the user and says why")
    func autoLeavesAStaleReviewWaiting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try postingRun(fixture, request: "Post the PR review comments")
        let cli = FakeCLI()
        await cli.setHead(String(repeating: "b", count: 40))

        let completed = await TaskSuccessfulCompletionService.apply(
            task: fixture.task,
            run: run,
            modelContext: fixture.context,
            successPayload: "Review prepared",
            permissionPolicy: .autonomous,
            reviewPublicationService: GitHubReviewPublicationService(modelContext: fixture.context, cli: cli)
        )

        #expect(!completed)
        #expect(await cli.postCount() == 0)
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
        #expect(fixture.task.events.contains { $0.payload.hasPrefix("Auto could not post the GitHub review") })
    }

    private func postingRun(
        _ fixture: (root: URL, container: ModelContainer, context: ModelContext, task: AgentTask, file: URL, data: Data),
        request: String
    ) throws -> TaskRun {
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: request,
            run: run
        ))
        try fixture.context.save()
        return run
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
