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
            return record.filePath == filePath
        }
    }

    static func pendingCandidatePath(task: AgentTask, filePaths: [String]) -> String? {
        filePaths.first { GitHubReviewThreadArtifactPolicy.isProposalFile($0) && !hasDispatched(task: task, filePath: $0) }
    }

    func prepare(task: AgentTask, filePath: String) async throws -> GitHubReviewThreadProposal {
        guard !Self.hasDispatched(task: task, filePath: filePath) else { throw GitHubReviewPublicationError.alreadyDispatched }
        let (data, payload) = try readPayload(task: task, filePath: filePath)
        try await validateTarget(task: task, payload: payload, filePath: filePath)
        var snapshots: [GitHubReviewThreadSnapshot] = []
        for action in payload.threads {
            let snapshot = try await loadThread(task: task, id: action.threadId)
            try validate(snapshot, action: action, payload: payload)
            snapshots.append(snapshot)
        }
        let requestID = GitHubReviewThreadRequirement.request(task: task)?.id
        // Bind approval to the entire live discussion, including comment edits.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(snapshots)
        let digest = GitHubReviewThreadArtifactPolicy.digest(data)
        let id = GitHubReviewThreadArtifactPolicy.digest(Data("\(filePath):\(digest):\(requestID ?? "")".utf8) + snapshotData)
        return GitHubReviewThreadProposal(id: id, filePath: filePath, digest: digest, requestID: requestID,
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
        do {
            for (index, action) in proposal.payload.threads.enumerated() {
                // Revalidate each thread immediately before its writes, since a
                // prior thread may have taken time or triggered new review activity.
                let snapshot = try await loadThread(task: task, id: action.threadId)
                try validate(snapshot, action: action, payload: proposal.payload)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(snapshot) == encoder.encode(proposal.snapshots[index]) else {
                    throw GitHubReviewPublicationError.invalid("A review discussion changed before sending.")
                }
                if let body = action.reply {
                    let receipt = try await mutate(task: task, proposal: proposal, action: action, body: body)
                    receipts.append(receipt)
                    try saveActionReceipt(record(proposal, actions: [receipt]), task: task, run: run)
                }
                if action.resolve {
                    // Recheck ownership, head and latest comment after our reply.
                    let latest = try await loadThread(task: task, id: action.threadId)
                    let lastID = receipts.last?.threadID == action.threadId && receipts.last?.operation == "reply"
                        ? receipts.last?.commentID : action.expectedLastCommentId
                    guard latest.pullRequest.url.caseInsensitiveCompare(proposal.payload.pullRequestUrl) == .orderedSame,
                          latest.pullRequest.headRefOid.caseInsensitiveCompare(proposal.payload.commitId) == .orderedSame,
                          latest.pullRequest.state == "OPEN", !latest.isResolved, latest.viewerCanResolve,
                          latest.comments.last?.id == lastID else {
                        throw GitHubReviewPublicationError.invalid("The PR or thread changed after posting the reply; resolution was not sent.")
                    }
                    let receipt = try await mutate(task: task, proposal: proposal, action: action, body: nil)
                    receipts.append(receipt)
                    try saveActionReceipt(record(proposal, actions: [receipt]), task: task, run: run)
                }
            }
        } catch {
            modelContext.insert(TaskEvent.structuredPayloadEvent(task: task, type: GitHubReviewThreadEvents.indeterminate,
                                                                payload: record(proposal, actions: receipts), run: run))
            try? save(task: task, operation: "github_review_threads_indeterminate")
            throw GitHubReviewPublicationError.invalid("Some thread changes may already be on GitHub. ASTRA will not resend this proposal. Check the recorded receipts and GitHub before preparing any remaining changes. \(error.localizedDescription)")
        }
        return try await finish(record(proposal, actions: receipts), task: task, run: run)
    }

    private func record(_ proposal: GitHubReviewThreadProposal, actions: [GitHubReviewThreadReceipt.Action]) -> GitHubReviewThreadReceipt {
        .init(proposalID: proposal.id, filePath: proposal.filePath, requestID: proposal.requestID,
              pullRequestURL: proposal.payload.pullRequestUrl, actions: actions)
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

    private func validateTarget(task: AgentTask, payload: GitHubReviewThreadPayload, filePath: String) async throws {
        guard let target = GitHubReviewThreadArtifactPolicy.target(payload.pullRequestUrl),
              URL(fileURLWithPath: filePath).lastPathComponent.hasPrefix("pr\(target.number)_threads") else {
            throw GitHubReviewPublicationError.invalid("The thread proposal filename does not match its pull request.")
        }
        let request = GitHubReviewThreadRequirement.request(task: task)?.text ?? task.goal
        if request.range(of: "github.com/", options: .caseInsensitive) != nil,
           GitHubReviewTargetResolver.durableTarget(task: task, request: request) == nil {
            throw GitHubReviewPublicationError.invalid("The request must identify one GitHub pull request.")
        }
        if let expected = GitHubReviewTargetResolver.durableTarget(task: task, request: request) {
            guard expected.url.caseInsensitiveCompare(payload.pullRequestUrl) == .orderedSame else {
                throw GitHubReviewPublicationError.invalid("The thread proposal targets a different PR from the user's request.")
            }
        } else {
            guard request.range(of: "github.com/", options: .caseInsensitive) == nil,
                  let origin = await originURL(task.executionRootPath ?? task.workspace?.primaryPath ?? ""),
                  let repository = GitService.githubRepositoryArgument(from: origin),
                  repository.caseInsensitiveCompare("github.com/" + target.repository) == .orderedSame,
                  GitHubReviewTargetResolver.shorthandNumber(in: request).map({ $0 == target.number }) ?? true else {
                throw GitHubReviewPublicationError.invalid("Add the full PR URL to the task request or connect its workspace to the target GitHub repository.")
            }
        }
    }

    private func validate(_ snapshot: GitHubReviewThreadSnapshot, action: GitHubReviewThreadPayload.Action, payload: GitHubReviewThreadPayload) throws {
        guard snapshot.id == action.threadId,
              snapshot.pullRequest.url.caseInsensitiveCompare(payload.pullRequestUrl) == .orderedSame,
              snapshot.pullRequest.state == "OPEN", snapshot.pullRequest.headRefOid.caseInsensitiveCompare(payload.commitId) == .orderedSame,
              !snapshot.isResolved, (!action.resolve || snapshot.viewerCanResolve),
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
            let id: String; let path: String; let line: Int?; let isResolved: Bool; let viewerCanResolve: Bool
            let pullRequest: GitHubReviewThreadSnapshot.PullRequest; let comments: Comments
        }
        struct ResponseData: Decodable { let node: Node? }
        let data: ResponseData?
        let errors: [GraphQLError]?
    }
    private struct GraphQLError: Decodable { let message: String }

    private func loadThread(task: AgentTask, id: String) async throws -> GitHubReviewThreadSnapshot {
        var cursor: String?; var seen: Set<String> = []; var snapshot: GitHubReviewThreadSnapshot?
        for _ in 0..<50 {
            var input = ["review-thread", "--id", id]
            if let cursor { input += ["--after", cursor] }
            let output = try await cli.run(at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
                                          arguments: GitHubReviewThreadReadOperation.arguments(for: input), label: "Read GitHub review thread")
            let response = try JSONDecoder().decode(ThreadResponse.self, from: Data(output.utf8))
            guard response.errors?.isEmpty ?? true, let node = response.data?.node else {
                throw GitHubReviewPublicationError.invalid("GitHub did not return the requested review thread.")
            }
            if snapshot == nil {
                snapshot = .init(id: node.id, path: node.path, line: node.line, isResolved: node.isResolved,
                                 viewerCanResolve: node.viewerCanResolve, pullRequest: node.pullRequest, comments: [])
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

    private func mutate(task: AgentTask, proposal: GitHubReviewThreadProposal, action: GitHubReviewThreadPayload.Action,
                        body: String?) async throws -> GitHubReviewThreadReceipt.Action {
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
