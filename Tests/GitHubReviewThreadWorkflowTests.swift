import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

@Suite("GitHub review thread workflow", .serialized)
@MainActor
struct GitHubReviewThreadWorkflowTests {
    private static let head = String(repeating: "a", count: 40)
    private actor FakeCLI: GitHubReviewCLI {
        var head = String(repeating: "a", count: 40)
        var target = "https://github.com/example/repo/pull/12"
        var resolved = false
        var comments: [[String: Any]] = [["id": "C1", "body": "Please fix this", "url": "https://github.com/example/repo/pull/12#discussion_r1", "author": ["login": "reviewer"]]]
        var replies = 0; var resolutions = 0; var reads = 0
        var failResolution = false; var loseReplyResponse = false; var wrongReceipt = false
        var paginate = false; var replacement: (URL, Data)?; var failReads = false; var missingThreads: Set<String> = []; var notThreads: Set<String> = []; var transientThreads: Set<String> = []; var editAfterReply = false; var canReply = true; var failFromRead: Int?; var replaceAtRead: (Int, URL, Data)?

        func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String {
            #expect(arguments.contains("github.com"))
            if let index = arguments.firstIndex(of: "--input") {
                let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) as! [String: Any]
                let query = input["query"] as! String; let variables = input["variables"] as! [String: Any]
                #expect(variables["threadId"] as? String == "T1")
                var result: [String: Any] = ["clientMutationId": variables["mutationId"]!]
                if query.contains("addPullRequestReviewThreadReply") {
                    replies += 1
                    let comment: [String: Any] = ["id": "C2", "body": variables["body"]!, "url": target + "#discussion_r2", "author": ["login": "owner"]]
                    comments.append(comment)
                    if editAfterReply { comments[0]["body"] = "Edited after the reply" }
                    if loseReplyResponse { throw NSError(domain: "lost-response", code: 1) }
                    var receiptComment = comment; receiptComment["pullRequest"] = ["url": target]
                    result["comment"] = receiptComment
                } else {
                    if failResolution { throw NSError(domain: "resolution-failed", code: 1) }
                    resolutions += 1; resolved = true
                    result["thread"] = ["id": "T1", "isResolved": true, "pullRequest": ["url": target]]
                }
                if wrongReceipt { result["clientMutationId"] = "wrong-proposal" }
                return try json(["data": ["change": result]])
            }
            reads += 1
            if failReads { throw NSError(domain: "offline", code: 1) }
            if let limit = failFromRead, reads >= limit { throw NSError(domain: "offline", code: 3) }
            if let (at, url, data) = replaceAtRead, reads == at { replaceAtRead = nil; try data.write(to: url) }
            if let id = arguments.first(where: { $0.hasPrefix("id=") }).map({ String($0.dropFirst(3)) }), transientThreads.contains(id) {
                throw NSError(domain: "offline", code: 2)
            }
            if let id = arguments.first(where: { $0.hasPrefix("id=") }).map({ String($0.dropFirst(3)) }), notThreads.contains(id) {
                // An id of another GitHub type: the inline fragment matches nothing.
                return try json(["data": ["node": [String: Any]()]])
            }
            if let id = arguments.first(where: { $0.hasPrefix("id=") }).map({ String($0.dropFirst(3)) }), missingThreads.contains(id) {
                throw GitHubCLIError.commandFailed("gh: Could not resolve to a node with the global id of '\(id)'")
            }
            #expect(arguments.contains { $0.hasPrefix("query=query(") })
            if let (url, data) = replacement { replacement = nil; try data.write(to: url) }
            let after = arguments.contains { $0.hasPrefix("after=") }
            let nodes = paginate ? (after ? Array(comments.dropFirst()) : Array(comments.prefix(1))) : comments
            return try json(["data": ["node": [
                "id": "T1", "path": "src/main.swift", "line": 12, "isResolved": resolved, "viewerCanResolve": true, "viewerCanReply": canReply,
                "pullRequest": ["url": target, "headRefOid": head, "state": "OPEN"],
                "comments": ["totalCount": comments.count, "nodes": nodes,
                             "pageInfo": ["hasNextPage": paginate && !after && comments.count > 1,
                                          "endCursor": "cursor1"]]
            ]]])
        }
        private func json(_ object: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func counts() -> (Int, Int, Int) { (replies, resolutions, reads) }
        func setReadFailure(_ on: Bool) { failReads = on }
        func setMissing(_ ids: Set<String>) { missingThreads = ids }
        func setNotThreads(_ ids: Set<String>) { notThreads = ids }
        func setTransient(_ ids: Set<String>) { transientThreads = ids }
        func setEditAfterReply(_ on: Bool) { editAfterReply = on }
        func setCanReply(_ on: Bool) { canReply = on }
        func setFailFromRead(_ n: Int?) { failFromRead = n }
        func setReplaceAtRead(_ at: Int, _ url: URL, _ data: Data) { replaceAtRead = (at, url, data) }
        func changeHead() { head = String(repeating: "b", count: 40) }
        func changeHead(to value: String) { head = value }
        func changeTarget() { target = "https://github.com/example/other/pull/12" }
        func editComment() { comments[0]["body"] = "Changed review" }
        func setFailure(resolve: Bool = false, lostReply: Bool = false, wrong: Bool = false) {
            failResolution = resolve; loseReplyResponse = lostReply; wrongReceipt = wrong
        }
        func setReplacement(_ url: URL, _ data: Data) { replacement = (url, data) }
        func addPage() {
            comments.append(["id": "C3", "body": "A follow-up", "url": target + "#discussion_r3", "author": ["login": "reviewer"]])
            paginate = true
        }
    }

    private func fixture() throws -> (root: URL, container: ModelContainer, context: ModelContext, task: AgentTask, run: TaskRun, file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-thread-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workspace = Workspace(name: "Threads", primaryPath: root.path)
        let task = AgentTask(title: "Address review", goal: "Reply to and resolve all comments on https://github.com/example/repo/pull/12", workspace: workspace)
        let run = TaskRun(task: task); run.recordCompletionBlocked(stopReason: .externalOutcomePending)
        context.insert(workspace); context.insert(task); context.insert(run); try context.save()
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let file = URL(fileURLWithPath: folder).appendingPathComponent("pr12_threads.json")
        try payload().write(to: file)
        return (root, container, context, task, run, file)
    }

    private func payload(reply: String? = "Fixed in abc123", resolve: Bool = true, last: String = "C1", extras: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["pull_request_url": "https://github.com/example/repo/pull/12", "commit_id": Self.head,
                                   "threads": [["thread_id": "T1", "expected_last_comment_id": last, "reply": reply as Any? ?? NSNull(), "resolve": resolve]]]
        object.merge(extras) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("read operations bind fixed queries and reject arbitrary options")
    func boundedReads() throws {
        let args = try GitHubReviewThreadReadOperation.arguments(for: ["review-threads", "--repo", "example/repo", "--pr", "12", "--after", "cursor"])
        #expect(args.contains("number=12")); #expect(args.contains("after=cursor"))
        #expect(!args.joined().contains("mutation"))
        for input in [["review-threads", "--repo", "example/repo", "--pr", "12", "--query", "mutation {}"],
                      ["review-thread", "--id", "T1", "--id", "T2"], ["review-thread", "--id", "T1", "--method", "POST"],
                      ["review-threads", "--repo", "../repo", "--pr", "12"], ["review-thread", "--id", "T1\nmutation"]] {
            #expect(throws: GitHubReviewThreadReadOperation.InvalidArguments.self) { try GitHubReviewThreadReadOperation.arguments(for: input) }
        }
        #expect(GitHubHostControlPolicy.denialReason(for: ["api", "graphql"]) != nil)
    }

    @Test("approval publishes a reply and resolution with per-action and final receipts")
    func publishWithReceipts() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        #expect(GitHubReviewPublicationRequirement.isPending(task: f.task))
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        #expect(await cli.counts().0 == 0)
        let receipt = try await service.publish(task: f.task, proposal: proposal)
        #expect(receipt.actions.map(\.operation) == ["reply", "resolve"])
        #expect(f.task.events.filter { $0.type == GitHubReviewThreadEvents.actionReceipt }.count == 2)
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
        #expect(await cli.counts().0 == 1); #expect(await cli.counts().1 == 1)
        await #expect(throws: GitHubReviewPublicationError.self) { try await service.publish(task: f.task, proposal: proposal) }
        #expect(await cli.counts().0 == 1)
    }

    @Test("stale heads and foreign threads cannot be approved")
    func staleAndForeignThreads() async throws {
        for foreign in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let cli = FakeCLI()
            if foreign { await cli.changeTarget() } else { await cli.changeHead() }
            await #expect(throws: GitHubReviewPublicationError.self) {
                try await GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli).prepare(task: f.task, filePath: f.file.path)
            }
            #expect(await cli.counts().0 == 0)
        }
    }

    @Test("provider success waits for thread receipts, and new-review receipts cannot substitute")
    func completionRequiresThreadReceipts() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.status = .pendingUser
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewPublicationEventTypes.receipt,
            payload: GitHubReviewPublicationRecord(proposalID: "other", filePath: "/tmp/pr12_review.json",
                pullRequestURL: "https://github.com/example/repo/pull/12", reviewURL: nil, reviewID: 42), run: f.run))
        try f.context.save()
        let before = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(task: f.task, run: f.run, modelContext: f.context)
        #expect(!before); #expect(f.task.status == .pendingUser)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)
        #expect(f.task.status == .completed)
        let dispatch = try #require(f.task.events.first { $0.type == GitHubReviewThreadEvents.dispatched })
        let record = try JSONDecoder().decode(GitHubReviewThreadReceipt.self, from: Data(dispatch.payload.utf8))
        #expect(record.approvedPayload?.threads[0].reply == "Fixed in abc123")
        #expect(record.approvedPayload?.threads[0].resolve == true)
    }

    @Test("hidden fields and payloads outside the task are rejected")
    func rejectsUnreviewedAndExternalFiles() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        try payload(extras: ["hidden_mutation": true]).write(to: f.file)
        await #expect(throws: GitHubReviewPublicationError.self) { try await service.prepare(task: f.task, filePath: f.file.path) }
        let outside = f.root.appendingPathComponent("pr12_threads.json"); try payload().write(to: outside)
        await #expect(throws: GitHubReviewPublicationError.self) { try await service.prepare(task: f.task, filePath: outside.path) }
    }

    @Test("file and discussion edits invalidate the exact approval")
    func editsInvalidateApproval() async throws {
        for editFile in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let cli = FakeCLI(); let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
            let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
            if editFile { try payload(reply: "Different reply").write(to: f.file) } else { await cli.editComment() }
            await #expect(throws: GitHubReviewPublicationError.self) { try await service.publish(task: f.task, proposal: proposal) }
            #expect(await cli.counts().0 == 0)
            #expect(!GitHubReviewThreadPublicationService.hasDispatched(task: f.task, filePath: f.file.path))
        }
    }

    @Test("file changes during network validation cannot sneak past approval")
    func mutationDuringValidation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        await cli.setReplacement(f.file, try payload(reply: "Changed while awaiting GitHub"))
        await #expect(throws: GitHubReviewPublicationError.self) { try await service.publish(task: f.task, proposal: proposal) }
        #expect(await cli.counts().0 == 0)
    }

    @Test("partial publication preserves confirmed receipts and blocks automatic replay")
    func partialFailure() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.setFailure(resolve: true)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        await #expect(throws: GitHubReviewPublicationError.self) { try await service.publish(task: f.task, proposal: proposal) }
        #expect(f.task.events.contains { $0.type == GitHubReviewThreadEvents.actionReceipt })
        #expect(!f.task.events.contains { $0.type == GitHubReviewThreadEvents.receipt })
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
        let context = ModelContext(f.container)
        let task = try #require(context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(GitHubReviewThreadPublicationService.hasDispatched(task: task, filePath: f.file.path))
        await #expect(throws: GitHubReviewPublicationError.self) {
            try await GitHubReviewThreadPublicationService(modelContext: context, cli: cli).publish(task: task, proposal: proposal)
        }
        #expect(await cli.counts().0 == 1)
    }

    @Test("lost and mismatched mutation responses stay pending and cannot resend")
    func uncertainReplies() async throws {
        for lost in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let cli = FakeCLI(); await cli.setFailure(lostReply: lost, wrong: !lost)
            let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
            let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
            await #expect(throws: GitHubReviewPublicationError.self) { try await service.publish(task: f.task, proposal: proposal) }
            #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
            #expect(await cli.counts().0 == 1); #expect(await cli.counts().1 == 0)
            let renamed = f.file.deletingLastPathComponent().appendingPathComponent("pr12_threads_2.json")
            try payload().write(to: renamed)
            await #expect(throws: GitHubReviewPublicationError.self) { try await service.prepare(task: f.task, filePath: renamed.path) }
        }
    }

    @Test("the complete paginated discussion is required for approval")
    func readsAllPages() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.addPage()
        try payload(reply: nil, last: "C3").write(to: f.file)
        let proposal = try await GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli).prepare(task: f.task, filePath: f.file.path)
        #expect(proposal.snapshots[0].comments.count == 2); #expect(await cli.counts().2 == 2)
    }

    @Test("confirmed changes recover from a final receipt save failure")
    func receiptRecovery() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI()
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli, saveReceipt: { _, _ in
            throw NSError(domain: "receipt-save", code: 1)
        })
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)
        #expect(f.task.events.contains { $0.type == GitHubReviewThreadEvents.receiptRecovery })
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
        #expect(await cli.counts().0 == 1)
    }

    @Test("requests, cancellation, and recovery evidence remain durable")
    func intentAndRecovery() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Do not resolve the comments"))
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
        f.context.insert(TaskEvent(task: f.task, type: TaskPlanConversationEventTypes.userMessage, payload: "Resolve the threads on PR #12"))
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
        #expect(WorkspaceConfigManager.isTaskRecoveryEvent(GitHubReviewThreadEvents.dispatched))
        #expect(WorkspaceConfigManager.importedRecoveryEventType(GitHubReviewThreadEvents.receipt, trust: .quarantine).hasPrefix("imported."))
        #expect(WorkspaceConfigManager.importedRecoveryEventType(GitHubReviewThreadEvents.receipt, trust: .trustedLocalRecovery) == GitHubReviewThreadEvents.receipt)
        #expect(GitHubReviewPublicationService.pendingCandidatePath(task: f.task, filePaths: [f.file.path]) == f.file.path)
        let retry = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "I still see a long list of coment unresolved in the PR, resolve them in the PR, address all of them")
        f.context.insert(retry)
        #expect(GitHubReviewThreadRequirement.request(task: f.task)?.id == retry.id.uuidString)
        let typo = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "reslolve all coments adressed .. and fix the new ones")
        f.context.insert(typo)
        #expect(GitHubReviewThreadRequirement.request(task: f.task)?.id == typo.id.uuidString)
    }

    // MARK: - What counts as a request to reply to or resolve threads

    private func request(for goal: String) -> GitHubReviewThreadRequirement.Request? {
        let workspace = Workspace(name: "Threads", primaryPath: "/tmp/astra-thread-intent")
        return GitHubReviewThreadRequirement.request(task: AgentTask(title: "Task", goal: goal, workspace: workspace))
    }

    @Test("asking to reply to or resolve review threads on a PR is a request", arguments: [
        "Reply to and resolve all comments on https://github.com/example/repo/pull/12",
        "Reply to all the unresolved review threads on PR 476 and resolve them",
        "Reply to the comments on PR #12",
        "Please mark the review threads on pull request 12 as resolved",
        "Address the review comments and resolve the threads on GitHub PR 12",
        "Reply to the reviewer comments on this PR",
        "Reply to the review threads and resolve them on GitHub PR 12",
        "In PR 12 reply to the threads",
        "Reply to the Slack thread and resolve the threads on GitHub PR 12",
        "Reply to the review threads on PR 12 but do not resolve them",
        "On PR #12, reply to the review threads",
        "In pull request 12: reply to the threads",
        "Reply to the PR #12 review comments",
        "Reply to the GitHub PR comments",
        "Resolve the pull request's review comments",
        "Reply to review comments on GitHub PR #12",
        "Reply to the comments on GitHub",
        "Reply to the GitHub review thread with the answer from Slack",
        "Reply but do not resolve the GitHub review threads on PR 12",
        "Reply and don't resolve the threads on PR 12",
        "Resolve the threads on PR 12 using the Jira ticket notes"
    ])
    func realRequestsAreDetected(goal: String) {
        #expect(request(for: goal) != nil, "\(goal)")
    }

    @Test("ordinary GitHub work that mentions comments or resolving does not become a request", arguments: [
        "Summarize the open GitHub PRs and reply to the Slack comments about the release",
        "Draft a reply to the customer comments, then open a pull request with the fix",
        "Draft a reply to the customer comments then open a pull request with the fix",
        "Reply to the Slack comments about the release and resolve them. Then check the GitHub PR",
        "Open a GitHub PR and mark the issue as resolved",
        "Investigate why the GitHub workflow fails; do not resolve any threads",
        "Stop resolving the review threads on PR 12",
        "Cancel replying to the threads on PR 12",
        "Skip resolving the threads on GitHub PR 12",
        "Do not resolve the review threads on GitHub PR 12, but reply to the Slack thread",
        "Don't resolve the threads on PR 12 and reply to the Slack thread",
        "Resolve the merge conflicts in my GitHub PR and update the review",
        "Review this GitHub PR and reply with your comments here",
        "Review the pull request and reply with your review comments in this chat",
        "Reply to the Slack thread, then inspect GitHub PR #12",
        "Reply to the Slack thread then inspect GitHub PR #12",
        "Reply to the Slack thread. Afterwards look at the GitHub PR",
        "Resolve the race in the worker threads on GitHub PR 12",
        "Resolve the deadlock between the main threads on GitHub PR 12",
        "Reply to the Slack thread and inspect GitHub PR #12",
        "Inspect GitHub PR #12 and reply to the Slack thread",
        "Reply to the Slack thread but first look at the GitHub PR"
    ])
    func ordinaryWorkIsNotARequest(goal: String) {
        // A false positive blocks the task from finishing until the user types a
        // cancellation phrase, so a miss is the cheaper error.
        #expect(request(for: goal) == nil, "\(goal)")
    }

    @Test("a follow-up message can still reply to or resolve comments once a request is active")
    func followUpsKeepWorkingAfterARequest() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "Do not resolve the comments"))
        #expect(GitHubReviewThreadRequirement.request(task: f.task) == nil)

        f.context.insert(TaskEvent(task: f.task, type: TaskPlanConversationEventTypes.userMessage,
                                   payload: "Resolve the threads on PR #12"))
        #expect(GitHubReviewThreadRequirement.request(task: f.task) != nil)
    }

    @Test("the user can drop a request in plain words")
    func plainWordsDropARequest() throws {
        for phrase in ["cancel it", "skip it", "forget that", "drop them", "never mind",
                       "Don't reply to them", "Stop replying to those", "do not post them", "never reply to it"] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
            f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: phrase))
            #expect(!GitHubReviewThreadRequirement.isPending(task: f.task), "\(phrase)")
        }
    }

    // MARK: - A proposal that can no longer be used must not block the next one

    private func dismissals(_ task: AgentTask) -> [String] {
        task.events.filter { $0.type == GitHubReviewThreadEvents.dismissed }.map(\.payload)
    }

    @Test("a stale thread proposal is dismissed and no longer offered, so it cannot shadow a review")
    func staleProposalIsDismissedAndStopsShadowingReviews() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.changeHead()
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        let review = f.file.deletingLastPathComponent().appendingPathComponent("pr12_review.json")

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }

        #expect(dismissals(f.task).count == 1)
        #expect(GitHubReviewThreadPublicationService.pendingCandidatePath(task: f.task, filePaths: [f.file.path]) == nil)
        // The dock now falls through to the review proposal instead of the dead thread file.
        #expect(GitHubReviewPublicationService.pendingCandidatePath(task: f.task, filePaths: [f.file.path, review.path]) == review.path)
    }

    @Test("a dismissed proposal stays dismissed, and a corrected one under a new name is accepted")
    func dismissedStaysDismissedAndANewNameWorks() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.changeHead()
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }

        // Asking again does not re-validate the dismissed file or add a second record.
        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }
        #expect(dismissals(f.task).count == 1)

        let corrected = f.file.deletingLastPathComponent().appendingPathComponent("pr12_threads_2.json")
        try payload().write(to: corrected)
        await cli.changeHead(to: Self.head)
        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path, corrected.path])
        #expect(proposal.filePath == corrected.path)
    }

    @Test("a good proposal after a stale one is returned, and the stale one is dismissed")
    func goodProposalAfterAStaleOne() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let folder = f.file.deletingLastPathComponent()
        let stale = folder.appendingPathComponent("pr12_threads_1.json")
        try payload(last: "C-old").write(to: stale)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())

        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [stale.path, f.file.path])

        #expect(proposal.filePath == f.file.path)
        #expect(dismissals(f.task).count == 1)
        #expect(GitHubReviewThreadPublicationService.pendingCandidatePath(task: f.task, filePaths: [stale.path, f.file.path]) == f.file.path)
    }

    @Test("a GitHub outage does not dismiss a proposal that may be perfectly good")
    func transientFailureDoesNotDismiss() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.setReadFailure(true)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)

        await #expect(throws: Error.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }

        #expect(dismissals(f.task).isEmpty)
        #expect(GitHubReviewThreadPublicationService.pendingCandidatePath(task: f.task, filePaths: [f.file.path]) == f.file.path)

        await cli.setReadFailure(false)
        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        #expect(proposal.filePath == f.file.path)
    }

    @Test("dismissal records are durable evidence and are quarantined when imported")
    func dismissalEvidenceIsDurable() {
        #expect(WorkspaceConfigManager.isTaskRecoveryEvent(GitHubReviewThreadEvents.dismissed))
        #expect(WorkspaceConfigManager.importedRecoveryEventType(GitHubReviewThreadEvents.dismissed, trust: .quarantine).hasPrefix("imported."))
    }

    // MARK: - Overlap with the generic review-publication request

    @Test("a thread request satisfied by its receipt does not leave the generic review requirement pending")
    func threadReceiptSatisfiesAnOverlappingReviewRequest() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // "post ... review" and "reply ... thread" both match this one sentence.
        f.task.goal = "Post a reply to every review thread on https://github.com/example/repo/pull/12"
        #expect(GitHubReviewPublicationRequirement.isPending(task: f.task))

        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
        #expect(!GitHubReviewPublicationRequirement.isPending(task: f.task))
    }

    // MARK: - A thread that no longer exists

    @Test("a proposal for a deleted thread is dismissed so a later one can be reached")
    func missingThreadIsDismissed() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let folder = f.file.deletingLastPathComponent()
        let gone = folder.appendingPathComponent("pr12_threads_1.json")
        let object: [String: Any] = ["pull_request_url": "https://github.com/example/repo/pull/12", "commit_id": Self.head,
            "threads": [["thread_id": "T9", "expected_last_comment_id": "C1", "reply": "Done", "resolve": true]]]
        try JSONSerialization.data(withJSONObject: object).write(to: gone)
        let cli = FakeCLI(); await cli.setMissing(["T9"])
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)

        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [gone.path, f.file.path])

        #expect(proposal.filePath == f.file.path)
        #expect(dismissals(f.task).count == 1)
        #expect(GitHubReviewThreadPublicationService.hasDismissed(task: f.task, filePath: gone.path))
    }

    // MARK: - Repository names

    @Test("repository names such as owner/.github are accepted and dot directories are not")
    func dotPrefixedRepositoryNames() throws {
        #expect(GitHubReviewThreadReadOperation.isRepository("owner/.github"))
        #expect(GitHubReviewThreadReadOperation.isRepository("owner/repo.name"))
        #expect(!GitHubReviewThreadReadOperation.isRepository("owner/."))
        #expect(!GitHubReviewThreadReadOperation.isRepository("owner/.."))
        #expect(!GitHubReviewThreadReadOperation.isRepository("owner/repo/extra"))
        _ = try GitHubReviewThreadReadOperation.arguments(for: ["review-threads", "--repo", "owner/.github", "--pr", "3"])
        #expect(GitHubReviewThreadArtifactPolicy.target("https://github.com/owner/.github/pull/3")?.repository == "owner/.github")
    }

    @Test("GitHub context must be in the clause that asked for it, not elsewhere in the task")
    func contextIsScopedToTheMatchedClause() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Review PR 12 and summarize it"
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "Reply to the Slack thread about the release"))
        #expect(GitHubReviewThreadRequirement.request(task: f.task) == nil)

        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "Now resolve the threads on PR 12"))
        #expect(GitHubReviewThreadRequirement.request(task: f.task) != nil)
    }

    // MARK: - Thread wording is not a request to post a review

    @Test("a request for both a review and thread replies needs both receipts")
    func dualIntentNeedsBothReceipts() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Post a review and reply to every review thread on https://github.com/example/repo/pull/12"
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
        // The review the same sentence asked for is still owed.
        #expect(GitHubReviewPublicationRequirement.isPending(task: f.task))
    }

    @Test("cancelling a thread-only request does not leave a review requirement behind")
    func cancellingAThreadOnlyRequestLeavesNothingPending() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Post a reply to every review thread on https://github.com/example/repo/pull/12"
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))

        for phrase in ["skip it", "never mind", "drop them", "forget that"] {
            f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: phrase))
            #expect(!GitHubReviewThreadRequirement.isPending(task: f.task), "\(phrase)")
            #expect(!GitHubReviewPublicationRequirement.isPending(task: f.task), "\(phrase)")
            f.context.insert(TaskEvent(task: f.task, type: TaskPlanConversationEventTypes.userMessage,
                                       payload: "Reply to every review thread on https://github.com/example/repo/pull/12"))
            #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
        }
    }

    // MARK: - Missing repository context is retryable, a wrong file is not

    @Test("a missing workspace origin leaves a valid proposal retryable instead of dismissing it")
    func missingOriginDoesNotDismiss() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Resolve the threads on PR 12"
        let offline = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI(), originURL: { _ in nil })

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await offline.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }
        #expect(dismissals(f.task).isEmpty)
        #expect(GitHubReviewThreadPublicationService.pendingCandidatePath(task: f.task, filePaths: [f.file.path]) == f.file.path)

        // Connecting the workspace afterwards makes the same file usable.
        let connected = GitHubReviewThreadPublicationService(
            modelContext: f.context, cli: FakeCLI(), originURL: { _ in "https://github.com/example/repo.git" })
        let proposal = try await connected.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        #expect(proposal.filePath == f.file.path)
    }

    @Test("a proposal for a different PR than the request names is a defect of the file and is dismissed")
    func wrongPullRequestIsDismissed() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Resolve the threads on PR 99"
        let service = GitHubReviewThreadPublicationService(
            modelContext: f.context, cli: FakeCLI(), originURL: { _ in "https://github.com/example/repo.git" })

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }

        #expect(dismissals(f.task).count == 1)
    }

    // MARK: - A pronoun follow-up keeps the target the request named

    @Test("a follow-up that says only \"resolve them\" keeps the PR the earlier message named")
    func pronounFollowUpKeepsTheTarget() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Look at the open review feedback"
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "Reply to the threads on https://github.com/example/repo/pull/12"))
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "resolve them"))
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        #expect(request.text == "resolve them")

        // No workspace origin: the target has to come from the message that named it.
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI(), originURL: { _ in nil })
        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        #expect(proposal.filePath == f.file.path)
        #expect(dismissals(f.task).isEmpty)
    }

    @Test("an explicit stop phrase with an object clears an active request")
    func stopPhraseClearsAnActiveRequest() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "Stop resolving the review threads on PR 12"))
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    @Test("a node id of another GitHub type is an unusable proposal, not a decoding failure")
    func nonThreadNodeIsDismissed() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let wrong = f.file.deletingLastPathComponent().appendingPathComponent("pr12_threads_1.json")
        let object: [String: Any] = ["pull_request_url": "https://github.com/example/repo/pull/12", "commit_id": Self.head,
            "threads": [["thread_id": "PR_kwDOnotAThread", "expected_last_comment_id": "C1", "reply": "Done", "resolve": true]]]
        try JSONSerialization.data(withJSONObject: object).write(to: wrong)
        let cli = FakeCLI(); await cli.setNotThreads(["PR_kwDOnotAThread"])
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)

        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [wrong.path, f.file.path])

        #expect(proposal.filePath == f.file.path)
        #expect(GitHubReviewThreadPublicationService.hasDismissed(task: f.task, filePath: wrong.path))
    }

    @Test("stale proposals found before a transient failure are still dismissed")
    func staleDismissalsSurviveATransientFailure() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let folder = f.file.deletingLastPathComponent()
        let stale = folder.appendingPathComponent("pr12_threads_1.json")
        try payload(last: "C-old").write(to: stale)
        let flaky = folder.appendingPathComponent("pr12_threads_2.json")
        let object: [String: Any] = ["pull_request_url": "https://github.com/example/repo/pull/12", "commit_id": Self.head,
            "threads": [["thread_id": "T2", "expected_last_comment_id": "C1", "reply": "Done", "resolve": true]]]
        try JSONSerialization.data(withJSONObject: object).write(to: flaky)
        let cli = FakeCLI(); await cli.setTransient(["T2"])
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)

        await #expect(throws: Error.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [stale.path, flaky.path])
        }

        #expect(GitHubReviewThreadPublicationService.hasDismissed(task: f.task, filePath: stale.path))
        #expect(!GitHubReviewThreadPublicationService.hasDismissed(task: f.task, filePath: flaky.path))
        #expect(GitHubReviewThreadPublicationService.pendingCandidatePath(task: f.task, filePaths: [stale.path, flaky.path]) == flaky.path)
    }

    // MARK: - Follow-ups scoped to another service

    @Test("a thread follow-up scoped to another service does not reopen a settled request")
    func otherServiceFollowUpDoesNotReopenASettledRequest() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)
        let settled = try #require(GitHubReviewThreadRequirement.request(task: f.task)).id
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))

        for phrase in ["Reply to the Slack thread", "Reply to the comments on the Jira ticket", "Resolve the email thread about it"] {
            f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: phrase))
            #expect(GitHubReviewThreadRequirement.request(task: f.task)?.id == settled, "\(phrase)")
            #expect(!GitHubReviewThreadRequirement.isPending(task: f.task), "\(phrase)")
        }
    }

    // MARK: - Replies to review comments are thread work

    @Test("a request to post replies to review comments owes thread receipts and no new review")
    func repliesToReviewCommentsAreThreadWork() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Post replies to every review comment on https://github.com/example/repo/pull/12"
        #expect(GitHubReviewThreadRequirement.request(task: f.task) != nil)

        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
        #expect(!GitHubReviewPublicationRequirement.isPending(task: f.task))
    }

    // MARK: - Resolution rechecks the whole discussion

    @Test("an earlier comment edited after the reply stops the resolution")
    func resolutionRechecksTheWholeDiscussion() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.setEditAfterReply(true)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.publish(task: f.task, proposal: proposal)
        }

        let counts = await cli.counts()
        #expect(counts.0 == 1)
        #expect(counts.1 == 0)
    }

    // MARK: - A fully receipted batch survives a crash before the final receipt

    @Test("action receipts that cover every operation of a dispatched batch satisfy the request")
    func actionReceiptsCoveringTheBatchSatisfyTheRequest() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        let url = "https://github.com/example/repo/pull/12"
        let payload = GitHubReviewThreadPayload(pullRequestUrl: url, commitId: Self.head, threads: [
            .init(threadId: "T1", expectedLastCommentId: "C1", reply: "Fixed", resolve: true)])
        func receipt(_ actions: [GitHubReviewThreadReceipt.Action], approved: Bool = false) -> GitHubReviewThreadReceipt {
            var value = GitHubReviewThreadReceipt(proposalID: "p1", filePath: f.file.path, requestID: request.id,
                                                  pullRequestURL: url, actions: actions)
            if approved { value.approvedPayload = payload }
            return value
        }
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.dispatched,
                                                          payload: receipt([], approved: true)))
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.actionReceipt,
            payload: receipt([.init(threadID: "T1", operation: "reply", commentID: "C2", url: url + "#discussion_r2")])))
        // The reply is confirmed but the resolution is not: still owed.
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))

        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.actionReceipt,
            payload: receipt([.init(threadID: "T1", operation: "resolve", commentID: nil, url: nil)])))
        // Every operation is confirmed, only the final batch receipt was never written.
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    // MARK: - A continuation that gives only a PR number keeps the repository

    @Test("a follow-up naming only a PR number keeps the repository of the earlier URL")
    func shorthandFollowUpKeepsTheRepository() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Look at the open review feedback"
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "Reply to the threads on https://github.com/example/repo/pull/12"))
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "resolve those on PR 12"))
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        #expect(request.text == "resolve those on PR 12")

        // No workspace origin: owner and repository must still come from the earlier URL.
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI(), originURL: { _ in nil })
        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        #expect(proposal.filePath == f.file.path)

        // A different number is a different PR in that repository, so this file no longer fits.
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "resolve those on PR 13"))
        let other = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI(), originURL: { _ in nil })
        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await other.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }
    }

    // MARK: - The recovery mirror keeps what decides the request

    private func mirroredEventIDs(_ f: (root: URL, container: ModelContainer, context: ModelContext, task: AgentTask, run: TaskRun, file: URL)) throws -> Set<String> {
        let workspace = try #require(f.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: f.context))
        let mirrored = try #require((config.tasks ?? []).first { $0.id == f.task.id.uuidString })
        return Set(mirrored.events.compactMap(\.id))
    }

    private func addNoise(_ f: (root: URL, container: ModelContainer, context: ModelContext, task: AgentTask, run: TaskRun, file: URL), count: Int) {
        for index in 0..<count {
            f.context.insert(TaskEvent(task: f.task, eventType: TaskEventTypes.System.info, payload: "noise \(index)"))
        }
    }

    @Test("the message that started the request survives the bounded event history once thread records point at it")
    func mirrorKeepsTheRequestMessage() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Look at the open review feedback"
        let request = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                payload: "Resolve the threads on https://github.com/example/repo/pull/12")
        f.context.insert(request)
        let record = GitHubReviewThreadReceipt(proposalID: "p1", filePath: f.file.path, requestID: request.id.uuidString,
                                               pullRequestURL: "https://github.com/example/repo/pull/12", actions: [])
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.dispatched, payload: record))
        addNoise(f, count: WorkspaceConfigManager.MirrorLimits.maxEventsPerTask + 5)

        #expect(try mirroredEventIDs(f).contains(request.id.uuidString))
    }

    // MARK: - A generic follow-up is not a continuation

    @Test("a generic follow-up about comments does not replace a settled request")
    func genericFollowUpDoesNotReopenASettledRequest() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)
        let settled = try #require(GitHubReviewThreadRequirement.request(task: f.task)).id

        for phrase in ["Reply with your comments here", "Reply to the comments in this document", "Reply with the review"] {
            f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: phrase))
            #expect(GitHubReviewThreadRequirement.request(task: f.task)?.id == settled, "\(phrase)")
            #expect(!GitHubReviewThreadRequirement.isPending(task: f.task), "\(phrase)")
        }
    }

    // MARK: - The request chain is recorded with the dispatch

    @Test("the target-bearing message of a continued request survives the recovery mirror")
    func mirrorKeepsTheContinuationChain() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Look at the open review feedback"
        let first = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                              payload: "Reply to the threads on https://github.com/example/repo/pull/12")
        f.context.insert(first)
        let second = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "resolve them")
        f.context.insert(second)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI(), originURL: { _ in nil })
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)
        addNoise(f, count: WorkspaceConfigManager.MirrorLimits.maxEventsPerTask + 5)

        let kept = try mirroredEventIDs(f)
        #expect(kept.contains(first.id.uuidString))
        #expect(kept.contains(second.id.uuidString))
    }

    // MARK: - Replying needs permission to reply

    @Test("a reply is rejected before dispatch when the viewer cannot reply")
    func replyNeedsViewerCanReply() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.setCanReply(false)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepare(task: f.task, filePath: f.file.path)
        }
        #expect(!f.task.events.contains { $0.type == GitHubReviewThreadEvents.dispatched })

        // A resolution without a reply does not need that permission.
        try payload(reply: nil, resolve: true).write(to: f.file)
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        #expect(proposal.payload.threads[0].reply == nil)
    }

    // MARK: - Permissions and ambiguity are not defects of the file

    @Test("a missing viewer permission leaves the proposal retryable instead of dismissing it")
    func missingViewerPermissionDoesNotDismiss() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI(); await cli.setCanReply(false)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }
        #expect(dismissals(f.task).isEmpty)
        #expect(GitHubReviewThreadPublicationService.pendingCandidatePath(task: f.task, filePaths: [f.file.path]) == f.file.path)

        // After permission is granted the unchanged file works again.
        await cli.setCanReply(true)
        let proposal = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        #expect(proposal.filePath == f.file.path)
    }

    @Test("a request naming several pull requests is rejected, not satisfied by one receipt")
    func multiplePullRequestsAreRejected() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Resolve the review threads on PR 12 and PR 13"
        let service = GitHubReviewThreadPublicationService(
            modelContext: f.context, cli: FakeCLI(), originURL: { _ in "https://github.com/example/repo.git" })

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.prepareFirstAvailable(task: f.task, filePaths: [f.file.path])
        }

        #expect(dismissals(f.task).isEmpty)
        #expect(!f.task.events.contains { $0.type == GitHubReviewThreadEvents.dispatched })
    }

    // MARK: - Cancellations survive recovery

    @Test("a cancellation of a goal-level request older than the bounded history is kept")
    func mirrorKeepsAnOldCancellation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cancel = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "never mind")
        f.context.insert(cancel)
        addNoise(f, count: WorkspaceConfigManager.MirrorLimits.maxEventsPerTask + 5)

        #expect(try mirroredEventIDs(f).contains(cancel.id.uuidString))
    }

    // MARK: - Recovery retention is bounded

    @Test("thread-vocabulary retention is capped and keeps long pasted text out")
    func languageRetentionIsBounded() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let long = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                             payload: "Here is a long log with a comment in it: " + String(repeating: "x", count: 10_000))
        f.context.insert(long)
        var ordinary: [TaskEvent] = []
        for index in 0..<80 {
            let event = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "please comment on item \(index)")
            f.context.insert(event); ordinary.append(event)
        }
        addNoise(f, count: WorkspaceConfigManager.MirrorLimits.maxEventsPerTask + 5)

        let workspace = try #require(f.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: f.context))
        let mirrored = try #require((config.tasks ?? []).first { $0.id == f.task.id.uuidString })
        let kept = Set(mirrored.events.compactMap(\.id))
        let userMessages = mirrored.events.filter { $0.type == TaskEventTypes.Conversation.userMessage.rawValue }

        #expect(!kept.contains(long.id.uuidString))
        #expect(userMessages.count <= WorkspaceConfigManager.MirrorLimits.maxThreadLanguageEvents + WorkspaceConfigManager.MirrorLimits.maxEventsPerTask)
        #expect(userMessages.allSatisfy { $0.payload.count <= WorkspaceConfigManager.MirrorLimits.maxEventPayloadCharacters })
    }

    // MARK: - Reads stay under the broker output cap

    @Test("thread reads keep pages small and leave comment bodies out of the thread list")
    func readsStayUnderTheOutputCap() throws {
        func query(_ input: [String]) throws -> String {
            try #require(GitHubReviewThreadReadOperation.arguments(for: input).first { $0.hasPrefix("query=") })
        }
        let list = try query(["review-threads", "--repo", "owner/repo", "--pr", "12"])
        let thread = try query(["review-thread", "--id", "T1"])

        #expect(!list.contains("body"))
        #expect(list.contains("comments(first: 1)"))
        #expect(thread.contains("body"))
        #expect(thread.contains("comments(first: 1"))
    }

    // MARK: - A failure before any write leaves the proposal sendable

    @Test("a read that fails before anything is sent does not consume the proposal")
    func preWriteFailureDoesNotConsumeTheProposal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI()
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)   // read 1
        await cli.setFailFromRead(3)   // the send's own preparation (read 2) passes; the loop's read fails

        await #expect(throws: Error.self) {
            _ = try await service.publish(task: f.task, proposal: proposal)
        }

        #expect(await cli.counts().0 == 0)
        #expect(!GitHubReviewThreadPublicationService.hasDispatched(task: f.task, filePath: f.file.path))
        #expect(!f.task.events.contains { $0.type == GitHubReviewThreadEvents.indeterminate })

        await cli.setFailFromRead(nil)
        let again = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: again)
        #expect(await cli.counts().0 == 1)
    }

    // MARK: - A failure before the request goes out consumes nothing

    @Test("a proposal edited while the send reads GitHub is withdrawn, not left indeterminate")
    func editDuringTheSendWithdrawsTheDispatch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cli = FakeCLI()
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)   // read 1
        // The send's own preparation is read 2; the file changes during the loop's read 3.
        await cli.setReplaceAtRead(3, f.file, try payload(reply: "Changed after approval"))

        await #expect(throws: GitHubReviewPublicationError.self) {
            _ = try await service.publish(task: f.task, proposal: proposal)
        }

        #expect(await cli.counts().0 == 0)
        #expect(!GitHubReviewThreadPublicationService.hasDispatched(task: f.task, filePath: f.file.path))
        #expect(!f.task.events.contains { $0.type == GitHubReviewThreadEvents.indeterminate })
    }

    // MARK: - A receipt has to cover what was asked for

    @Test("a request for resolutions is not settled by a reply that leaves the thread open")
    func resolutionRequestNeedsAResolution() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Resolve the review threads on https://github.com/example/repo/pull/12"
        try payload(reply: "Fixed in abc123", resolve: false).write(to: f.file)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    @Test("a request for replies and resolutions needs both")
    func repliesAndResolutionsNeedBoth() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // The fixture goal asks to reply to and resolve the comments.
        try payload(reply: nil, resolve: true).write(to: f.file)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    @Test("a request for replies alone is settled by a reply")
    func replyRequestIsSettledByAReply() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Reply to the review threads on https://github.com/example/repo/pull/12"
        try payload(reply: "Fixed in abc123", resolve: false).write(to: f.file)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    // MARK: - Additive follow-ups keep what was already asked

    @Test("\"also resolve them\" adds to a pending reply request instead of replacing it")
    func additiveFollowUpKeepsTheReply() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Reply to the review threads on https://github.com/example/repo/pull/12"
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "also resolve them"))
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        #expect(request.operations == ["reply", "resolve"])

        try payload(reply: nil, resolve: true).write(to: f.file)
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: FakeCLI())
        let proposal = try await service.prepare(task: f.task, filePath: f.file.path)
        _ = try await service.publish(task: f.task, proposal: proposal)

        // The resolution alone does not publish the reply that is still asked for.
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    @Test("receipts of the request an additive follow-up extends still count")
    func receiptsOfTheExtendedRequestStillCount() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Reply to the review threads on https://github.com/example/repo/pull/12"
        try payload(reply: "Fixed in abc123", resolve: false).write(to: f.file)
        let cli = FakeCLI()
        let service = GitHubReviewThreadPublicationService(modelContext: f.context, cli: cli)
        _ = try await service.publish(task: f.task, proposal: try await service.prepare(task: f.task, filePath: f.file.path))
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))

        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "also resolve them"))
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))   // the resolution is still owed

        let second = f.file.deletingLastPathComponent().appendingPathComponent("pr12_threads_2.json")
        try payload(reply: nil, resolve: true, last: "C2").write(to: second)
        _ = try await service.publish(task: f.task, proposal: try await service.prepare(task: f.task, filePath: second.path))
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))   // reply already sent, resolution now too
    }

    // MARK: - Dispatch evidence survives a relocated workspace

    @Test("a dispatched proposal is still recognised after its task folder moved")
    func dispatchSurvivesRelocation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = "/Users/someone/Documents/Old Place/.astra/tasks/ABCD1234/pr12_threads.json"
        let moved = "/Volumes/Moved/Workspaces/Renamed/.astra/tasks/ABCD1234/pr12_threads.json"
        let record = GitHubReviewThreadReceipt(proposalID: "p1", filePath: old, requestID: nil,
                                               pullRequestURL: "https://github.com/example/repo/pull/12", actions: [])
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.dispatched, payload: record))
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.dismissed,
                                                          payload: GitHubReviewThreadDismissal(filePath: old, reason: "stale")))

        #expect(GitHubReviewThreadPublicationService.hasDispatched(task: f.task, filePath: moved))
        #expect(GitHubReviewThreadPublicationService.hasDismissed(task: f.task, filePath: moved))
        // A different proposal in the same folder is not the same proposal.
        let other = "/Volumes/Moved/Workspaces/Renamed/.astra/tasks/ABCD1234/pr12_threads_2.json"
        #expect(!GitHubReviewThreadPublicationService.hasDispatched(task: f.task, filePath: other))
    }

    // MARK: - Settled batches do not accumulate in the recovery mirror

    @Test("old settled thread batches are compacted while active evidence is kept")
    func settledBatchesAreBounded() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = "https://github.com/example/repo/pull/12"
        func insert(_ type: String, _ proposal: String) {
            let record = GitHubReviewThreadReceipt(proposalID: proposal, filePath: "/x/pr12_threads.json", requestID: nil,
                                                   pullRequestURL: url, actions: [.init(threadID: "T1", operation: "reply", commentID: "C", url: url)])
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: type, payload: record))
        }
        for index in 0..<12 {
            insert(GitHubReviewThreadEvents.dispatched, "settled-\(index)")
            insert(GitHubReviewThreadEvents.actionReceipt, "settled-\(index)")
            insert(GitHubReviewThreadEvents.receipt, "settled-\(index)")
        }
        insert(GitHubReviewThreadEvents.dispatched, "active")   // sent, never settled

        let workspace = try #require(f.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: f.context))
        let mirrored = try #require((config.tasks ?? []).first { $0.id == f.task.id.uuidString })
        let thread = mirrored.events.filter { $0.type.hasPrefix("github.review-threads.") }
        let proposals = Set(thread.compactMap { event -> String? in
            (try? JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any])?["proposalID"] as? String
        })

        #expect(proposals.contains("active"))
        #expect(proposals.contains("settled-11"))
        #expect(!proposals.contains("settled-0"))
        #expect(proposals.count <= 1 + WorkspaceConfigManager.MirrorLimits.maxSettledThreadBatches)
    }

    // MARK: - Every clause of one message counts

    @Test("a message with separately qualified clauses keeps every requested operation")
    func multiClauseMessageKeepsEveryOperation() {
        let both = request(for: "Reply to the review threads on PR 12, and resolve the review threads on PR 12")
        #expect(both?.operations == ["reply", "resolve"])

        // A negated clause is not an operation, and another job's clause is not either.
        let onlyReply = request(for: "Reply to the review threads on PR 12 but do not resolve the review threads on PR 12")
        #expect(onlyReply?.operations == ["reply"])
        let slack = request(for: "Reply to the Slack thread, and resolve the review threads on PR 12")
        #expect(slack?.operations == ["resolve"])
    }

    // MARK: - Unsettled evidence is compacted, never dropped

    @Test("unsettled batches beyond the newest few lose their embedded payload but stay in the mirror")
    func unsettledBatchesAreCompactedNotDropped() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = "https://github.com/example/repo/pull/12"
        let payload = GitHubReviewThreadPayload(pullRequestUrl: url, commitId: Self.head, threads: [
            .init(threadId: "T1", expectedLastCommentId: "C1", reply: "Fixed", resolve: true)])
        let total = WorkspaceConfigManager.MirrorLimits.maxActiveThreadBatches + 5
        for index in 0..<total {
            var record = GitHubReviewThreadReceipt(proposalID: "unsettled-\(index)", filePath: "/x/pr12_threads_\(index).json",
                                                   requestID: nil, pullRequestURL: url, actions: [])
            record.approvedPayload = payload
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.dispatched, payload: record))
        }

        let workspace = try #require(f.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: f.context))
        let mirrored = try #require((config.tasks ?? []).first { $0.id == f.task.id.uuidString })
        var withPayload: [String: Bool] = [:]
        for event in mirrored.events where event.type == GitHubReviewThreadEvents.dispatched {
            let object = (try? JSONSerialization.jsonObject(with: Data(event.payload.utf8))) as? [String: Any]
            if let id = object?["proposalID"] as? String { withPayload[id] = object?["approvedPayload"] != nil }
        }

        #expect(withPayload.count == total)                       // every unsettled dispatch is still there
        #expect(withPayload["unsettled-0"] == false)               // the oldest ones are compacted
        let oldest = mirrored.events.first { $0.payload.contains("unsettled-0\"") && $0.type == GitHubReviewThreadEvents.dispatched }
        let oldestObject = oldest.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.payload.utf8))) as? [String: Any] }
        #expect((oldestObject?["requiredActions"] as? [String])?.sorted() == ["T1:reply", "T1:resolve"])
        #expect(withPayload["unsettled-\(total - 1)"] == true)     // the newest keep what recovery may need
    }

    // MARK: - Selective negation keeps what is still asked for

    @Test("negating an operation for one thread does not cancel it for another")
    func selectiveNegationKeepsThePositive() {
        let selective = request(for: "Do not resolve the first GitHub review thread, but resolve the second GitHub review thread")
        #expect(selective?.operations == ["resolve"])

        // The last mention decides: a change of mind within the message cancels.
        #expect(request(for: "Resolve the review threads on PR 12. Do not resolve the review threads on PR 12.") == nil)
    }

    // MARK: - Compaction keeps the required actions

    @Test("a compacted dispatch still lets full receipt coverage settle the request")
    func compactedDispatchStillSettlesFromReceipts() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        let url = "https://github.com/example/repo/pull/12"
        func record(_ actions: [GitHubReviewThreadReceipt.Action] = [], required: [String]? = nil) -> GitHubReviewThreadReceipt {
            var value = GitHubReviewThreadReceipt(proposalID: "old", filePath: f.file.path, requestID: request.id,
                                                  pullRequestURL: url, actions: actions)
            value.requiredActions = required
            return value
        }
        // A dispatch as the mirror leaves it once compacted: no approved payload, only the summary.
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.dispatched,
                                                          payload: record(required: ["T1:reply", "T1:resolve"])))
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.actionReceipt,
            payload: record([.init(threadID: "T1", operation: "reply", commentID: "C2", url: url)])))
        #expect(GitHubReviewThreadRequirement.isPending(task: f.task))   // the resolution is not confirmed yet

        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: GitHubReviewThreadEvents.actionReceipt,
            payload: record([.init(threadID: "T1", operation: "resolve", commentID: nil, url: nil)])))
        #expect(!GitHubReviewThreadRequirement.isPending(task: f.task))
    }

    // MARK: - Request messages follow the retained batches

    @Test("the request message of a batch the mirror dropped is not kept forever")
    func droppedBatchesDoNotKeepTheirRequestMessages() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Look at the open review feedback"
        let url = "https://github.com/example/repo/pull/12"
        var messages: [TaskEvent] = []
        for index in 0..<12 {
            let message = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "go ahead, number \(index)")
            f.context.insert(message); messages.append(message)
            for type in [GitHubReviewThreadEvents.dispatched, GitHubReviewThreadEvents.receipt] {
                let record = GitHubReviewThreadReceipt(proposalID: "settled-\(index)", filePath: "/x/pr12_threads_\(index).json",
                    requestID: message.id.uuidString, pullRequestURL: url, actions: [.init(threadID: "T1", operation: "reply", commentID: "C", url: url)],
                    requestEventIDs: [message.id.uuidString])
                f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: type, payload: record))
            }
        }
        addNoise(f, count: WorkspaceConfigManager.MirrorLimits.maxEventsPerTask + 5)

        let kept = try mirroredEventIDs(f)
        #expect(kept.contains(messages[11].id.uuidString))    // its batch is among the newest
        #expect(!kept.contains(messages[0].id.uuidString))    // its batch was compacted away
    }

    // MARK: - Selective negation in either order

    @Test("refusing an operation for one thread keeps it for another, whichever comes first")
    func selectiveNegationInEitherOrder() {
        #expect(request(for: "Resolve the first GitHub review thread, but do not resolve the second GitHub review thread")?.operations == ["resolve"])
        #expect(request(for: "Do not resolve the first GitHub review thread, but resolve the second GitHub review thread")?.operations == ["resolve"])
        // The same thing refused is a change of mind.
        #expect(request(for: "Resolve the review threads on PR 12. Do not resolve the review threads on PR 12.") == nil)
    }

    // MARK: - A continuation that changes pull request is not additive

    @Test("an additive follow-up about another pull request starts its own request")
    func additiveFollowUpOnAnotherPullRequestIsNotMerged() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Reply to the review threads on https://github.com/example/repo/pull/12"
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "also resolve the review threads on https://github.com/example/repo/pull/13"))
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))

        #expect(request.operations == ["resolve"])
        #expect(request.priorRequestIDs.isEmpty)
    }

    // MARK: - The request chain stays bounded

    @Test("a restatement does not drag the whole earlier chain along")
    func restatementsDoNotGrowTheChain() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Look at the open review feedback"
        for _ in 0..<30 {
            f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                       payload: "Reply to the review threads on https://github.com/example/repo/pull/12"))
        }
        #expect(try #require(GitHubReviewThreadRequirement.request(task: f.task)).sourceEventIDs.count == 1)

        for _ in 0..<40 {
            f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                       payload: "also resolve them"))
        }
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        #expect(request.operations.contains("resolve") && request.priorRequestIDs.count > 1)   // the follow-ups really chained
        #expect(request.sourceEventIDs.count <= 20)
    }

    // MARK: - Receipts an additive request still needs survive compaction

    @Test("a settled batch the current request still depends on is kept however old it is")
    func referencedSettledBatchesAreKept() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = "https://github.com/example/repo/pull/12"
        func insert(_ type: String, _ proposal: String, request: String, prior: [String] = []) {
            var record = GitHubReviewThreadReceipt(proposalID: proposal, filePath: "/x/\(proposal).json", requestID: request,
                pullRequestURL: url, actions: [.init(threadID: "T1", operation: "reply", commentID: "C", url: url)])
            record.priorRequestIDs = prior
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: type, payload: record))
        }
        insert(GitHubReviewThreadEvents.dispatched, "original", request: "r0")
        insert(GitHubReviewThreadEvents.receipt, "original", request: "r0")
        for index in 1...7 {   // more settled batches than the mirror keeps by age
            insert(GitHubReviewThreadEvents.dispatched, "later-\(index)", request: "r\(index)", prior: ["r0"])
            insert(GitHubReviewThreadEvents.receipt, "later-\(index)", request: "r\(index)", prior: ["r0"])
        }

        let workspace = try #require(f.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: f.context))
        let mirrored = try #require((config.tasks ?? []).first { $0.id == f.task.id.uuidString })
        let proposals = Set(mirrored.events.compactMap { event -> String? in
            (try? JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any])?["proposalID"] as? String
        })

        #expect(proposals.contains("original"))      // still named by the newer batches' chain
        #expect(proposals.contains("later-7"))
        #expect(!proposals.contains("later-1"))      // an old batch nothing depends on is compacted away
    }

    // MARK: - Shorthand pull request numbers

    @Test("an additive follow-up about another shorthand pull request starts its own request")
    func additiveFollowUpOnAnotherShorthandPullRequest() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Reply to the review threads on PR 12"
        f.context.insert(TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue,
                                   payload: "also resolve the review threads on PR 13"))
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))

        #expect(request.operations == ["resolve"])
        #expect(request.priorRequestIDs.isEmpty)
    }

    // MARK: - Bounding the chain keeps what changed the request

    @Test("bounding the message chain keeps the message that added an operation")
    func boundedChainKeepsOperationChangingMessages() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = "https://github.com/example/repo/pull/12"
        f.task.goal = "Resolve the review threads on \(url)"
        let start = Date()
        func message(_ text: String, _ offset: Int) -> TaskEvent {
            let event = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: text)
            event.timestamp = start.addingTimeInterval(TimeInterval(offset)); f.context.insert(event); return event
        }
        _ = message("also resolve them", 0)
        let reply = message("also reply to the review threads on \(url)", 1)   // the message that adds the reply
        for index in 2..<42 { _ = message("also resolve them", index) }
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))

        #expect(request.operations == ["reply", "resolve"])
        #expect(request.sourceEventIDs.count <= 20)
        #expect(request.sourceEventIDs.contains(reply.id))
    }

    @Test("the ancestry an additive request keeps is bounded")
    func additiveAncestryIsBounded() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.task.goal = "Reply to the review threads on https://github.com/example/repo/pull/12"
        let start = Date()
        for index in 0..<60 {
            let event = TaskEvent(task: f.task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "also resolve them")
            event.timestamp = start.addingTimeInterval(TimeInterval(index))
            f.context.insert(event)
        }
        let request = try #require(GitHubReviewThreadRequirement.request(task: f.task))
        #expect(request.priorRequestIDs.count > 1)
        #expect(request.priorRequestIDs.count <= 20)
    }

    @Test("a settled ancestor kept for a newer batch is compacted, not kept whole")
    func referencedAncestorsAreCompacted() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = "https://github.com/example/repo/pull/12"
        let payload = GitHubReviewThreadPayload(pullRequestUrl: url, commitId: Self.head, threads: [
            .init(threadId: "T1", expectedLastCommentId: "C1", reply: "Fixed", resolve: false)])
        func insert(_ type: String, _ proposal: String, request: String, prior: [String] = []) {
            var record = GitHubReviewThreadReceipt(proposalID: proposal, filePath: "/x/\(proposal).json", requestID: request,
                pullRequestURL: url, actions: [.init(threadID: "T1", operation: "reply", commentID: "C", url: url)])
            record.priorRequestIDs = prior
            record.approvedPayload = payload
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task, type: type, payload: record))
        }
        insert(GitHubReviewThreadEvents.dispatched, "original", request: "r0")
        insert(GitHubReviewThreadEvents.receipt, "original", request: "r0")
        for index in 1...7 {
            insert(GitHubReviewThreadEvents.dispatched, "later-\(index)", request: "r\(index)", prior: ["r0"])
            insert(GitHubReviewThreadEvents.receipt, "later-\(index)", request: "r\(index)", prior: ["r0"])
        }
        let workspace = try #require(f.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: f.context))
        let mirrored = try #require((config.tasks ?? []).first { $0.id == f.task.id.uuidString })
        func dispatched(_ proposal: String) -> [String: Any]? {
            mirrored.events.first { $0.type == GitHubReviewThreadEvents.dispatched && $0.payload.contains("\"\(proposal)\"") }
                .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.payload.utf8))) as? [String: Any] }
        }

        #expect(dispatched("original") != nil)
        #expect(dispatched("original")?["approvedPayload"] == nil)
        #expect(dispatched("later-7")?["approvedPayload"] != nil)
    }
}
