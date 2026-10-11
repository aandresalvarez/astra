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
            // Only the request is recorded, so the sheet offers this file —
            // even when it was never registered as an artifact.
            #expect(fixture.task.events.map(\.type) == [GitHubReviewPublicationEventTypes.requested])
            #expect(GitHubReviewPublicationService.pendingCandidatePath(task: fixture.task, filePaths: []) == fixture.file.path)
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

        // The agent does what it was told: the replacement goes out under a
        // new name. The changed file is retired, so the dock does not offer
        // it afterwards as a second review.
        let replacement = fixture.file.deletingLastPathComponent().appendingPathComponent("pr12_review_2.json")
        try fixture.data.write(to: replacement)
        let posted = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: replacement))
        guard case .performed = posted else {
            Issue.record("Expected the replacement to post, got \(posted)")
            return
        }
        #expect(await cli.postCount() == 1)
        #expect(GitHubReviewPublicationService.pendingCandidatePath(
            task: fixture.task, filePaths: [fixture.file.path, replacement.path]
        ) == nil)
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

    /// "PR 12" after a goal that links pull requests in more than one
    /// repository means the one linked as 12, never the workspace origin's
    /// PR 12; when two repositories have a 12 there, nothing is posted.
    @Test("A shorthand request resolves against the goal's links and never guesses the origin")
    func shorthandRequestUsesTheGoalsLinks() async throws {
        let goal = "Review https://github.com/acme/one/pull/12 against https://github.com/acme/two/pull/7"
        let fixture = try Fixture(goal: goal)
        fixture.context.insert(TaskEvent(
            task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Post the review to PR 12"
        ))
        let cli = FakeCLI()

        let outcome = await fixture.handler(level: .autonomous, cli: cli, origin: "https://github.com/example/repo.git")
            .postGitHubReview(fixture.request(for: fixture.file))

        guard case .performed = outcome else {
            Issue.record("Expected the goal's PR 12 to be posted, got \(outcome)")
            return
        }
        let called = await cli.calledArguments()
        #expect(!called.isEmpty && called.allSatisfy { $0.contains("acme/one") && !$0.contains("example/repo") }, "\(called)")

        let ambiguous = try Fixture(goal: "Review https://github.com/acme/one/pull/12 and https://github.com/acme/two/pull/12")
        ambiguous.context.insert(TaskEvent(
            task: ambiguous.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Post the review to PR 12"
        ))
        let ambiguousCLI = FakeCLI()
        let refused = await ambiguous.handler(level: .autonomous, cli: ambiguousCLI, origin: "https://github.com/example/repo.git")
            .postGitHubReview(ambiguous.request(for: ambiguous.file))
        guard case .refused = refused else {
            Issue.record("Expected an ambiguous target to be refused, got \(refused)")
            return
        }
        #expect(await ambiguousCLI.postCount() == 0)
        #expect(!GitHubReviewPublicationRequirement.needsOriginTargetBinding(task: ambiguous.task))
    }

    /// A request that names two pull requests has no single target: neither
    /// the linked one, nor the numbered one, nor the goal's or the file's
    /// number is chosen — not by Auto, and not as the sheet's proposal.
    @Test("A request naming two pull requests is not posted to either")
    func conflictingPullRequestsAreNotPosted() async throws {
        let linkedGoal = "Post a review on https://github.com/example/repo/pull/12"
        for (goal, message) in [
            (linkedGoal, "Review https://github.com/example/repo/pull/12, then post the review to PR 13"),
            (linkedGoal, "Review PR 12, then post the review to PR 13"),
            ("Review PR 12", "Review PR 12, then post the review to PR 13")
        ] {
            let fixture = try Fixture(goal: goal)
            fixture.context.insert(TaskEvent(
                task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: message
            ))
            let cli = FakeCLI()

            let outcome = await fixture.handler(level: .autonomous, cli: cli, origin: "https://github.com/example/repo.git")
                .postGitHubReview(fixture.request(for: fixture.file))

            guard case .refused = outcome else {
                Issue.record("\(message): expected a refusal, got \(outcome)")
                continue
            }
            #expect(await cli.postCount() == 0, "\(message)")
            #expect(!GitHubReviewPublicationRequirement.needsOriginTargetBinding(task: fixture.task), "\(message)")
            let sheet = GitHubReviewPublicationService(
                modelContext: fixture.context, cli: FakeCLI(), originURL: { _ in "https://github.com/example/repo.git" }
            )
            await #expect(throws: GitHubReviewPublicationError.self, "\(message)") {
                try await sheet.prepare(task: fixture.task, filePath: fixture.file.path)
            }
        }
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

    /// Consent for Auto is a positive list — a command to post — so a request
    /// that defers, conditions or pauses the post is left for the sheet. The
    /// errors this allows are reviews not posted, never reviews posted.
    @Test("Auto takes only a command to post now as consent")
    func autoConsentIsACommandToPostNow() {
        let url = "https://github.com/example/repo/pull/12"
        for command in [
            "Post a review on \(url)", "Please post the review on \(url)", "Review \(url) and post the review",
            "Review \(url), then submit the review", "Can you publish the review comments on \(url)?",
            "Post a review on \(url) again", "Post the review to PR 12", "Post your final code review on \(url)",
            // Review work and words that keep it a command, around the command.
            "Draft the review for \(url) and then post the review", "First, post the review on \(url)",
            "Thanks! Please post the review on \(url)", "Review PR #12. Post the review."
        ] {
            #expect(GitHubReviewPublicationRequirement.commandsPosting(command), "\(command)")
        }
        for notYet in [
            "Ask me before posting the review on \(url)", "Hold off on posting the review on \(url)",
            "Post the review on \(url) after I approve it", "Post the review on \(url), but ask me first",
            "Don't post the review on \(url) yet", "Wait before you post the review on \(url)",
            "Draft the review comments for \(url) and let me post them", "I will post the review on \(url) myself",
            "Add review comments to the review file for \(url)", "Leave a review on \(url)",
            "Post the review on \(url) once the tests pass", "Stop posting the review on \(url)",
            "I'll review \(url) and post the review myself", "Someone else should post the review on \(url)",
            "Post the review on \(url), then wait", "Post the draft review on \(url) first",
            "Review \(url); I'll post the review later",
            // The file is posted whole, so asking for part of it is not consent.
            "Publish the comments on \(url) except the review summary", "Post the review on \(url), but not the summary",
            "Post only the inline comments on \(url)", "Post the review on \(url) without the summary",
            // A condition stated first is still a condition.
            "When I approve, post the review on \(url)", "If the tests pass, post the review on \(url)",
            "Once CI is green, then post the review on \(url)",
            // Between the verb and the review, where only the whole-message reading sees it.
            "Post later the review on \(url)", "Post when ready the review on \(url)", "Post not yet the review on \(url)",
            "Post the draft review on \(url)", "Post the review on \(url). Don\u{2019}t.",
            // A kind of comment is part of the file, which also carries a summary and a verdict.
            "Post the inline comments on \(url)", "Post the code comments", "Post the inline review comments on \(url)",
            // A link is exactly a pull request's URL: nothing rides along on it.
            "Post the review on \(url),later", "Post the review on \(url)/files", "Review \(url),later and post the review",
            // A retraction in the same message, which the latest-message rule cannot see.
            "Post the review on \(url). Actually, don't.", "Post the review on \(url). Never mind.",
            "Post the review on \(url) — no, scratch that", "Post the review on \(url); stop, leave it",
            // Somewhere other than the pull request.
            "Post the review to Slack", "Publish the review in the team channel",
            "Post the review on \(url) and in Slack",
            // Any other sentence: Auto does not read it to decide it changes
            // nothing about the post, so the review is left for the sheet.
            "Post the review. The requested destination is Slack.", "Post the review on \(url). Slack is where it goes",
            "First, post the review on \(url), then summarize it", "Post the review on \(url); I will prepare the follow-up",
            "Review \(url) and summarize it, then post the review", "Post the review on \(url). Check: Slack gets it",
            "Draft the review for Slack and post the review"
        ] {
            #expect(!GitHubReviewPublicationRequirement.commandsPosting(notYet), "\(notYet)")
        }
    }

    /// Auto acts on the user's latest word: whatever follows a command to post
    /// — a reversal it could never list, or anything else — leaves the review
    /// for the sheet, where Ask's broader reading still offers it.
    @Test("Auto posts only when the request is the user's latest instruction")
    func autoActsOnTheLatestInstructionOnly() async throws {
        for later in ["Actually, no", "Never mind", "Thanks! Also look at the flaky test"] {
            let fixture = try Fixture()
            fixture.context.insert(TaskEvent(
                task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: later
            ))
            let cli = FakeCLI()

            let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

            #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription), "\(later)")
            #expect(await cli.callCount() == 0, "\(later)")
        }
        // A command restated last is the latest word again.
        let fixture = try Fixture()
        let thanks = TaskEvent(task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Thanks")
        let restated = TaskEvent(
            task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post the review on https://github.com/example/repo/pull/12"
        )
        thanks.timestamp = Date(timeIntervalSinceNow: -60)
        restated.timestamp = Date(timeIntervalSinceNow: -30)
        fixture.context.insert(thanks)
        fixture.context.insert(restated)
        let outcome = await fixture.handler(level: .autonomous, cli: FakeCLI()).postGitHubReview(fixture.request(for: fixture.file))
        guard case .performed = outcome else {
            Issue.record("Expected the restated command to post, got \(outcome)")
            return
        }
    }

    /// "…, then post it" names the review first and posts it by pronoun. The
    /// review must come first, and for Auto nothing may follow but a GitHub
    /// destination: "post it to the channel" is never a pull-request review.
    @Test("A request that posts the review by pronoun is a request, and for Auto only toward GitHub")
    func referentialPostingRequests() async throws {
        let url = "https://github.com/example/repo/pull/12"
        for command in ["Review PR #12, then post it.", "Review \(url) and post it on GitHub",
                        "Please review \(url) and then submit it"] {
            #expect(GitHubReviewPublicationRequirement.requestsPublication(in: command), "\(command)")
            #expect(GitHubReviewPublicationRequirement.commandsPosting(command), "\(command)")
        }
        for notConsent in ["Review \(url) and post it to the team channel", "Post it", "Fix the bug and post it",
                           "Review PR #12. Don't post it yet", "Review \(url) and I'll post it"] {
            #expect(!GitHubReviewPublicationRequirement.commandsPosting(notConsent), "\(notConsent)")
        }
        #expect(!GitHubReviewPublicationRequirement.requestsPublication(in: "Fix the bug and post it"),
                "a pronoun with no review before it is not a review request")

        let fixture = try Fixture(goal: "Review PR #12, then post it.")
        let cli = FakeCLI()
        let outcome = await fixture.handler(level: .autonomous, cli: cli, origin: "https://github.com/example/repo.git")
            .postGitHubReview(fixture.request(for: fixture.file))
        guard case .performed = outcome else {
            Issue.record("Expected the referential request to post, got \(outcome)")
            return
        }
        #expect(await cli.postCount() == 1)
    }

    /// The broker told the agent the user would see this exact review, so the
    /// sheet must open on it, not on an older review file that sorts first.
    @Test("Below Auto the sheet offers the file the agent asked to post, ahead of older reviews")
    func askOffersTheRequestedFile() async throws {
        let fixture = try Fixture()
        let older = fixture.file
        let requested = older.deletingLastPathComponent().appendingPathComponent("pr12_review_2.json")
        let requestedData = Data("""
            {"event":"COMMENT","commit_id":"\(Self.head)","body":"The review the agent asked to post"}
            """.utf8)
        try requestedData.write(to: requested)

        _ = await fixture.handler(level: .review, cli: FakeCLI()).postGitHubReview(fixture.request(for: requested))

        #expect(GitHubReviewPublicationService.pendingCandidatePath(task: fixture.task, filePaths: [older.path]) == requested.path)
        let proposal = try await GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI(), originURL: { _ in nil })
            .prepareFirstAvailable(task: fixture.task, filePaths: [older.path])
        #expect(proposal.filePath == requested.path)
        #expect(proposal.validatedData == requestedData)
    }

    /// The request recorded a digest: different bytes under that name later
    /// are not the review the agent asked about, under any spelling of the
    /// path, so the sheet never shows them as that review.
    @Test("Below Auto a requested file that changed afterwards is not offered as the requested review")
    func askRefusesARequestedFileThatChanged() async throws {
        let fixture = try Fixture(throughSymlink: true)
        _ = await fixture.handler(level: .review, cli: FakeCLI()).postGitHubReview(fixture.request(for: fixture.file))
        try Data("""
            {"event":"REQUEST_CHANGES","commit_id":"\(Self.head)","body":"Something the agent wrote afterwards"}
            """.utf8).write(to: fixture.file)
        let service = GitHubReviewPublicationService(modelContext: fixture.context, cli: FakeCLI(), originURL: { _ in nil })

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: fixture.task, filePaths: [fixture.file.resolvingSymlinksInPath().path])
        }
        #expect(GitHubReviewPublicationService.hasDismissed(task: fixture.task, filePath: fixture.file.path))
        #expect(GitHubReviewPublicationService.pendingCandidatePath(task: fixture.task, filePaths: [fixture.file.path]) == nil)
    }

    /// The review file is agent-writable: what is checked must be what is read,
    /// and neither a FIFO nor an oversized file may block or flood the app.
    @Test("A review file swapped for a FIFO or an oversized file is refused, not read")
    func reviewFileIsReadThroughOneBoundedDescriptor() async throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.file)
        #expect(mkfifo(fixture.file.path, 0o600) == 0)
        // A reader that opened the FIFO blocking would wait for a writer
        // forever; this one arrives late and never blocks, so such a read
        // fails the time check below instead of hanging the suite.
        let fifoPath = fixture.file.path
        Thread {
            Thread.sleep(forTimeInterval: 5)
            let writer = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }.start()

        let started = Date()
        let fifo = await fixture.handler(level: .autonomous, cli: FakeCLI()).postGitHubReview(
            GitHubReviewPostRequest(fileName: "pr12_review.json", contentDigest: String(repeating: "0", count: 64))
        )
        #expect(Date().timeIntervalSince(started) < 4, "opening the FIFO waited for a writer")
        guard case .refused = fifo else {
            Issue.record("Expected a refusal for a FIFO, got \(fifo)")
            return
        }

        // A valid review padded past the limit: only the size bound refuses
        // it. The same review padded to just under the limit posts.
        try FileManager.default.removeItem(at: fixture.file)
        try (fixture.data + Data(repeating: 0x20, count: 256 * 1024)).write(to: fixture.file)
        let largeCLI = FakeCLI()
        let large = await fixture.handler(level: .autonomous, cli: largeCLI).postGitHubReview(fixture.request(for: fixture.file))
        guard case .refused = large else {
            Issue.record("Expected a refusal for an oversized file, got \(large)")
            return
        }
        #expect(await largeCLI.callCount() == 0)

        let control = try Fixture()
        try (control.data + Data(repeating: 0x20, count: 256 * 1024 - control.data.count)).write(to: control.file)
        let fits = await control.handler(level: .autonomous, cli: FakeCLI()).postGitHubReview(control.request(for: control.file))
        guard case .performed = fits else {
            Issue.record("Expected a review at the limit to post, got \(fits)")
            return
        }
    }

    /// A swap between checking the file and reading it cannot be staged
    /// deterministically, so the shape of the read is pinned instead: one
    /// descriptor, opened without following a link or blocking, checked with
    /// `fstat`, and nothing that reopens the path.
    @Test("The review file is read through one bounded descriptor")
    func reviewReadUsesOneDescriptor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Git/GitHubReviewPublicationService.swift"), encoding: .utf8
        )
        let readPayload = try #require(source.range(of: "private func readPayload(")).lowerBound
        let body = String(source[readPayload...].prefix(1_500))
        #expect(body.contains("readBoundedRegularFile("))
        for reopening in ["Data(contentsOf:", "attributesOfItem", "FileHandle("] {
            #expect(!body.contains(reopening), "\(reopening)")
        }
        let helper = try #require(source.range(of: "private static func readBoundedRegularFile(")).lowerBound
        let helperBody = String(source[helper...].prefix(1_500))
        for required in ["O_NOFOLLOW", "O_NONBLOCK", "fstat(", "S_IFREG"] {
            #expect(helperBody.contains(required), "\(required)")
        }
    }

    /// The broker was bound to a run; a post that outlives the wait must not
    /// put its dispatch and receipt on a run that started after it.
    @Test("A post records on the run the broker was bound to, not the latest one")
    func postRecordsOnTheBoundRun() async throws {
        let fixture = try Fixture()
        let later = TaskRun(task: fixture.task)
        later.startedAt = fixture.run.startedAt.addingTimeInterval(60)
        fixture.context.insert(later)
        try fixture.context.save()
        // The premise: without the binding, "the latest run" is the other one.
        try #require(fixture.task.runs.max(by: { $0.startedAt < $1.startedAt })?.id == later.id)

        let outcome = await fixture.handler(level: .autonomous, cli: FakeCLI()).postGitHubReview(fixture.request(for: fixture.file))

        guard case .performed = outcome else {
            Issue.record("Expected a post, got \(outcome)")
            return
        }
        for type in [GitHubReviewPublicationEventTypes.dispatched, GitHubReviewPublicationEventTypes.receipt] {
            let event = try #require(fixture.task.events.first { $0.type == type })
            #expect(event.run?.id == fixture.run.id, "\(type)")
        }
    }

    /// A broker bound to a run ASTRA can no longer find has no run to record
    /// a post under, and the latest run is not a stand-in for it: nothing is
    /// posted and the review is left for the sheet.
    @Test("Auto posts nothing when the run the broker was bound to is gone")
    func missingBoundRunPostsNothing() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI()
        let handler = BrokeredExternalActionHandler(
            modelContext: fixture.context,
            taskID: fixture.task.id,
            runID: UUID(),
            policyLevel: .autonomous,
            makeReviewService: { context in
                GitHubReviewPublicationService(modelContext: context, cli: cli, originURL: { _ in nil })
            }
        )

        let outcome = await handler.postGitHubReview(fixture.request(for: fixture.file))

        #expect(outcome == .awaitingReview)
        #expect(await cli.callCount() == 0)
        #expect(fixture.records(GitHubReviewPublicationEventTypes.dispatched).isEmpty)
    }

    /// Auto posts while a request is open, so every way the user calls it off
    /// has to close it — the noun forms too, and a stopping verb before the
    /// posting one, which the broad pattern used to read as a request.
    @Test("A request the user called off is never posted by Auto")
    func cancelledRequestIsNotPosted() async throws {
        for cancellation in ["Cancel the review", "Stop the review.", "Actually, withdraw the comments",
                             "stop posting the review", "Don't post it", "cancel that"] {
            let fixture = try Fixture()
            fixture.context.insert(TaskEvent(
                task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: cancellation
            ))
            let cli = FakeCLI()

            let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

            #expect(!GitHubReviewPublicationRequirement.isPending(task: fixture.task), "\(cancellation)")
            #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription), "\(cancellation)")
            #expect(await cli.callCount() == 0, "\(cancellation)")
        }
        // Talk that does not call it off leaves it open.
        let fixture = try Fixture()
        fixture.context.insert(TaskEvent(
            task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Also stop the build warnings in the meantime"
        ))
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
    }

    /// "Review PR #12" in the goal and a later "Post the review" name one pull
    /// request between them; the binding has to read the goal's number, or the
    /// request never reads as open and Auto refuses what the user asked for.
    @Test("A follow-up post request is bound to the goal's pull request")
    func followUpRequestUsesTheGoalsNumber() async throws {
        let fixture = try Fixture(goal: "Review PR #12")
        fixture.context.insert(TaskEvent(
            task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Post the review"
        ))
        let cli = FakeCLI()

        let outcome = await fixture.handler(level: .autonomous, cli: cli, origin: "https://github.com/example/repo.git")
            .postGitHubReview(fixture.request(for: fixture.file))

        #expect(outcome == .performed(BrokeredExternalActionReceipt(
            identifier: "review 42", url: "https://github.com/example/repo/pull/12#pullrequestreview-42"
        )))
        #expect(await cli.postCount() == 1)
    }

    /// A post that outlives the broker's wait must not go out under a request
    /// the user made after it began: the newer request is for whatever the
    /// agent writes next, not for the file this call already named.
    @Test("A post in flight does not go out under a request made after it began")
    func inFlightPostIsBoundToItsRequest() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI(duringGet: { @Sendable in
            await MainActor.run {
                fixture.context.insert(TaskEvent(
                    task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage,
                    payload: "Post the review on https://github.com/example/repo/pull/12"
                ))
            }
        })

        let outcome = await fixture.handler(level: .autonomous, cli: cli).postGitHubReview(fixture.request(for: fixture.file))

        #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription))
        #expect(await cli.postCount() == 0)
        #expect(!GitHubReviewPublicationService.hasDispatched(task: fixture.task, filePath: fixture.file.path))
    }

    /// GitHub may have accepted a review whose answer was lost, so the
    /// request it was posted under is answered: a second file must not
    /// become a second review on the strength of it.
    @Test("After an uncertain post, another file under the same request is not posted")
    func uncertainPostAnswersTheRequest() async throws {
        let fixture = try Fixture()
        let cli = FakeCLI(failsPost: true)
        let handler = fixture.handler(level: .autonomous, cli: cli)
        _ = await handler.postGitHubReview(fixture.request(for: fixture.file))
        let second = fixture.file.deletingLastPathComponent().appendingPathComponent("pr12_review_2.json")
        try Data("""
            {"event":"COMMENT","commit_id":"\(Self.head)","body":"A second try"}
            """.utf8).write(to: second)

        let outcome = await handler.postGitHubReview(fixture.request(for: second))

        #expect(outcome == .refused(message: GitHubReviewPublicationError.notRequested.localizedDescription))
        #expect(await cli.postCount() == 1)
        // Ask still reads the request as open: the user decides there.
        #expect(GitHubReviewPublicationRequirement.isPending(task: fixture.task))
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
        private var duringGet: (@Sendable () async -> Void)?
        private var payloads: [Data] = []
        private var calls = 0
        private var argumentLists: [[String]] = []

        /// `duringGet` runs once, inside the first GitHub read: what the user
        /// does while a post is still being prepared.
        init(failsPost: Bool = false, duringGet: (@Sendable () async -> Void)? = nil) {
            self.failsPost = failsPost
            self.duringGet = duringGet
        }

        func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String {
            calls += 1
            argumentLists.append(arguments)
            if !arguments.contains("POST"), let hook = duringGet {
                duringGet = nil
                await hook()
            }
            if arguments.contains("POST") {
                let inputIndex = try #require(arguments.firstIndex(of: "--input"))
                payloads.append(try Data(contentsOf: URL(fileURLWithPath: arguments[inputIndex + 1])))
                if failsPost { throw URLError(.networkConnectionLost) }
                // Answers for the pull request it was posted to, as GitHub does.
                let endpoint = arguments.first { $0.hasPrefix("repos/") }?.split(separator: "/") ?? []
                let page = endpoint.count >= 5
                    ? "https://github.com/\(endpoint[1])/\(endpoint[2])/pull/\(endpoint[4])"
                    : "https://github.com/example/repo/pull/12"
                return #"{"id":42,"html_url":"\#(page)#pullrequestreview-42","state":"COMMENTED","commit_id":"\#(GitHubReviewPostWhenRequestedTests.head)","submitted_at":"2026-10-09T00:00:00Z"}"#
            }
            return #"{"state":"open","head":{"sha":"\#(GitHubReviewPostWhenRequestedTests.head)"}}"#
        }

        func postedPayloads() -> [Data] { payloads }
        func postCount() -> Int { payloads.count }
        func callCount() -> Int { calls }
        func calledArguments() -> [String] { argumentLists.map { $0.joined(separator: " ") } }
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
