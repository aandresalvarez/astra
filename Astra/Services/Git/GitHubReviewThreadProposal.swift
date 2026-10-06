import CryptoKit
import Foundation
import ASTRAModels
import HostControlToolSupport

struct GitHubReviewThreadPayload: Codable {
    struct Action: Codable {
        let threadId: String
        let expectedLastCommentId: String
        let reply: String?
        let resolve: Bool
    }
    let pullRequestUrl: String
    let commitId: String
    let threads: [Action]
}

struct GitHubReviewThreadSnapshot: Codable {
    struct PullRequest: Codable { let url: String; let headRefOid: String; let state: String }
    struct Comment: Codable {
        struct Author: Codable { let login: String }
        let id: String
        let body: String
        let url: String
        let author: Author?
    }
    let id: String
    let path: String
    let line: Int?
    let isResolved: Bool
    let viewerCanResolve: Bool
    let pullRequest: PullRequest
    var comments: [Comment]
}

struct GitHubReviewThreadProposal: Identifiable {
    let id: String
    let filePath: String
    let digest: String
    let requestID: String?
    let payload: GitHubReviewThreadPayload
    let snapshots: [GitHubReviewThreadSnapshot]
}

struct GitHubReviewThreadReceipt: Codable {
    struct Action: Codable {
        let threadID: String
        let operation: String
        let commentID: String?
        let url: String?
    }
    let proposalID: String
    let filePath: String
    let requestID: String?
    let pullRequestURL: String
    let actions: [Action]
    var approvedPayload: GitHubReviewThreadPayload? = nil
}

/// A thread proposal ASTRA found unusable (stale head, resolved or edited thread,
/// foreign target, invalid file). It is not offered again; the agent prepares a
/// corrected proposal under a new versioned filename.
struct GitHubReviewThreadDismissal: Codable {
    let filePath: String
    let reason: String
}

enum GitHubReviewThreadEvents {
    static let dispatched = "github.review-threads.dispatched"
    static let actionReceipt = "github.review-threads.action-receipt"
    static let receipt = "github.review-threads.receipt"
    static let receiptRecovery = "github.review-threads.receipt-recovery"
    static let indeterminate = "github.review-threads.indeterminate"
    static let dismissed = "github.review-threads.dismissed"
}

enum GitHubReviewThreadArtifactPolicy {
    static func isProposalFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.range(
            of: #"^pr[1-9][0-9]*_threads(?:_[a-z0-9-]+)?\.json$"#, options: .regularExpression
        ) != nil
    }

    static func target(_ url: String) -> (repository: String, number: Int)? {
        guard let parts = URLComponents(string: url), parts.scheme == "https", parts.host == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[3] == "pull",
              let number = Int(path[4]), number > 0, String(number) == path[4] else { return nil }
        let repository = "\(path[1])/\(path[2])"
        return GitHubReviewThreadReadOperation.isRepository(repository) ? (repository, number) : nil
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A request remains pending until ASTRA has receipts for the approved batch.
/// Unrelated follow-ups retain the request; cancellation clears it.
enum GitHubReviewThreadRequirement {
    struct Request { let id: String; let text: String }

    static func request(task: AgentTask) -> Request? {
        let userMessages = task.events.filter {
            $0.type == TaskEventTypes.Conversation.userMessage.rawValue || $0.type == TaskPlanConversationEventTypes.userMessage
        }
        let context = ([task.goal] + userMessages.map(\.payload)).joined(separator: "\n")
        guard context.range(of: #"(?i)github\.com/|\bgithub\b|\bPR\b|\bpull request\b"#, options: .regularExpression) != nil else { return nil }
        var current = intent(task.goal) == true ? Request(id: "goal:" + GitHubReviewThreadArtifactPolicy.digest(Data(task.goal.utf8)), text: task.goal) : nil
        let messages = userMessages.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
        for message in messages {
            if let publish = intent(message.payload, allowPronoun: current != nil) {
                current = publish ? Request(id: message.id.uuidString, text: message.payload) : nil
            } else if current != nil,
                      message.payload.range(
                        of: #"(?i)\b(?:cancel|stop|skip|drop|forget|do not send|don't send)\s+(?:it|that|them|this)\b|\bnever\s?mind\b"#,
                        options: .regularExpression
                      ) != nil {
                current = nil
            }
        }
        return current
    }

    static func isPending(task: AgentTask) -> Bool {
        guard let request = request(task: task) else { return false }
        return !task.events.contains { event in
            guard [GitHubReviewThreadEvents.receipt, GitHubReviewThreadEvents.receiptRecovery].contains(event.type),
                  let data = event.payload.data(using: .utf8),
                  let receipt = try? JSONDecoder().decode(GitHubReviewThreadReceipt.self, from: data) else { return false }
            return receipt.requestID == request.id && !receipt.actions.isEmpty
        }
    }

    /// What the user is asking for decides whether a task is held until ASTRA
    /// publishes, so a false positive traps an unrelated task and a miss only
    /// costs enforcement (a proposal file is still offered for approval). The
    /// patterns therefore err toward missing.
    ///
    /// - A thread noun ("threads", "conversations", "review comments") is enough.
    /// - Any "comments", "review comments" or "reviews" counts only when a pull request follows
    ///   it ("comments on PR 12"), or when a request is already active and the
    ///   message is a follow-up ("do not resolve the comments").
    private static let threadNoun = #"(?:threads?|conversations?)\b"#
    private static let bareNoun = #"(?:(?:(?:review|reviewer|inline)\s+)?comm?ents?|reviews?)\b"#
    private static let pullRequestTail =
        #"(?:\s+\S+){0,3}?\s+(?:on|in|for|of|from|to)\s+(?:the\s+|this\s+|that\s+|my\s+|our\s+)?(?:https?://github\.com/\S+/pull/\d+|PR\s*#?\d+|pull request\b|PR\b)"#

    private static func intent(_ text: String, allowPronoun: Bool = false) -> Bool? {
        let object = "(?:" + threadNoun + "|" + bareNoun + (allowPronoun ? "" : pullRequestTail) + ")"
        var pattern = #"(?i)\b(?:resolve|reslolve|resolving|reply|replying)\b(?:\s+\S+){0,6}?\s+\b"# + object
            + #"|\bmark\b(?:\s+\S+){0,4}?\s+\b(?:"# + threadNoun + "|" + bareNoun + #")(?:\s+\S+){0,7}?\s+\bresolved\b"#
        let qualifyingObject = #"(?i)\b(?:"# + threadNoun + "|" + bareNoun + pullRequestTail + ")"
        if allowPronoun || text.range(of: qualifyingObject, options: .regularExpression) != nil {
            pattern += #"|\b(?:resolve|reslolve)\s+(?:them|those|these)\b"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).last,
              let range = Range(match.range, in: text) else { return nil }
        let clause = String(text[..<range.lowerBound].suffix(64))
            .components(separatedBy: CharacterSet(charactersIn: ".!?;\n")).last ?? ""
        let lead = clause.split(whereSeparator: \.isWhitespace).suffix(4).joined(separator: " ")
        let phrase = (lead + " " + text[range]).lowercased()
        return phrase.range(of: #"\b(?:do not|don't|dont|never|without|not|no)\b"#, options: .regularExpression) == nil
    }
}
