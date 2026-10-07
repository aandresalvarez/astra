import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

@MainActor
final class GitHubReviewThreadPublicationService {
    private let modelContext: ModelContext
    private let cli: any GitHubReviewCLI
    private let originURL: (String) async -> String?
    private let saveReceipt: ((AgentTask, ModelContext) throws -> Void)?

    init(modelContext: ModelContext, cli: any GitHubReviewCLI = NativeGitHubReviewCLI(),
         originURL: @escaping (String) async -> String? = { await GitService.shared.getRemoteOriginURL(at: $0) },
         saveReceipt: ((AgentTask, ModelContext) throws -> Void)? = nil) {
        self.modelContext = modelContext; self.cli = cli; self.originURL = originURL; self.saveReceipt = saveReceipt
    }

    static func hasDispatched(task: AgentTask, filePath: String) -> Bool {
        task.events.contains {
            guard $0.type == GitHubReviewThreadEvents.dispatched,
                  let data = $0.payload.data(using: .utf8),
                  let record = try? JSONDecoder().decode(GitHubReviewThreadReceipt.self, from: data) else { return false }
            return GitHubReviewThreadArtifactPolicy.identity(of: record.filePath) == GitHubReviewThreadArtifactPolicy.identity(of: filePath)
        }
    }

    static func hasDismissed(task: AgentTask, filePath: String) -> Bool {
        task.events.contains {
            guard $0.type == GitHubReviewThreadEvents.dismissed,
                  let data = $0.payload.data(using: .utf8),
                  let record = try? JSONDecoder().decode(GitHubReviewThreadDismissal.self, from: data) else { return false }
            return GitHubReviewThreadArtifactPolicy.identity(of: record.filePath) == GitHubReviewThreadArtifactPolicy.identity(of: filePath)
        }
    }

    static func pendingCandidatePath(task: AgentTask, filePaths: [String]) -> String? {
        filePaths.first {
            GitHubReviewThreadArtifactPolicy.isProposalFile($0)
                && !hasDispatched(task: task, filePath: $0) && !hasDismissed(task: task, filePath: $0)
        }
    }

    /// The first proposal that validates. One that cannot be used (stale head, a
    /// thread resolved or edited since, a foreign target, an invalid file) is
    /// dismissed durably and skipped, so a dead file never hides a usable one or
    /// a review proposal. Anything else, such as a GitHub outage, leaves the file
    /// in place to be tried again.
    func prepareFirstAvailable(task: AgentTask, filePaths: [String]) async throws -> GitHubReviewThreadProposal {
        var lastUnusable: Error?
        var dismissals: [GitHubReviewThreadDismissal] = []
        for path in filePaths where GitHubReviewThreadArtifactPolicy.isProposalFile(path)
            && !Self.hasDispatched(task: task, filePath: path) && !Self.hasDismissed(task: task, filePath: path) {
            do {
                let proposal = try await prepare(task: task, filePath: path)
                try persistDismissals(dismissals, task: task)
                return proposal
            } catch GitHubReviewPublicationError.unusableArtifact(let reason) {
                lastUnusable = GitHubReviewPublicationError.unusableArtifact(reason)
                dismissals.append(.init(filePath: path, reason: reason))
            } catch {
                // A transient failure leaves this candidate pending, but what was already
                // found unusable stays skipped instead of being retried every time.
                try? persistDismissals(dismissals, task: task)
                throw error
            }
        }
        try persistDismissals(dismissals, task: task)
        throw lastUnusable ?? GitHubReviewPublicationError.invalid("No thread proposal is available to send.")
    }

    private func persistDismissals(_ records: [GitHubReviewThreadDismissal], task: AgentTask) throws {
        guard !records.isEmpty else { return }
        let events = records.map {
            TaskEvent.structuredPayloadEvent(task: task, type: GitHubReviewThreadEvents.dismissed, payload: $0)
        }
        events.forEach(modelContext.insert)
        do { try save(task: task, operation: "github_review_threads_dismissed") }
        catch {
            events.forEach { modelContext.delete($0) }
            task.events.removeAll { event in events.contains { $0.id == event.id } }
            throw error
        }
    }

    /// Failures of the proposal itself, as opposed to failing to reach GitHub.
    private static func unusable<T>(_ body: () throws -> T) rethrows -> T {
        do { return try body() }
        catch let error as GitHubReviewPublicationError {
            if case .invalid(let message) = error { throw GitHubReviewPublicationError.unusableArtifact(message) }
            throw error
        } catch { throw GitHubReviewPublicationError.unusableArtifact(error.localizedDescription) }
    }

    private static func unusable<T>(_ body: () async throws -> T) async rethrows -> T {
        do { return try await body() }
        catch let error as GitHubReviewPublicationError {
            if case .invalid(let message) = error { throw GitHubReviewPublicationError.unusableArtifact(message) }
            throw error
        } catch { throw GitHubReviewPublicationError.unusableArtifact(error.localizedDescription) }
    }

    func prepare(task: AgentTask, filePath: String) async throws -> GitHubReviewThreadProposal {
        guard !Self.hasDispatched(task: task, filePath: filePath) else { throw GitHubReviewPublicationError.alreadyDispatched }
        guard !Self.hasDismissed(task: task, filePath: filePath) else {
            throw GitHubReviewPublicationError.unusableArtifact("This thread proposal was dismissed after validation failed. Save a corrected proposal under a new versioned filename.")
        }
        let (data, payload) = try Self.unusable { try readPayload(task: task, filePath: filePath) }
        try await validateTarget(task: task, payload: payload, filePath: filePath)
        var snapshots: [GitHubReviewThreadSnapshot] = []
        for action in payload.threads {
            let snapshot = try await loadThread(task: task, id: action.threadId)
            try Self.unusable { try validate(snapshot, action: action, payload: payload) }
            try requirePermissions(snapshot, action: action)
            snapshots.append(snapshot)
        }
        let request = GitHubReviewThreadRequirement.request(task: task)
        let requestID = request?.id
        // Bind approval to the entire live discussion, including comment edits.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(snapshots)
        let digest = GitHubReviewThreadArtifactPolicy.digest(data)
        let id = GitHubReviewThreadArtifactPolicy.digest(Data("\(filePath):\(digest):\(requestID ?? "")".utf8) + snapshotData)
        return GitHubReviewThreadProposal(id: id, filePath: filePath, digest: digest, requestID: requestID,
                                         requestEventIDs: (request?.sourceEventIDs ?? []).map(\.uuidString),
                                         chainID: request?.chain,
                                         payload: payload, snapshots: snapshots)
    }

    func publish(task: AgentTask, proposal: GitHubReviewThreadProposal) async throws -> GitHubReviewThreadReceipt {
        let fresh = try await prepare(task: task, filePath: proposal.filePath)
        guard fresh.id == proposal.id else {
            throw GitHubReviewPublicationError.invalid("The proposal, request, or review discussion changed. Review it again before sending.")
        }
        // Preparing awaits GitHub. Recheck the file and durable dispatch after
        // those awaits, before recording a dispatch or starting any write.
        let (currentData, _) = try readPayload(task: task, filePath: proposal.filePath)
        guard GitHubReviewThreadArtifactPolicy.digest(currentData) == proposal.digest else {
            throw GitHubReviewPublicationError.invalid("The proposal file changed during validation. Review it again.")
        }
        guard !Self.hasDispatched(task: task, filePath: proposal.filePath) else { throw GitHubReviewPublicationError.alreadyDispatched }
        let run = task.runs.max { $0.startedAt < $1.startedAt }
        var dispatch = record(proposal, actions: [])
        dispatch.approvedPayload = proposal.payload
        let event = TaskEvent.structuredPayloadEvent(task: task, type: GitHubReviewThreadEvents.dispatched, payload: dispatch, run: run)
        modelContext.insert(event)
        do { try save(task: task, operation: "github_review_threads_dispatch") }
        catch { modelContext.delete(event); task.events.removeAll { $0.id == event.id }; throw error }

        var receipts: [GitHubReviewThreadReceipt.Action] = []
        // Set just before the first request that can write. A failure before that left GitHub
        // untouched, so it must not consume the proposal.
        var attemptedWrite = false
        do {
            for (index, action) in proposal.payload.threads.enumerated() {
                // Revalidate each thread immediately before its writes, since a
                // prior thread may have taken time or triggered new review activity.
                let snapshot = try await loadThread(task: task, id: action.threadId)
                try validate(snapshot, action: action, payload: proposal.payload)
                try requirePermissions(snapshot, action: action)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(snapshot) == encoder.encode(proposal.snapshots[index]) else {
                    throw GitHubReviewPublicationError.invalid("A review discussion changed before sending.")
                }
                if let body = action.reply {
                    let receipt = try await mutate(task: task, proposal: proposal, action: action, body: body,
                                                   willSend: { attemptedWrite = true })
                    receipts.append(receipt)
                    try saveActionReceipt(record(proposal, actions: [receipt]), task: task, run: run)
                }
                if action.resolve {
                    // Recheck ownership, head and latest comment after our reply.
                    let latest = try await loadThread(task: task, id: action.threadId)
                    let lastID = receipts.last?.threadID == action.threadId && receipts.last?.operation == "reply"
                        ? receipts.last?.commentID : action.expectedLastCommentId
                    // The approved discussion must still be exactly what was approved, with only
                    // our own reply after it: an earlier comment edited or deleted since the
                    // snapshot would leave the reply as the last comment and pass a last-id check.
                    let replied = receipts.last?.threadID == action.threadId && receipts.last?.operation == "reply"
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let approvedComments = try encoder.encode(proposal.snapshots[index].comments)
                    let currentComments = try encoder.encode(replied ? Array(latest.comments.dropLast()) : latest.comments)
                    guard latest.pullRequest.url.caseInsensitiveCompare(proposal.payload.pullRequestUrl) == .orderedSame,
                          latest.pullRequest.headRefOid.caseInsensitiveCompare(proposal.payload.commitId) == .orderedSame,
                          latest.pullRequest.state == "OPEN", !latest.isResolved, latest.viewerCanResolve,
                          latest.comments.last?.id == lastID, currentComments == approvedComments else {
                        throw GitHubReviewPublicationError.invalid("The PR or thread changed after posting the reply; resolution was not sent.")
                    }
                    let receipt = try await mutate(task: task, proposal: proposal, action: action, body: nil,
                                                   willSend: { attemptedWrite = true })
                    receipts.append(receipt)
                    try saveActionReceipt(record(proposal, actions: [receipt]), task: task, run: run)
                }
            }
        } catch {
            if !attemptedWrite {
                // Nothing was sent: take the dispatch back so the unchanged proposal can be sent again.
                modelContext.delete(event); task.events.removeAll { $0.id == event.id }
                try? save(task: task, operation: "github_review_threads_dispatch_withdrawn")
                throw GitHubReviewPublicationError.invalid("GitHub could not be checked before anything was sent, so nothing changed. Send the proposal again. \(error.localizedDescription)")
            }
            modelContext.insert(TaskEvent.structuredPayloadEvent(task: task, type: GitHubReviewThreadEvents.indeterminate,
                                                                payload: record(proposal, actions: receipts), run: run))
            try? save(task: task, operation: "github_review_threads_indeterminate")
            throw GitHubReviewPublicationError.invalid("Some thread changes may already be on GitHub. ASTRA will not resend this proposal. Check the recorded receipts and GitHub before preparing any remaining changes. \(error.localizedDescription)")
        }
        return try await finish(record(proposal, actions: receipts), task: task, run: run)
    }

    private func record(_ proposal: GitHubReviewThreadProposal, actions: [GitHubReviewThreadReceipt.Action]) -> GitHubReviewThreadReceipt {
        .init(proposalID: proposal.id, filePath: proposal.filePath, requestID: proposal.requestID,
              pullRequestURL: proposal.payload.pullRequestUrl, actions: actions,
              requestEventIDs: proposal.requestEventIDs,
              chainID: proposal.chainID)
    }

    private func save(task: AgentTask, operation: String) throws {
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: task.workspace, modelContext: modelContext,
                                                                    taskID: task.id, auditFields: ["operation": operation])
    }

    private func saveActionReceipt(_ receipt: GitHubReviewThreadReceipt, task: AgentTask, run: TaskRun?) throws {
        modelContext.insert(TaskEvent.structuredPayloadEvent(task: task, type: GitHubReviewThreadEvents.actionReceipt, payload: receipt, run: run))
        try save(task: task, operation: "github_review_thread_action_receipt")
    }

    private func finish(_ receipt: GitHubReviewThreadReceipt, task: AgentTask, run: TaskRun?) async throws -> GitHubReviewThreadReceipt {
        let eventIDs = Set(task.events.map(\.id))
        let priorState = TaskStateMachine.ExternalOutcomeReceiptSnapshot(task: task, run: run)
        for eventType in [GitHubReviewThreadEvents.receipt, GitHubReviewThreadEvents.receiptRecovery] {
            modelContext.insert(TaskEvent.structuredPayloadEvent(task: task, type: eventType, payload: receipt, run: run))
            if task.status == .pendingUser, run?.typedStopReason == .externalOutcomePending, let run {
                _ = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(task: task, run: run, modelContext: modelContext)
            }
            do {
                if eventType == GitHubReviewThreadEvents.receipt, let saveReceipt { try saveReceipt(task, modelContext) }
                else { try save(task: task, operation: "github_review_threads_receipt") }
                return receipt
            } catch {
                modelContext.rollback()
                task.events.removeAll { !eventIDs.contains($0.id) }
                TaskStateMachine.restoreFailedExternalOutcomeReceipt(task: task, run: run, snapshot: priorState)
            }
        }
        throw GitHubReviewPublicationError.receiptPersistenceFailed(receipt.pullRequestURL)
    }

    private func readPayload(task: AgentTask, filePath: String) throws -> (Data, GitHubReviewThreadPayload) {
        let root = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder).resolvingSymlinksInPath().path
        let url = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        guard root != "/", url.path.hasPrefix(root + "/"), GitHubReviewThreadArtifactPolicy.isProposalFile(url.path) else {
            throw GitHubReviewPublicationError.invalid("Choose a pr<NUMBER>_threads.json proposal from this task’s folder.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size > 0, size <= 256 * 1024 else {
            throw GitHubReviewPublicationError.invalid("The thread proposal must be a regular JSON file under 256 KB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["pull_request_url", "commit_id", "threads"],
              let actions = object["threads"] as? [[String: Any]],
              actions.allSatisfy({ Set($0.keys).isSubset(of: ["thread_id", "expected_last_comment_id", "reply", "resolve"]) }) else {
            throw GitHubReviewPublicationError.invalid("The thread proposal contains fields ASTRA cannot show for approval.")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(GitHubReviewThreadPayload.self, from: data)
        guard GitHubReviewThreadArtifactPolicy.target(payload.pullRequestUrl) != nil,
              payload.commitId.count == 40, payload.commitId.allSatisfy(\.isHexDigit),
              !payload.threads.isEmpty, payload.threads.count <= 100,
              Set(payload.threads.map(\.threadId)).count == payload.threads.count,
              payload.threads.allSatisfy({ action in
                  GitHubReviewThreadReadOperation.isNodeID(action.threadId)
                    && GitHubReviewThreadReadOperation.isNodeID(action.expectedLastCommentId)
                    && (action.resolve || action.reply != nil)
                    && (action.reply.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 65_536 } ?? true)
              }) else { throw GitHubReviewPublicationError.invalid("The proposal needs a PR URL, head commit, unique thread IDs, latest comment IDs, and replies or resolutions.") }
        return (data, payload)
    }

    private static func pullRequestNumbers(in text: String) -> [String] {
        let patterns = [#"(?i)\b(?:PR|pull request)\s*#?([1-9][0-9]*)\b"#, #"(?i)github\.com/[^/\s]+/[^/\s]+/pull/([1-9][0-9]*)"#]
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
    }

    /// A defect of the proposal (its name, or a PR other than the request names) is
    /// `unusableArtifact` and dismisses it. Missing repository context, such as a
    /// workspace with no readable GitHub origin, is `invalid`: the user can supply
    /// it, and the same proposal must work afterwards.
    private func validateTarget(task: AgentTask, payload: GitHubReviewThreadPayload, filePath: String) async throws {
        guard let target = GitHubReviewThreadArtifactPolicy.target(payload.pullRequestUrl),
              URL(fileURLWithPath: filePath).lastPathComponent.hasPrefix("pr\(target.number)_threads") else {
            throw GitHubReviewPublicationError.unusableArtifact("The thread proposal filename does not match its pull request.")
        }
        let request = GitHubReviewThreadRequirement.request(task: task)?.targetText ?? task.goal
        // One proposal targets one pull request and one receipt settles the request, so
        // a request naming several would be marked done after the first.
        if Set(Self.pullRequestNumbers(in: request)).count > 1 {
            throw GitHubReviewPublicationError.invalid("The request names more than one pull request. Ask for one pull request at a time.")
        }
        if request.range(of: "github.com/", options: .caseInsensitive) != nil,
           GitHubReviewTargetResolver.durableTarget(task: task, request: request) == nil {
            throw GitHubReviewPublicationError.invalid("The request must identify one GitHub pull request.")
        }
        if let expected = GitHubReviewTargetResolver.durableTarget(task: task, request: request) {
            guard expected.url.caseInsensitiveCompare(payload.pullRequestUrl) == .orderedSame else {
                throw GitHubReviewPublicationError.unusableArtifact("The thread proposal targets a different PR from the user's request.")
            }
        } else {
            guard let origin = await originURL(task.executionRootPath ?? task.workspace?.primaryPath ?? ""),
                  let repository = GitService.githubRepositoryArgument(from: origin),
                  repository.caseInsensitiveCompare("github.com/" + target.repository) == .orderedSame else {
                throw GitHubReviewPublicationError.invalid("Add the full PR URL to the task request or connect its workspace to the target GitHub repository.")
            }
            if let requested = GitHubReviewTargetResolver.shorthandNumber(in: request), requested != target.number {
                throw GitHubReviewPublicationError.unusableArtifact("The thread proposal targets a different PR from the user's request.")
            }
        }
    }

    /// What the signed-in account may do is not a defect of the proposal: it changes
    /// when the user switches account or is granted access, so it stays retryable
    /// instead of dismissing the file.
    private func requirePermissions(_ snapshot: GitHubReviewThreadSnapshot, action: GitHubReviewThreadPayload.Action) throws {
        if action.reply != nil, !snapshot.viewerCanReply {
            throw GitHubReviewPublicationError.invalid("The signed-in GitHub account cannot reply to this thread. Switch account or ask for access, then review the proposal again.")
        }
        if action.resolve, !snapshot.viewerCanResolve {
            throw GitHubReviewPublicationError.invalid("The signed-in GitHub account cannot resolve this thread. Switch account or ask for access, then review the proposal again.")
        }
    }

    private func validate(_ snapshot: GitHubReviewThreadSnapshot, action: GitHubReviewThreadPayload.Action, payload: GitHubReviewThreadPayload) throws {
        guard snapshot.id == action.threadId,
              snapshot.pullRequest.url.caseInsensitiveCompare(payload.pullRequestUrl) == .orderedSame,
              snapshot.pullRequest.state == "OPEN", snapshot.pullRequest.headRefOid.caseInsensitiveCompare(payload.commitId) == .orderedSame,
              !snapshot.isResolved,
              snapshot.comments.last?.id == action.expectedLastCommentId else {
            throw GitHubReviewPublicationError.invalid("The thread is unavailable, resolved, changed, or belongs to another PR/head. Read it again and prepare a new proposal.")
        }
    }

    private struct ThreadResponse: Decodable {
        struct Node: Decodable {
            struct Comments: Decodable {
                struct Page: Decodable { let hasNextPage: Bool; let endCursor: String? }
                let totalCount: Int; let pageInfo: Page; let nodes: [GitHubReviewThreadSnapshot.Comment]
            }
            let id: String; let path: String; let line: Int?; let isResolved: Bool; let viewerCanResolve: Bool; let viewerCanReply: Bool
            let pullRequest: GitHubReviewThreadSnapshot.PullRequest; let comments: Comments
        }
        struct ResponseData: Decodable { let node: Node? }
        let data: ResponseData?
        let errors: [GraphQLError]?
    }
    private struct GraphQLError: Decodable { let message: String; let type: String? }
    private static let missingThreadMessage = "A thread in this proposal no longer exists or is not accessible. Read the pull request again and prepare a new proposal."
    /// GitHub answers an unknown or inaccessible node id with this text. A transport,
    /// rate-limit or sign-in failure does not, so those stay retryable.
    private static func isMissingNode(_ text: String) -> Bool { text.contains("Could not resolve to a node") }

    private func loadThread(task: AgentTask, id: String) async throws -> GitHubReviewThreadSnapshot {
        var cursor: String?; var seen: Set<String> = []; var snapshot: GitHubReviewThreadSnapshot?
        for _ in 0..<1000 {
            var input = ["review-thread", "--id", id]
            if let cursor { input += ["--after", cursor] }
            let output: String
            do {
                output = try await cli.run(at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
                                          arguments: GitHubReviewThreadReadOperation.arguments(for: input), label: "Read GitHub review thread")
            } catch GitHubCLIError.commandFailed(let detail) where Self.isMissingNode(detail) {
                throw GitHubReviewPublicationError.unusableArtifact(Self.missingThreadMessage)
            }
            // A node id of another GitHub type matches none of the query's inline
            // fragment, so GitHub answers `"node": {}`, which has no thread to decode.
            if let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
               let data = object["data"] as? [String: Any], let node = data["node"] as? [String: Any], node.isEmpty {
                throw GitHubReviewPublicationError.unusableArtifact("A thread id in this proposal does not refer to a review thread. Read the pull request again and prepare a new proposal.")
            }
            let response = try JSONDecoder().decode(ThreadResponse.self, from: Data(output.utf8))
            if response.errors?.contains(where: { $0.type == "NOT_FOUND" || Self.isMissingNode($0.message) }) == true
                || (response.errors?.isEmpty ?? true) && response.data?.node == nil {
                throw GitHubReviewPublicationError.unusableArtifact(Self.missingThreadMessage)
            }
            guard response.errors?.isEmpty ?? true, let node = response.data?.node else {
                throw GitHubReviewPublicationError.invalid("GitHub did not return the requested review thread.")
            }
            if snapshot == nil {
                snapshot = .init(id: node.id, path: node.path, line: node.line, isResolved: node.isResolved,
                                 viewerCanResolve: node.viewerCanResolve, viewerCanReply: node.viewerCanReply, pullRequest: node.pullRequest, comments: [])
            }
            guard snapshot?.id == node.id, snapshot?.pullRequest.headRefOid == node.pullRequest.headRefOid,
                  snapshot?.isResolved == node.isResolved else { throw GitHubReviewPublicationError.invalid("The discussion changed while paging.") }
            snapshot?.comments += node.comments.nodes
            if !node.comments.pageInfo.hasNextPage, let snapshot {
                guard snapshot.comments.count == node.comments.totalCount,
                      Set(snapshot.comments.map(\.id)).count == snapshot.comments.count else {
                    throw GitHubReviewPublicationError.invalid("GitHub returned an incomplete discussion.")
                }
                return snapshot
            }
            guard let next = node.comments.pageInfo.endCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw GitHubReviewPublicationError.invalid("GitHub returned an incomplete discussion page.")
            }
            cursor = next
        }
        throw GitHubReviewPublicationError.invalid("This discussion is too large to validate safely.")
    }

    /// `willSend` runs immediately before the request that can write. Everything before it
    /// (the digest and request rechecks, building the input) can fail without GitHub having
    /// been touched.
    private func mutate(task: AgentTask, proposal: GitHubReviewThreadProposal, action: GitHubReviewThreadPayload.Action,
                        body: String?, willSend: () -> Void) async throws -> GitHubReviewThreadReceipt.Action {
        let (data, _) = try readPayload(task: task, filePath: proposal.filePath)
        guard GitHubReviewThreadArtifactPolicy.digest(data) == proposal.digest,
              GitHubReviewThreadRequirement.request(task: task)?.id == proposal.requestID else {
            throw GitHubReviewPublicationError.invalid("The approved proposal or user request changed before sending.")
        }
        let mutationID = proposal.id + ":" + action.threadId + (body == nil ? ":resolve" : ":reply")
        var variables: [String: Any] = ["threadId": action.threadId, "mutationId": mutationID]
        if let body { variables["body"] = body }
        let query = body == nil ? Self.resolveMutation : Self.replyMutation
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("astra-thread-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]).write(to: input, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: input) }
        willSend()
        let output = try await cli.run(at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
                                      arguments: ["api", "graphql", "--hostname", "github.com", "--input", input.path], label: "Send approved GitHub thread change")
        guard let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              (object["errors"] as? [Any] ?? []).isEmpty,
              let data = object["data"] as? [String: Any], let result = data["change"] as? [String: Any],
              result["clientMutationId"] as? String == mutationID else { throw GitHubReviewPublicationError.uncertain }
        if let body {
            guard let comment = result["comment"] as? [String: Any], let id = comment["id"] as? String,
                  GitHubReviewThreadReadOperation.isNodeID(id), comment["body"] as? String == body,
                  let url = comment["url"] as? String,
                  Self.matchesCommentURL(url, pullRequestURL: proposal.payload.pullRequestUrl),
                  let target = (comment["pullRequest"] as? [String: Any])?["url"] as? String,
                  target.caseInsensitiveCompare(proposal.payload.pullRequestUrl) == .orderedSame else {
                throw GitHubReviewPublicationError.uncertain
            }
            return .init(threadID: action.threadId, operation: "reply", commentID: id, url: url)
        }
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == action.threadId,
              thread["isResolved"] as? Bool == true,
              let target = (thread["pullRequest"] as? [String: Any])?["url"] as? String,
              target.caseInsensitiveCompare(proposal.payload.pullRequestUrl) == .orderedSame else {
            throw GitHubReviewPublicationError.uncertain
        }
        return .init(threadID: action.threadId, operation: "resolve", commentID: nil, url: nil)
    }

    private static func matchesCommentURL(_ url: String, pullRequestURL: String) -> Bool {
        guard let actual = URLComponents(string: url), let expected = URLComponents(string: pullRequestURL),
              actual.scheme == "https", actual.host == "github.com", actual.port == nil,
              actual.user == nil, actual.password == nil, actual.query == nil,
              actual.path.caseInsensitiveCompare(expected.path) == .orderedSame,
              let fragment = actual.fragment else { return false }
        return fragment.range(of: #"^discussion_r[1-9][0-9]*$"#, options: .regularExpression) != nil
    }

    private static let replyMutation = """
    mutation($threadId: ID!, $body: String!, $mutationId: String!) {
      change: addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body, clientMutationId: $mutationId}) {
        clientMutationId comment { id body url pullRequest { url } }
      }
    }
    """
    private static let resolveMutation = """
    mutation($threadId: ID!, $mutationId: String!) {
      change: resolveReviewThread(input: {threadId: $threadId, clientMutationId: $mutationId}) {
        clientMutationId thread { id isResolved pullRequest { url } }
      }
    }
    """
}
