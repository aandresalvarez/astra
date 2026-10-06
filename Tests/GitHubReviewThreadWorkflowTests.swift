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
        var paginate = false; var replacement: (URL, Data)?; var failReads = false; var missingThreads: Set<String> = []

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
            if let id = arguments.first(where: { $0.hasPrefix("id=") }).map({ String($0.dropFirst(3)) }), missingThreads.contains(id) {
                throw GitHubCLIError.commandFailed("gh: Could not resolve to a node with the global id of '\(id)'")
            }
            #expect(arguments.contains { $0.hasPrefix("query=query(") })
            if let (url, data) = replacement { replacement = nil; try data.write(to: url) }
            let after = arguments.contains { $0.hasPrefix("after=") }
            let nodes = paginate ? (after ? Array(comments.dropFirst()) : Array(comments.prefix(1))) : comments
            return try json(["data": ["node": [
                "id": "T1", "path": "src/main.swift", "line": 12, "isResolved": resolved, "viewerCanResolve": true,
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
        "Reply to the reviewer comments on this PR"
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
        "Resolve the merge conflicts in my GitHub PR and update the review",
        "Review this GitHub PR and reply with your comments here",
        "Review the pull request and reply with your review comments in this chat",
        "Reply to the Slack thread, then inspect GitHub PR #12",
        "Reply to the Slack thread then inspect GitHub PR #12",
        "Reply to the Slack thread. Afterwards look at the GitHub PR"
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
        for phrase in ["cancel it", "skip it", "forget that", "drop them", "never mind"] {
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
}
