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
    /// The request this one extends, so earlier receipts of the same chain still count.
    var chainID: String? = nil
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
    /// The first request of the chain of additive follow-ups the dispatched request belongs
    /// to. A later batch can only be judged settled with the receipts of the whole chain.
    var chainID: String? = nil
    /// The operations the approved payload required ("thread:reply", "thread:resolve"). The
    /// recovery mirror compacts old dispatches to this summary in place of the payload.
    var requiredActions: [String]? = nil
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

    /// A proposal's identity within its task folder, so evidence recorded under one
    /// absolute path still matches after the workspace was moved or renamed.
    static func identity(of path: String) -> String {
        guard let range = path.range(of: "/tasks/", options: .backwards) else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let afterTasks = path[range.upperBound...]
        guard let slash = afterTasks.firstIndex(of: "/") else { return String(afterTasks) }
        return String(afterTasks[afterTasks.index(after: slash)...])
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
        /// What the request asked ASTRA to do: "reply", "resolve", or both. A receipt only
        /// settles the request if it covers these.
        var operations: Set<String> = []
        /// The first request of the additive chain this belongs to. Receipts of any request
        /// of the chain count toward it.
        var chainID: String? = nil
        var chain: String { chainID ?? id }
        /// Messages that added an operation the request did not have. Bounding the chain
        /// never drops them: without one, a recovered request would ask for less.
        var operationEventIDs: [UUID] = []
        var targetText: String { targetSource ?? text }
    }

    static func request(task: AgentTask) -> Request? {
        let userMessages = task.events.filter {
            $0.type == TaskEventTypes.Conversation.userMessage.rawValue || $0.type == TaskPlanConversationEventTypes.userMessage
        }
        var current = intentDetail(task.goal).flatMap { detail in
            detail.publish
                ? Request(id: "goal:" + GitHubReviewThreadArtifactPolicy.digest(Data(task.goal.utf8)), text: task.goal,
                          operations: detail.operations)
                : nil
        }
        let messages = userMessages.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
        for message in messages {
            if let detail = intentDetail(message.payload, allowPronoun: current != nil) {
                // "also resolve them" adds to what was asked; any other message restates it.
                let wording = current != nil && message.payload.range(
                    of: #"(?i)\b(?:also|too|as well|in addition|additionally|plus|and then)\b"#, options: .regularExpression) != nil
                let carried = carriedTarget(message.payload, prior: current)
                // An addition about another pull request is a request of its own.
                let namesOtherPullRequest = current != nil
                    && namesAnotherPullRequest(task: task, text: carried ?? message.payload, prior: current)
                let additive = wording && !namesOtherPullRequest
                // A message that names its own pull request restarts the chain. One that
                // leans on an earlier message for the target keeps that message, the first
                // of the chain, and the newest few, within a fixed bound.
                let leans = additive || (carried != nil && current != nil)
                let operations = detail.operations.union(additive ? current?.operations ?? [] : [])
                let pinned = leans
                    ? (current?.operationEventIDs ?? []) + (operations.isSubset(of: current?.operations ?? []) ? [] : [message.id])
                    : []
                let chain = leans ? boundedChain((current?.sourceEventIDs ?? []) + [message.id], pinned: pinned) : [message.id]
                current = detail.publish
                    ? Request(id: message.id.uuidString, text: message.payload,
                              targetSource: carried,
                              sourceEventIDs: chain,
                              operations: operations,
                              chainID: additive ? current?.chain : nil,
                              operationEventIDs: pinned)
                    : (namesOtherPullRequest ? current : withoutRefused(current, detail.refused))
            } else if current != nil,
                      message.payload.range(
                        of: #"(?i)\b(?:cancel|stop|skip|drop|forget|do not send|don't send)\s+(?:it|that|them|this)\b|\bnever\s?mind\b|\b(?:do not|don't|dont|never|stop|cancel|skip)\s+(?:replying|reply|resolving|resolve|posting|post|sending|send)\b(?:\s+to)?\s+(?:it|that|them|this|those|these)\b"#,
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

    private static let maxChainMessages = 20

    /// The root message of a chain, which names the pull request, and its newest messages.
    /// Messages that added an operation stay, so the bound never weakens the request.
    private static func boundedChain(_ ids: [UUID], pinned: [UUID]) -> [UUID] {
        guard ids.count > maxChainMessages, let root = ids.first else { return ids }
        let keep = Set([root] + pinned + ids.suffix(max(1, maxChainMessages - 1 - pinned.count)))
        return ids.filter(keep.contains)
    }


    /// The request after a follow-up refused some of its operations: it stays for the ones left
    /// and ends when none are.
    private static func withoutRefused(_ request: Request?, _ refused: Set<String>) -> Request? {
        guard var request else { return nil }
        request.operations.subtract(refused)
        return request.operations.isEmpty ? nil : request
    }

    /// Whether a message targets a different pull request than the request it would extend.
    private static func namesAnotherPullRequest(task: AgentTask, text: String, prior: Request?) -> Bool {
        guard let prior else { return false }
        let earlierTarget = GitHubReviewTargetResolver.durableTarget(task: task, request: prior.targetText)
        let laterTarget = GitHubReviewTargetResolver.durableTarget(task: task, request: text)
        if let earlier = earlierTarget, let later = laterTarget {
            return earlier.repository.lowercased() != later.repository.lowercased() || earlier.number != later.number
        }
        // Only one side names its repository: an equal number does not make them the same
        // pull request.
        if (earlierTarget == nil) != (laterTarget == nil) { return true }
        // One side lacks a repository ("PR 12" against a full URL, or two shorthands): the
        // numbers alone tell them apart, whichever form carries them.
        func number(_ text: String) -> Int? {
            GitHubReviewTargetResolver.pullRequest(in: text)?.number ?? GitHubReviewTargetResolver.shorthandNumber(in: text)
        }
        guard let earlier = number(prior.targetText), let later = number(text) else { return false }
        return earlier != later
    }

    static func isPending(task: AgentTask) -> Bool {
        guard let request = request(task: task) else { return false }
        func records(_ types: [String]) -> [GitHubReviewThreadReceipt] {
            task.events.compactMap { event in
                guard types.contains(event.type), let data = event.payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(GitHubReviewThreadReceipt.self, from: data)
            }
        }
        func covers(_ actions: [GitHubReviewThreadReceipt.Action]) -> Bool {
            !actions.isEmpty && request.operations.isSubset(of: Set(actions.map(\.operation)))
        }
        // Every receipt of the chain counts, however many follow-ups it has grown by.
        func inChain(_ record: GitHubReviewThreadReceipt) -> Bool { (record.chainID ?? record.requestID) == request.chain }
        let finalActions = records([GitHubReviewThreadEvents.receipt, GitHubReviewThreadEvents.receiptRecovery])
            .filter(inChain).flatMap(\.actions)
        if covers(finalActions) { return false }
        // ASTRA can stop after the last confirmed operation but before it writes the
        // final batch receipt. Every operation of the approved payload is then already
        // durably confirmed, and there is nothing left to propose or send.
        let confirmed = records([GitHubReviewThreadEvents.actionReceipt])
        return !records([GitHubReviewThreadEvents.dispatched]).contains { dispatch in
            guard inChain(dispatch) else { return false }
            // Across the chain: a reply confirmed by a batch that failed before resolving, and a
            // resolution-only batch sent to finish it, are one request completed.
            let confirmedActions = confirmed.filter(inChain).flatMap(\.actions)
            guard covers(finalActions + confirmedActions) else { return false }
            let done = Set(confirmedActions.map { "\($0.threadID):\($0.operation)" })
            // The approved payload, or the summary a compacted dispatch keeps in its place.
            let required: [String]
            if let payload = dispatch.approvedPayload {
                required = payload.threads.flatMap { thread in
                    (thread.reply != nil ? ["\(thread.threadId):reply"] : []) + (thread.resolve ? ["\(thread.threadId):resolve"] : [])
                }
            } else if let summary = dispatch.requiredActions {
                required = summary
            } else { return false }
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
        #"(?:\s+\S+){0,3}?\s+(?:on|in|for|of|from|to)\s+(?:the\s+|this\s+|that\s+|my\s+|our\s+)?(?:https?://github\.com/\S+/pull/\d+|(?:GitHub\s+)?PR\s*#?\d+|(?:GitHub\s+)?pull request\b|(?:GitHub\s+)?PR\b|GitHub\b)"#

    /// The pull request named before the noun: "the PR #12 review comments".
    private static let pullRequestHead =
        #"(?:https?://github\.com/\S+/pull/\d+|\bPR\b\s*#?\d*|pull request(?:'s)?\s*#?\d*|\bGitHub\b(?:\s+PR)?)(?:\s+\S+){0,2}?\s+"#

    /// The verbs of the operation that made this a request, with negated ones already removed.
    private static func requestedOperations(_ operation: String) -> Set<String> {
        var operations: Set<String> = []
        if operation.range(of: #"(?i)\b(?:reply|replying|replies)\b"#, options: .regularExpression) != nil { operations.insert("reply") }
        if operation.range(of: #"(?i)\b(?:resolve|reslolve|resolving|resolved)\b"#, options: .regularExpression) != nil { operations.insert("resolve") }
        return operations
    }

    /// `refused` are the operations the message refuses, so a follow-up that refuses one operation
    /// of an active request can take it out of the request instead of cancelling the whole.
    private static func intentDetail(_ rawText: String, allowPronoun: Bool = false) -> (publish: Bool, operations: Set<String>, refused: Set<String>)? {
        // "then" ends a clause as a comma does: "Reply to the Slack thread, then
        // inspect GitHub PR #12" is two jobs.
        let text = rawText.replacingOccurrences(of: #"(?i)\bthen\b"#, with: ",", options: .regularExpression)
        let object = "(?:" + threadNoun + "|" + bareNoun + (allowPronoun ? "" : pullRequestTail) + "|" + pullRequestHead + bareNoun + ")"
        var pattern = #"(?i)\b(?:resolve|reslolve|resolving|reply|replying|replies)\b(?:\s+\S+){0,6}?\s+\b"# + object
            + #"|\bmark\b(?:\s+\S+){0,4}?\s+\b(?:"# + threadNoun + "|" + bareNoun + #")(?:\s+\S+){0,7}?\s+\bresolved\b"#
        let qualifyingObject = #"(?i)\b(?:"# + threadNoun + "|" + bareNoun + pullRequestTail + "|" + pullRequestHead + bareNoun + ")"
        if allowPronoun || text.range(of: qualifyingObject, options: .regularExpression) != nil {
            pattern += #"|\b(?:resolve|reslolve|reply|replying)\s+(?:to\s+)?(?:them|those|these)\b"#
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
        let services = "slack|jira|e-?mail|teams|discord|linear|notion|confluence|asana|trello|zendesk|intercom|whatsapp|sms|chat"
        let otherService = #"(?i)\b(?:"# + services + #")\b"#
        // "with the answer from Slack" names where the content comes from, not where it goes.
        let serviceAsSource = #"(?i)\b(?:from|using|based on|according to)\b(?:\s+(?:the|a|an|our|my))?\s+(?:"# + services + #")\b"#
        // "On PR #12, reply to the threads": a leading qualifier names the pull request
        // for the sentence that follows its comma or colon.
        let leadingQualifier = #"(?i)^\s*(?:on|in|for|regarding|about|re)\s+(?:the\s+)?(?:(?:(?:GitHub\s+)?(?:PR|pull request)\b[^,:;!?\n]*)|https?://github\.com/\S+)\s*[,:]\s*(?:please\s+)?$"#
        // Threads of a program, not of a review.
        let softwareThread = #"(?i)\b(?:worker|main|background|ui|gcd|cpu|jvm|java|python|pool|concurrent|dispatch)\s+threads?\b|\b(?:race condition|race|deadlock|mutex|semaphore)\b"#
        let operations = matches.compactMap { candidate -> (named: Bool, negated: Bool, elsewhere: Bool, continuation: Bool, text: String)? in
            guard let span = Range(candidate.range, in: text) else { return nil }
            let head = String(text[..<span.lowerBound])
            let headStart = boundaries?.matches(in: head, range: NSRange(head.startIndex..<head.endIndex, in: head))
                .last.flatMap { Range($0.range, in: head)?.upperBound } ?? head.startIndex
            let tail = String(text[span.upperBound...])
            let tailEnd = tail.range(of: boundary, options: .regularExpression)?.lowerBound ?? tail.endIndex
            let lead = head[headStart...].split(whereSeparator: \.isWhitespace).suffix(4).joined(separator: " ")
            // A negation in front of a later verb ("reply but do not resolve ...") belongs to
            // that verb, not to the operation that began with the first one.
            let operationText = String(text[span]).replacingOccurrences(
                of: #"(?i)\b(?:do not|don't|dont|never|not)\s+(?:resolve|reslolve|resolving|reply|replying|replies)\b"#,
                with: "", options: .regularExpression)
            let phrase = (lead + " " + operationText).lowercased()
            let clause = String(head[headStart...] + text[span] + tail[..<tailEnd])
            // What a follow-up needs to count without naming GitHub: "resolve them", an
            // explicit thread or conversation, or the resolve verb itself, which is
            // GitHub thread work. A bare "reply with your comments here" is not.
            let operation = String(text[span])
            let negated = phrase.range(of: negation, options: .regularExpression) != nil
            // A refusal of "them" counts once a request is active or the message makes one,
            // whatever the verb; an unrefused "reply to them" is too ambiguous to be one.
            let continuation = operation.range(of: #"(?i)^\s*(?:resolve|reslolve)\s+(?:them|those|these)\b"#, options: .regularExpression) != nil
                || (negated && operation.range(of: #"(?i)^\s*(?:reply|replying)\s+(?:to\s+)?(?:them|those|these)\b"#, options: .regularExpression) != nil)
                || operation.range(of: #"(?i)\b(?:threads?|conversations?)\b"#, options: .regularExpression) != nil
                || operation.range(of: #"(?i)^\s*(?:resolve|reslolve|resolving|mark)\b"#, options: .regularExpression) != nil
            let sentenceStart = head.range(of: #"[!?;\n]|\.(?=\s)"#, options: [.regularExpression, .backwards])?.upperBound ?? head.startIndex
            let qualified = head[sentenceStart...].range(of: leadingQualifier, options: .regularExpression) != nil
            return (named: qualified || clause.range(of: context, options: .regularExpression) != nil,
                    negated: negated,
                    elsewhere: operation.range(of: softwareThread, options: .regularExpression) != nil
                        || clause.replacingOccurrences(of: serviceAsSource, with: "", options: .regularExpression)
                            .range(of: otherService, options: .regularExpression) != nil,
                    continuation: continuation, text: operationText)
        }
        // Every operation of the message counts, not only the last: "reply ..., and resolve ..."
        // asks for both, and "reply ..., but do not resolve ..." asks for the reply alone. What
        // is left after the refused operations is the request; nothing left is a cancellation.
        // A pronoun in a message that also names GitHub thread work ("... on PR 12, but don't
        // reply to them") refers to that work, as it does after an active request.
        let anchored = operations.contains { !$0.elsewhere && $0.named }
        let qualifying = operations.filter { !$0.elsewhere && ($0.named || ((allowPronoun || anchored) && $0.continuation)) }
        guard !qualifying.isEmpty else { return nil }
        // The last mention of a verb on the same object decides it, so a plain change of mind
        // ("resolve them. Do not resolve them.") cancels it, while refusing it for one thread
        // ("resolve the first thread, but do not resolve the second") leaves it for the other,
        // whichever comes first.
        var refusedAtLastMention: [String: [String: Bool]] = [:]
        for operation in qualifying {
            let object = operation.text.lowercased()
                .replacingOccurrences(of: #"\b(?:resolve|reslolve|resolving|resolved|reply|replying|replies)\b"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let isPronoun = object.range(of: #"^(?:to\s+)?(?:them|those|these)$"#, options: .regularExpression) != nil
            for verb in requestedOperations(operation.text) {
                // "... but don't reply to them" refers to everything asked for so far.
                if operation.negated && isPronoun {
                    for known in refusedAtLastMention[verb]?.keys ?? [:].keys { refusedAtLastMention[verb]?[known] = true }
                }
                refusedAtLastMention[verb, default: [:]][object] = operation.negated
            }
        }
        let remaining = Set(refusedAtLastMention.filter { $0.value.values.contains(false) }.keys)
        let refused = Set(refusedAtLastMention.filter { !$0.value.values.contains(false) }.keys)
        return (!remaining.isEmpty, remaining, refused)
    }
}
