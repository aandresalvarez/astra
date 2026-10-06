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
    let viewerCanReply: Bool
    let pullRequest: PullRequest
    var comments: [Comment]
}

struct GitHubReviewThreadProposal: Identifiable {
    let id: String
    let filePath: String
    let digest: String
    let requestID: String?
    /// The user messages that built the request, oldest first, recorded with the dispatch.
    let requestEventIDs: [String]
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
    var requestEventIDs: [String]? = nil
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
    /// `targetSource` is the text that names the pull request. A follow-up such as
    /// "resolve them" renews the request without repeating it, so it keeps the
    /// target of the request it continues.
    struct Request {
        let id: String
        let text: String
        var targetSource: String?
        /// The messages that built this request, so recovery can rebuild a continuation.
        var sourceEventIDs: [UUID] = []
        var targetText: String { targetSource ?? text }
    }

    static func request(task: AgentTask) -> Request? {
        let userMessages = task.events.filter {
            $0.type == TaskEventTypes.Conversation.userMessage.rawValue || $0.type == TaskPlanConversationEventTypes.userMessage
        }
        var current = intent(task.goal) == true ? Request(id: "goal:" + GitHubReviewThreadArtifactPolicy.digest(Data(task.goal.utf8)), text: task.goal) : nil
        let messages = userMessages.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
        for message in messages {
            if let publish = intent(message.payload, allowPronoun: current != nil) {
                current = publish
                    ? Request(id: message.id.uuidString, text: message.payload,
                              targetSource: carriedTarget(message.payload, prior: current),
                              sourceEventIDs: (current?.sourceEventIDs ?? []) + [message.id])
                    : nil
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

    /// The text that names the pull request for a renewed request. A message with
    /// its own full URL names it; one with no target keeps the earlier one; one
    /// with only a PR number keeps the earlier owner and repository.
    private static func carriedTarget(_ payload: String, prior: Request?) -> String? {
        if payload.range(of: "github.com/", options: .caseInsensitive) != nil { return nil }
        guard let prior else { return nil }
        guard GitHubReviewTargetResolver.shorthandNumber(in: payload) != nil else { return prior.targetText }
        guard let repository = GitHubReviewTargetResolver.repository(in: prior.targetText) else { return nil }
        return "https://github.com/\(repository) " + payload
    }

    static func isPending(task: AgentTask) -> Bool {
        guard let request = request(task: task) else { return false }
        func records(_ types: [String]) -> [GitHubReviewThreadReceipt] {
            task.events.compactMap { event in
                guard types.contains(event.type), let data = event.payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(GitHubReviewThreadReceipt.self, from: data)
            }
        }
        if records([GitHubReviewThreadEvents.receipt, GitHubReviewThreadEvents.receiptRecovery])
            .contains(where: { $0.requestID == request.id && !$0.actions.isEmpty }) { return false }
        // ASTRA can stop after the last confirmed operation but before it writes the
        // final batch receipt. Every operation of the approved payload is then already
        // durably confirmed, and there is nothing left to propose or send.
        let confirmed = records([GitHubReviewThreadEvents.actionReceipt])
        return !records([GitHubReviewThreadEvents.dispatched]).contains { dispatch in
            guard dispatch.requestID == request.id, let payload = dispatch.approvedPayload else { return false }
            let done = Set(confirmed.filter { $0.proposalID == dispatch.proposalID }
                .flatMap(\.actions).map { "\($0.threadID):\($0.operation)" })
            let required = payload.threads.flatMap { thread in
                (thread.reply != nil ? ["\(thread.threadId):reply"] : []) + (thread.resolve ? ["\(thread.threadId):resolve"] : [])
            }
            return !required.isEmpty && required.allSatisfy(done.contains)
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

    private static func intent(_ rawText: String, allowPronoun: Bool = false) -> Bool? {
        // "then" ends a clause as a comma does: "Reply to the Slack thread, then
        // inspect GitHub PR #12" is two jobs.
        let text = rawText.replacingOccurrences(of: #"(?i)\bthen\b"#, with: ",", options: .regularExpression)
        let object = "(?:" + threadNoun + "|" + bareNoun + (allowPronoun ? "" : pullRequestTail) + ")"
        var pattern = #"(?i)\b(?:resolve|reslolve|resolving|reply|replying|replies)\b(?:\s+\S+){0,6}?\s+\b"# + object
            + #"|\bmark\b(?:\s+\S+){0,4}?\s+\b(?:"# + threadNoun + "|" + bareNoun + #")(?:\s+\S+){0,7}?\s+\bresolved\b"#
        let qualifyingObject = #"(?i)\b(?:"# + threadNoun + "|" + bareNoun + pullRequestTail + ")"
        if allowPronoun || text.range(of: qualifyingObject, options: .regularExpression) != nil {
            pattern += #"|\b(?:resolve|reslolve)\s+(?:them|those|these)\b"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        // Each match is one operation. Its GitHub context and its negation are read
        // from the same clause around it, so a prohibition on one job never decides
        // another and a mention of GitHub elsewhere never qualifies it. A job ends at
        // punctuation or a conjunction ("Reply to the Slack thread and inspect GitHub
        // PR #12" asks nothing of GitHub threads). An active request already
        // established the context for its follow-ups.
        let boundary = #"(?i)[.!?;,\n]|\b(?:and|but|also|plus)\b"#
        let context = #"(?i)github\.com/|\bgithub\b|\bPR\b|\bpull request\b"#
        let negation = #"\b(?:do not|don't|dont|never|without|not|no|stop|cancel|skip|abort)\b"#
        let boundaries = try? NSRegularExpression(pattern: boundary)
        // Thread work that names another service ("Reply to the Slack thread") is not
        // GitHub work, whatever else the task mentions, so it never renews a request.
        let otherService = #"(?i)\b(?:slack|jira|e-?mail|teams|discord|linear|notion|confluence|asana|trello|zendesk|intercom|whatsapp|sms|chat)\b"#
        let operations = matches.compactMap { candidate -> (named: Bool, negated: Bool, elsewhere: Bool, continuation: Bool)? in
            guard let span = Range(candidate.range, in: text) else { return nil }
            let head = String(text[..<span.lowerBound])
            let headStart = boundaries?.matches(in: head, range: NSRange(head.startIndex..<head.endIndex, in: head))
                .last.flatMap { Range($0.range, in: head)?.upperBound } ?? head.startIndex
            let tail = String(text[span.upperBound...])
            let tailEnd = tail.range(of: boundary, options: .regularExpression)?.lowerBound ?? tail.endIndex
            let lead = head[headStart...].split(whereSeparator: \.isWhitespace).suffix(4).joined(separator: " ")
            let phrase = (lead + " " + text[span]).lowercased()
            let clause = String(head[headStart...] + text[span] + tail[..<tailEnd])
            // What a follow-up needs to count without naming GitHub: "resolve them", an
            // explicit thread or conversation, or the resolve verb itself, which is
            // GitHub thread work. A bare "reply with your comments here" is not.
            let operation = String(text[span])
            let continuation = operation.range(of: #"(?i)^\s*(?:resolve|reslolve)\s+(?:them|those|these)\b"#, options: .regularExpression) != nil
                || operation.range(of: #"(?i)\b(?:threads?|conversations?)\b"#, options: .regularExpression) != nil
                || operation.range(of: #"(?i)^\s*(?:resolve|reslolve|resolving|mark)\b"#, options: .regularExpression) != nil
            return (named: clause.range(of: context, options: .regularExpression) != nil,
                    negated: phrase.range(of: negation, options: .regularExpression) != nil,
                    elsewhere: clause.range(of: otherService, options: .regularExpression) != nil,
                    continuation: continuation)
        }
        guard let operation = operations.last(where: { !$0.elsewhere && ($0.named || (allowPronoun && $0.continuation)) }) else { return nil }
        return !operation.negated
    }
}
