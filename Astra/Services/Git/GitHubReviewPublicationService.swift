import CryptoKit
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// A review composed by an agent is data until the user approves this exact
/// destination, commit, summary, and set of inline comments.
struct GitHubReviewProposal: Identifiable {
    let id: String
    let filePath: String
    let digest: String
    let repository: String
    let pullRequestNumber: Int
    let pullRequestURL: String
    let payload: GitHubReviewPayload

    var endpoint: String { "repos/\(repository)/pulls/\(pullRequestNumber)/reviews" }
}

struct GitHubReviewPayload: Decodable {
    struct Comment: Decodable {
        let path: String
        let line: Int
        let side: String
        let body: String
        let startLine: Int?
        let startSide: String?
    }

    let body: String
    let event: String
    let commitId: String
    let comments: [Comment]

    private enum CodingKeys: String, CodingKey {
        case body, event, commitId, comments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decode(String.self, forKey: .body)
        event = try container.decode(String.self, forKey: .event)
        commitId = try container.decode(String.self, forKey: .commitId)
        comments = try container.decodeIfPresent([Comment].self, forKey: .comments) ?? []
    }
}

struct GitHubReviewPublicationRecord: Codable {
    let proposalID: String
    let filePath: String
    let pullRequestURL: String
    let reviewURL: String?
    let reviewID: Int?
}

enum GitHubReviewPublicationEventTypes {
    static let dispatched = "github.review.dispatched"
    static let receipt = "github.review.receipt"
    static let indeterminate = "github.review.indeterminate"
}

/// The latest user request, rather than the task's original goal, determines
/// whether posting a review is still owed. A local JSON artifact is not proof
/// of that external result.
enum GitHubReviewPublicationRequirement {
    static func isPending(task: AgentTask) -> Bool {
        let latestRequest = task.events
            .filter { $0.type == TaskEventTypes.Conversation.userMessage.rawValue }
            .max { $0.timestamp < $1.timestamp }
        let requestText = latestRequest?.payload ?? task.goal
        let lower = requestText.lowercased()
        let asksToPost = lower.range(of: #"\b(post|publish|submit|add)\b"#, options: .regularExpression) != nil
        let namesReview = lower.range(of: #"\b(comments?|review)\b"#, options: .regularExpression) != nil
        let namesPullRequest = lower.range(of: #"\b(pr|pull request|github)\b"#, options: .regularExpression) != nil
        guard asksToPost && namesReview && namesPullRequest else { return false }
        return !task.events.contains { event in
            event.type == GitHubReviewPublicationEventTypes.receipt
                && (latestRequest.map { event.timestamp >= $0.timestamp } ?? true)
        }
    }
}

enum GitHubReviewPublicationError: LocalizedError {
    case invalid(String)
    case alreadyDispatched
    case staleHead
    case uncertain

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .alreadyDispatched:
            "This review was already sent or its outcome is uncertain. Check GitHub before preparing a new review."
        case .staleHead:
            "The pull request has changed since these comments were prepared. Recheck the diff and prepare a new review."
        case .uncertain:
            "ASTRA sent the review request but could not confirm the result. Check the pull request on GitHub before trying again."
        }
    }
}

enum GitHubReviewArtifactPolicy {
    static func candidatePath(in paths: [String]) -> String? {
        paths.first { path in
            isReviewFile(path)
        }
    }

    static func isReviewFile(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "github_review.json"
            || name.range(of: #"^pr[0-9]+_review(?:_[a-z0-9-]+)?\.json$"#, options: .regularExpression) != nil
    }
}

protocol GitHubReviewCLI: Sendable {
    func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String
}

struct NativeGitHubReviewCLI: GitHubReviewCLI {
    func run(at repositoryPath: String, arguments: [String], label: String) async throws -> String {
        try await GitService.shared.runGitHubCLI(
            at: repositoryPath,
            arguments: arguments,
            label: label,
            ghPathOverride: nil
        )
    }
}

@MainActor
final class GitHubReviewPublicationService {
    private static let maximumPayloadBytes = 256 * 1024
    private let modelContext: ModelContext
    private let cli: any GitHubReviewCLI

    init(modelContext: ModelContext, cli: any GitHubReviewCLI = NativeGitHubReviewCLI()) {
        self.modelContext = modelContext
        self.cli = cli
    }

    static func hasDispatched(task: AgentTask, filePath: String) -> Bool {
        task.events.contains { event in
            guard event.type == GitHubReviewPublicationEventTypes.dispatched,
                  let data = event.payload.data(using: .utf8),
                  let record = try? JSONDecoder().decode(GitHubReviewPublicationRecord.self, from: data) else {
                return false
            }
            return record.filePath == filePath
        }
    }

    static func hasReceipt(task: AgentTask, run: TaskRun) -> Bool {
        task.events.contains { event in
            event.run?.id == run.id && event.type == GitHubReviewPublicationEventTypes.receipt
        }
    }

    func prepare(task: AgentTask, filePath: String) async throws -> GitHubReviewProposal {
        guard !Self.hasDispatched(task: task, filePath: filePath) else {
            throw GitHubReviewPublicationError.alreadyDispatched
        }
        let (data, payload) = try readPayload(task: task, filePath: filePath)
        let target = try Self.target(from: task.goal)
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent.lowercased()
        let expectedPrefix = "pr\(target.number)_review"
        if fileName != "github_review.json",
           fileName != "\(expectedPrefix).json",
           !(fileName.hasPrefix(expectedPrefix + "_") && fileName.hasSuffix(".json")) {
            throw GitHubReviewPublicationError.invalid("The review filename does not match the pull request in this task’s goal.")
        }
        let metadata = try await pullRequestMetadata(task: task, target: target)
        guard metadata.state.lowercased() == "open" else {
            throw GitHubReviewPublicationError.invalid("The target pull request is no longer open.")
        }
        guard metadata.head.sha.caseInsensitiveCompare(payload.commitId) == .orderedSame else {
            throw GitHubReviewPublicationError.staleHead
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let idSource = "\(target.repository)/\(target.number):\(filePath):\(digest)"
        let id = SHA256.hash(data: Data(idSource.utf8)).map { String(format: "%02x", $0) }.joined()
        return GitHubReviewProposal(
            id: id,
            filePath: filePath,
            digest: digest,
            repository: target.repository,
            pullRequestNumber: target.number,
            pullRequestURL: target.url,
            payload: payload
        )
    }

    /// The dispatch event is durably saved before the network call. If ASTRA
    /// exits or the response is lost, this file cannot be submitted again by a
    /// later click without first checking GitHub and creating a new proposal.
    func publish(task: AgentTask, proposal: GitHubReviewProposal) async throws -> GitHubReviewPublicationRecord {
        guard !Self.hasDispatched(task: task, filePath: proposal.filePath) else {
            throw GitHubReviewPublicationError.alreadyDispatched
        }
        let current = try await prepare(task: task, filePath: proposal.filePath)
        guard current.id == proposal.id, current.digest == proposal.digest else {
            throw GitHubReviewPublicationError.invalid("The review file changed after you opened it. Review the new content before posting.")
        }
        let (data, _) = try readPayload(task: task, filePath: proposal.filePath)
        guard !Self.hasDispatched(task: task, filePath: proposal.filePath) else {
            throw GitHubReviewPublicationError.alreadyDispatched
        }
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-github-review-\(UUID().uuidString).json")
        try data.write(to: inputURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let run = task.runs.max(by: { $0.startedAt < $1.startedAt })
        let dispatched = GitHubReviewPublicationRecord(
            proposalID: proposal.id,
            filePath: proposal.filePath,
            pullRequestURL: proposal.pullRequestURL,
            reviewURL: nil,
            reviewID: nil
        )
        let dispatchEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: GitHubReviewPublicationEventTypes.dispatched,
            payload: dispatched,
            run: run
        )
        modelContext.insert(dispatchEvent)
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "github_review_dispatch", "proposal_id": proposal.id]
            )
        } catch {
            modelContext.delete(dispatchEvent)
            throw error
        }

        do {
            let output = try await cli.run(
                at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
                arguments: ["api", proposal.endpoint, "--method", "POST", "--input", inputURL.path],
                label: "Post reviewed GitHub pull request review"
            )
            let responseDecoder = JSONDecoder()
            responseDecoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try responseDecoder.decode(ReviewResponse.self, from: Data(output.utf8))
            let expectedState = proposal.payload.event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED"
            guard response.id > 0,
                  response.htmlUrl.hasPrefix(proposal.pullRequestURL + "#pullrequestreview-"),
                  response.state == expectedState,
                  response.commitId.caseInsensitiveCompare(proposal.payload.commitId) == .orderedSame,
                  response.submittedAt != nil else {
                throw GitHubReviewPublicationError.uncertain
            }
            let receipt = GitHubReviewPublicationRecord(
                proposalID: proposal.id,
                filePath: proposal.filePath,
                pullRequestURL: proposal.pullRequestURL,
                reviewURL: response.htmlUrl,
                reviewID: response.id
            )
            let completesRequestedReview = GitHubReviewPublicationRequirement.isPending(task: task)
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: GitHubReviewPublicationEventTypes.receipt,
                payload: receipt,
                run: run
            ))
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.info,
                payload: "Posted GitHub review: \(response.htmlUrl)",
                run: run
            ))
            if completesRequestedReview, task.status == .pendingUser, let run {
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Task.approved,
                    payload: "Posted GitHub review: \(response.htmlUrl)",
                    run: run
                ))
                _ = TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
            }
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "github_review_receipt", "review_id": String(response.id)]
            )
            return receipt
        } catch {
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: GitHubReviewPublicationEventTypes.indeterminate,
                payload: dispatched,
                run: run
            ))
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "GitHub review submission could not be confirmed. Check \(proposal.pullRequestURL) before preparing a new review; ASTRA will not resend this file.",
                run: run
            ))
            try? WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "github_review_outcome_indeterminate"]
            )
            throw GitHubReviewPublicationError.uncertain
        }
    }

    private func readPayload(task: AgentTask, filePath: String) throws -> (Data, GitHubReviewPayload) {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let root = URL(fileURLWithPath: taskFolder, isDirectory: true).resolvingSymlinksInPath().path
        let url = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        guard !root.isEmpty, url.path.hasPrefix(root + "/"),
              GitHubReviewArtifactPolicy.isReviewFile(url.path) else {
            throw GitHubReviewPublicationError.invalid("Choose a PR review JSON file from this task’s folder.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int,
              size > 0, size <= Self.maximumPayloadBytes else {
            throw GitHubReviewPublicationError.invalid("The review file must be a regular JSON file under 256 KB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumPayloadBytes else {
            throw GitHubReviewPublicationError.invalid("The review file is too large.")
        }
        try Self.rejectUnreviewedFields(in: data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(GitHubReviewPayload.self, from: data)
        try Self.validate(payload)
        return (data, payload)
    }

    /// The app sends the reviewed file bytes to GitHub. Refuse fields the sheet
    /// does not show, including API options a future GitHub version may add.
    private static func rejectUnreviewedFields(in data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              Set(root.keys).isSubset(of: ["body", "event", "commit_id", "comments"]) else {
            throw GitHubReviewPublicationError.invalid("The review JSON contains fields ASTRA cannot show for approval.")
        }
        if let value = root["comments"] {
            guard let comments = value as? [[String: Any]],
                  comments.allSatisfy({ comment in
                      Set(comment.keys).isSubset(of: [
                          "path", "line", "side", "body", "start_line", "start_side"
                      ])
                  }) else {
                throw GitHubReviewPublicationError.invalid("An inline comment contains fields ASTRA cannot show for approval.")
            }
        }
    }

    private static func validate(_ payload: GitHubReviewPayload) throws {
        let sha = payload.commitId
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit),
              ["COMMENT", "REQUEST_CHANGES"].contains(payload.event),
              payload.body.utf8.count <= 65_536,
              !payload.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.comments.count <= 100 else {
            throw GitHubReviewPublicationError.invalid("The review needs a valid commit, COMMENT or REQUEST_CHANGES event, and review text.")
        }
        for comment in payload.comments {
            let parts = comment.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !comment.path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
                  !parts.contains(""), comment.path.utf8.count <= 1024,
                  comment.line > 0, ["LEFT", "RIGHT"].contains(comment.side),
                  !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  comment.body.utf8.count <= 65_536,
                  (comment.startLine == nil && comment.startSide == nil)
                    || (comment.startLine != nil && comment.startSide != nil && comment.startLine! > 0
                        && ["LEFT", "RIGHT"].contains(comment.startSide!)) else {
                throw GitHubReviewPublicationError.invalid("An inline comment has an invalid path, line, side, or body.")
            }
        }
    }

    private struct Target {
        let repository: String
        let number: Int
        let url: String
    }

    private static func target(from goal: String) throws -> Target {
        let pattern = #"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)(?=$|[\s/#?.,)])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(goal.startIndex..<goal.endIndex, in: goal)
        let matches = regex.matches(in: goal, range: range)
        guard matches.count == 1, let match = matches.first,
              let ownerRange = Range(match.range(at: 1), in: goal),
              let repoRange = Range(match.range(at: 2), in: goal),
              let numberRange = Range(match.range(at: 3), in: goal),
              let number = Int(goal[numberRange]),
              goal[repoRange] != ".", goal[repoRange] != ".." else {
            throw GitHubReviewPublicationError.invalid("The task goal must contain exactly one target GitHub pull request URL.")
        }
        let repository = "\(goal[ownerRange])/\(goal[repoRange])"
        return Target(repository: repository, number: number,
                      url: "https://github.com/\(repository)/pull/\(number)")
    }

    private struct PullRequestMetadata: Decodable {
        struct Head: Decodable { let sha: String }
        let state: String
        let head: Head
    }

    private struct ReviewResponse: Decodable {
        let id: Int
        let htmlUrl: String
        let state: String
        let commitId: String
        let submittedAt: String?
    }

    private func pullRequestMetadata(task: AgentTask, target: Target) async throws -> PullRequestMetadata {
        let output = try await cli.run(
            at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
            arguments: ["api", "repos/\(target.repository)/pulls/\(target.number)", "--method", "GET"],
            label: "Check GitHub pull request review target"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PullRequestMetadata.self, from: Data(output.utf8))
    }
}
