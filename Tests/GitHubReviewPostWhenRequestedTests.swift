import CryptoKit
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// Spec decision 15 for a requested GitHub review: in Auto the agent asks ASTRA
/// to post a review file it wrote, and ASTRA posts it then, through every check
/// the Post review sheet makes, returning the link. What is eligible is the
/// file the request names, holding the bytes the broker read — never "a review
/// file the run touched", which is how an earlier Ask run's pending review got
/// posted by Auto. Ask and Custom keep the sheet.
@Suite("GitHub review posted when requested", .serialized)
@MainActor
struct GitHubReviewPostWhenRequestedTests {
    nonisolated private static let head = String(repeating: "a", count: 40)

    @Test("Auto posts the file the agent names, with the bytes it named, and returns the link")
    func autoPostsTheNamedFile() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI()

        let outcome = await fixture.handler(level: .autonomous, cli: cli)
            .postGitHubReview(fixture.request(for: fixture.file))

        #expect(outcome == .performed(BrokeredExternalActionReceipt(
            identifier: "review 42", url: "https://github.com/example/repo/pull/12#pullrequestreview-42"
        )))
        #expect(await cli.postedPayloads() == [fixture.data])
        let receipt = try #require(fixture.records(GitHubReviewPublicationEventTypes.receipt).first)
        #expect(receipt.authorization == .autoPolicy)
        #expect(GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
        #expect(!GitHubReviewPublicationRequirement.isPending(task: fixture.task))

        let event = try #require(fixture.task.events.first { $0.type == GitHubReviewPublicationEventTypes.receipt })
        let shown = try #require(ExternalActionRecordProjection.record(
            type: event.type, payload: event.payload, eventID: event.id, timestamp: event.timestamp
        ))
        #expect(shown.authorization == .autoPolicy)
    }

    @Test("Ask and Custom post nothing and reach no GitHub endpoint")
    func askAndCustomKeepTheSheet() async throws {
        for level in [AgentPolicyLevel.review, .custom, .network] {
            let fixture = try Fixture()
            let cli = FakeCLI()

            let outcome = await fixture.handler(level: level, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

            #expect(outcome == .awaitingReview, "\(level.rawValue)")
            #expect(await cli.callCount() == 0)
            #expect(fixture.task.events.isEmpty)
            // The sheet's path is unchanged: the file is still offered.
            #expect(GitHubReviewPublicationService.pendingCandidatePath(
                task: fixture.task, filePaths: [fixture.file.path]
            ) == fixture.file.path)
        }
    }

    @Test("A file that changed after the agent asked is not posted")
    func changedFileIsNotPosted() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI()
        let request = fixture.request(for: fixture.file)
        try Data("""
            {"event":"REQUEST_CHANGES","commit_id":"\(Self.head)","body":"Something else entirely"}
            """.utf8).write(to: fixture.file)

        let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(request)

        guard case let .refused(message) = outcome else {
            Issue.record("Expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("changed after you asked"))
        #expect(await cli.postedPayloads().isEmpty)
        #expect(!GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
    }

    @Test("Auto posts a review only when the user asked for one to be posted")
    func noPostingRequestNoPost() async throws {
        let fixture = try Fixture(goal: "review this pr in detail https://github.com/example/repo/pull/12")
        let cli = FakeCLI()

        let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

        #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription))
        #expect(await cli.callCount() == 0)
    }

    /// A shorthand request names no repository; `prepare` binds it to the
    /// workspace's GitHub origin. Before that binding the request does not
    /// read as pending, so checking that first refused what the user asked for.
    @Test("A shorthand request is bound to the workspace's origin and posted")
    func shorthandRequestIsBoundAndPosted() async throws {
        let fixture = try Fixture(goal: "Post a review on PR 12")
        let cli = FakeCLI()

        let outcome = await fixture.handler(level: .autonomous, cli: cli, origin: "https://github.com/example/repo.git")
            .postGitHubReview(fixture.request(for: fixture.file))

        #expect(outcome == .performed(BrokeredExternalActionReceipt(
            identifier: "review 42", url: "https://github.com/example/repo/pull/12#pullrequestreview-42"
        )))
        #expect(await cli.postedPayloads() == [fixture.data])
    }

    /// One request, one review: a second file asked for after the first was
    /// posted is not posted on the strength of a request already answered.
    @Test("A request that was already answered does not post a second review")
    func answeredRequestDoesNotPostAgain() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI()
        let handler = fixture.handler(level: .autonomous, cli: cli)
        _ = await handler.postGitHubReview(fixture.request(for: fixture.file))
        let second = fixture.file.deletingLastPathComponent().appendingPathComponent("pr12_review_2.json")
        try Data("""
            {"event":"COMMENT","commit_id":"\(Self.head)","body":"Another review"}
            """.utf8).write(to: second)

        let outcome = await handler.postGitHubReview(fixture.request(for: second))

        #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription))
        #expect(await cli.postCount() == 1)
    }

    /// The broad posting heuristic reads "add" and "leave", which is fine for
    /// offering the sheet. Auto posts without it, so it needs post, publish or
    /// submit — "add review comments to the file" is an edit, not consent.
    @Test("Auto posts only on an explicit request to post, publish or submit")
    func autoNeedsAnExplicitPostingRequest() async throws {
        let url = "https://github.com/example/repo/pull/12"
        for goal in ["Add review comments to the review file for \(url)", "Leave a review on \(url)"] {
            let fixture = try Fixture(goal: goal)
            let cli = FakeCLI()
            #expect(GitHubReviewPublicationRequirement.postingRequest(task: fixture.task) != nil, "\(goal)")

            let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

            #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription), "\(goal)")
            #expect(await cli.callCount() == 0, "\(goal)")
        }
        for goal in ["Submit a review on \(url)", "Please publish the review comments on \(url)"] {
            let fixture = try Fixture(goal: goal)
            let cli = FakeCLI()

            let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

            guard case .performed = outcome else {
                Issue.record("\(goal): expected a post, got \(outcome)")
                continue
            }
        }
    }

    @Test("An uncertain post is never posted a second time")
    func uncertainPostIsNotRepeated() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI(failsPost: true)
        let handler = fixture.handler(level: .autonomous, cli: cli)
        let request = fixture.request(for: fixture.file)

        let first = await handler.postGitHubReview(request)
        let second = await handler.postGitHubReview(request)

        guard case .uncertain = first, case .uncertain = second else {
            Issue.record("Expected both to be uncertain, got \(first) and \(second)")
            return
        }
        #expect(await cli.postCount() == 1)
    }

    /// The regression decision 15 names: an earlier Ask run left a review for
    /// the user, and Auto posted it because the path was touched. Now only the
    /// file a request names is eligible.
    @Test("An earlier run's pending review is not posted when Auto asks for another file")
    func earlierPendingReviewIsNotPosted() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI()
        let later = fixture.file.deletingLastPathComponent().appendingPathComponent("pr12_review_2.json")
        let laterData = Data("""
            {"event":"COMMENT","commit_id":"\(Self.head)","body":"The second review"}
            """.utf8)
        try laterData.write(to: later)

        let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: later))

        guard case .performed = outcome else {
            Issue.record("Expected the named file to be posted, got \(outcome)")
            return
        }
        #expect(await cli.postedPayloads() == [laterData])
        #expect(!GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
        #expect(GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: later.path))
    }

    /// The dock asks about artifact paths, which can spell the task folder
    /// through `/private`. A review Auto posted must not come back under the
    /// other spelling, where a second Post would be a second review.
    @Test("The dock never re-offers a review Auto posted, however its path is spelled")
    func postedReviewIsNotReofferedUnderAnotherSpelling() async throws {
        let fixture = try Fixture(throughSymlink: true)
        _ = await fixture.handler(level: .autonomous, cli: FakeCLI()).postGitHubReview(fixture.request(for: fixture.file))
        let resolved = fixture.file.resolvingSymlinksInPath().path
        let unresolved = URL(fileURLWithPath: TaskWorkspaceAccess(task: fixture.task).taskFolder)
            .appendingPathComponent("pr12_review.json").path
        try #require(resolved != unresolved, "The fixture must spell the task folder two ways")

        for spelling in [resolved, unresolved, fixture.file.path] {
            #expect(GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: spelling), "\(spelling)")
            #expect(GitHubReviewPublicationService.pendingCandidatePath(task: fixture.task, filePaths: [spelling]) == nil)
        }
        // A different file is still a different file.
        let other = URL(fileURLWithPath: resolved).deletingLastPathComponent().appendingPathComponent("pr12_review_2.json").path
        #expect(!GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: other))
    }

    /// The default macOS volume ignores case, and the review-file rule accepts
    /// either, so one file must not be postable twice under two casings.
    @Test("A review posted under one casing is not posted again under another")
    func postedReviewIsNotRepostedUnderAnotherCasing() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI()
        let handler = fixture.handler(level: .autonomous, cli: cli)
        _ = await handler.postGitHubReview(fixture.request(for: fixture.file))
        // The user asks again, so only the dispatch record stands between the
        // same file and a second review.
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on https://github.com/example/repo/pull/12 again"
        ))
        let shouted = fixture.request(for: fixture.file)

        _ = await handler.postGitHubReview(GitHubReviewPostRequest(
            fileName: "PR12_REVIEW.JSON", contentDigest: shouted.contentDigest
        ))

        #expect(await cli.postCount() == 1)
        #expect(GitHubReviewPublicationService.hasDispatched(
            task: fixture.task,
            filePath: fixture.file.deletingLastPathComponent().appendingPathComponent("PR12_REVIEW.JSON").path
        ))
    }

    @Test("Two spellings of one task-folder file are the same review file")
    func sameFileAcrossSpellings() {
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot("/var/folders/x/task")
        #expect(GitHubReviewArtifactPolicy.sameFile("/var/folders/x/task/pr1_review.json", "/var/folders/x/task/./pr1_review.json", root: root))
        #expect(GitHubReviewArtifactPolicy.sameFile("/var/folders/x/task/pr1_review.json", "/var/folders/x/task/PR1_Review.JSON", root: root))
        #expect(!GitHubReviewArtifactPolicy.sameFile("/var/folders/x/task/pr1_review.json", "/var/folders/x/task/pr2_review.json", root: root))
        #expect(!GitHubReviewArtifactPolicy.sameFile("/elsewhere/pr1_review.json", "/var/folders/x/task/pr1_review.json", root: root))
    }

    /// The runtime guard stops a host tool call whose input keys are outside
    /// its schema, so a request the broker accepts but the guard does not is a
    /// request the agent is told exists and then stopped for.
    @Test("The runtime guard admits a post_review call's input keys")
    func runtimeGuardAdmitsPostReviewKeys() throws {
        let descriptor = try #require(HostControlPlaneMCPProjection.runtimeSupportToolDescriptors(
            for: .claudeCode, tools: ["github"]
        ).first)
        for key in ["operation", GitHubReviewHostControlOperations.reviewFileKey, "arguments"] {
            #expect(descriptor.allowedInputKeys.contains(key), "\(key)")
            #expect(!descriptor.deniedInputKeys.contains(key), "\(key)")
        }
        #expect(!descriptor.allowedInputKeys.contains("body"))
        #expect(!descriptor.allowedInputKeys.contains("file"))
    }

    // MARK: - Fixture

    private actor FakeCLI: GitHubReviewCLI {
        private let failsPost: Bool
        private var payloads: [Data] = []
        private var calls = 0

        init(failsPost: Bool = false) {
            self.failsPost = failsPost
        }

        func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String {
            calls += 1
            if arguments.contains("POST") {
                let inputIndex = try #require(arguments.firstIndex(of: "--input"))
                payloads.append(try Data(contentsOf: URL(fileURLWithPath: arguments[inputIndex + 1])))
                if failsPost { throw URLError(.networkConnectionLost) }
                return #"{"id":42,"html_url":"https://github.com/example/repo/pull/12#pullrequestreview-42","state":"COMMENTED","commit_id":"\#(GitHubReviewPostWhenRequestedTests.head)","submitted_at":"2026-10-09T00:00:00Z"}"#
            }
            return #"{"state":"open","head":{"sha":"\#(GitHubReviewPostWhenRequestedTests.head)"}}"#
        }

        func postedPayloads() -> [Data] { payloads }
        func postCount() -> Int { payloads.count }
        func callCount() -> Int { calls }
    }

    @MainActor
    final class Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun
        let file: URL
        let data: Data

        init(goal: String = "Post a review on https://github.com/example/repo/pull/12", throughSymlink: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-review-when-requested-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // The workspace reached through a link, so the task folder has two
            // spellings that are one directory.
            var workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
            if throughSymlink {
                let link = root.appendingPathComponent("linked-workspace", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspacePath)
                workspacePath = link
            }
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            let workspace = Workspace(name: "Review", primaryPath: workspacePath.path)
            task = AgentTask(title: "Review", goal: goal, workspace: workspace)
            run = TaskRun(task: task)
            context.insert(workspace)
            context.insert(task)
            context.insert(run)
            try context.save()
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            file = URL(fileURLWithPath: folder).appendingPathComponent("pr12_review.json")
            data = Data("""
                {"event":"COMMENT","commit_id":"\(GitHubReviewPostWhenRequestedTests.head)","body":"Summary",\
                "comments":[{"path":"src/main.swift","line":12,"side":"RIGHT","body":"Fix this."}]}
                """.utf8)
            try data.write(to: file)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func handler(
            level: AgentPolicyLevel,
            cli: some GitHubReviewCLI,
            origin: String? = nil
        ) -> BrokeredExternalActionHandler {
            BrokeredExternalActionHandler(
                modelContext: context,
                taskID: task.id,
                runID: run.id,
                policyLevel: level,
                makeReviewService: { context in
                    GitHubReviewPublicationService(modelContext: context, cli: cli, originURL: { _ in origin })
                }
            )
        }

        /// What the broker sends: the bare name and the digest of the bytes on disk now.
        func request(for url: URL) -> GitHubReviewPostRequest {
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            return GitHubReviewPostRequest(
                fileName: url.lastPathComponent,
                contentDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
        }

        func records(_ type: String) -> [GitHubReviewPublicationRecord] {
            task.events.filter { $0.type == type }.compactMap {
                try? JSONDecoder().decode(GitHubReviewPublicationRecord.self, from: Data($0.payload.utf8))
            }
        }
    }
}
