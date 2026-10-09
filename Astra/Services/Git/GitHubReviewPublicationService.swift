import CryptoKit
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

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
    let validatedData: Data

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
    /// Who let ASTRA post it. Absent on receipts written before levels were
    /// harmonized, every one of which the user reviewed in the sheet.
    var authorization: ExternalActionAuthorization? = nil
}

private struct GitHubReviewUnusableArtifactRecord: Codable {
    let filePath: String
    let reason: String
}

private struct GitHubReviewBoundTargetRecord: Codable {
    let requestEventID: UUID?
    let requestDigest: String
    let repository: String
    let number: Int
}

private struct GitHubReviewUnresolvedTargetRecord: Codable {
    let requestEventID: UUID?
    let requestDigest: String
    let reason: String
}

enum GitHubReviewPublicationEventTypes {
    static let dispatched = "github.review.dispatched"
    static let receipt = "github.review.receipt"
    static let indeterminate = "github.review.indeterminate"
    static let unusable = "github.review.unusable"
    static let targetBound = "github.review.target-bound"
    static let targetUnresolved = "github.review.target-unresolved"
    static let receiptRecovery = "github.review.receipt-recovery"
}

private enum GitHubReviewTargetResolver {
    struct Target {
        let repository: String
        let number: Int
        var url: String { "https://github.com/\(repository)/pull/\(number)" }
    }

    private static let pullRequestPattern = #"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)(?![A-Za-z0-9])"#
    private static let repositoryPattern = #"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)(?=/|[)\s>]|$)"#
    private static let shorthandPattern = #"\b(?:PR|pull request)\s*#?([1-9][0-9]*)\b"#
    private static let filePattern = #"^pr([1-9][0-9]*)_review(?:_[a-z0-9-]+)?\.json$"#

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    static func pullRequest(in text: String) -> Target? {
        let found = matches(pullRequestPattern, in: text)
        guard found.count == 1, let match = found.first,
              let numberRange = Range(match.range(at: 3), in: text),
              let number = Int(text[numberRange]),
              let repository = repository(from: match, in: text) else { return nil }
        return Target(repository: repository, number: number)
    }

    static func repository(in text: String) -> String? {
        let found = matches(repositoryPattern, in: text)
        guard found.count == 1, let match = found.first else { return nil }
        return repository(from: match, in: text)
    }

    private static func repository(from match: NSTextCheckingResult, in text: String) -> String? {
        guard let ownerRange = Range(match.range(at: 1), in: text),
              let repoRange = Range(match.range(at: 2), in: text) else { return nil }
        let rawRepository = String(text[repoRange])
        let repository = rawRepository.lowercased().hasSuffix(".git")
            ? String(rawRepository.dropLast(4)) : rawRepository
        guard repository != ".", repository != "..", !repository.isEmpty else { return nil }
        return "\(text[ownerRange])/\(repository)"
    }

    static func shorthandNumber(in text: String) -> Int? {
        let found = matches(shorthandPattern, in: text)
        guard found.count == 1, let numberRange = Range(found[0].range(at: 1), in: text) else { return nil }
        return Int(text[numberRange])
    }

    static func fileNumber(in path: String) -> Int? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let found = matches(filePattern, in: name)
        guard found.count == 1, let numberRange = Range(found[0].range(at: 1), in: name) else { return nil }
        return Int(name[numberRange])
    }

    static func durableTarget(task: AgentTask, request: String?) -> Target? {
        if let request, request.range(of: "github.com/", options: .caseInsensitive) != nil {
            if let target = pullRequest(in: request) { return target }
            if let number = shorthandNumber(in: request),
               let repository = repository(in: request) {
                return Target(repository: repository, number: number)
            }
            return nil
        }
        if let request, let number = shorthandNumber(in: request),
           let repository = repository(in: task.goal) {
            return Target(repository: repository, number: number)
        }
        return pullRequest(in: task.goal)
    }
}

/// Durable user messages can request or cancel publication. Unrelated later
/// messages do not erase an unresolved posting request.
enum GitHubReviewPublicationRequirement {
    private static let publicationRegex = try? NSRegularExpression(
        pattern: #"\b(?:post|posting|publish|publishing|submit|submitting|add|adding|send|sending|leave|leaving)\b(?:\s+\S+){0,4}?\s+\b(?:comments?|review)\b"#
    )
    /// What Auto takes as consent to post without the sheet: a command, in
    /// so many words. The broad pattern above is right for offering the Post
    /// review sheet, where the user still decides; read as consent it let
    /// "add review comments to the file", "ask me before posting the review"
    /// and "hold off on posting the review" through, one phrasing per review
    /// round. So this is a positive list rather than a list of negations: the
    /// base verb post, publish or submit, before the review or its comments,
    /// with nothing ahead of it in its clause but words that keep it a
    /// command. Being wrong costs a review left for the sheet, never a post.
    private static let imperativePublicationRegex = try? NSRegularExpression(
        pattern: #"\b(?:post|publish|submit)\b(?:\s+\S+){0,4}?\s+\b(?:comments?|review)\b"#
    )
    private static let imperativeLeadWords: Set<String> = [
        "please", "and", "then", "also", "now", "so", "ok", "okay", "go", "ahead", "kindly", "just",
        "finally", "lastly", "next", "can", "could", "would", "will", "you", "yes", "sure", "alright"
    ]
    /// A condition after the command ("post the review once I approve") or a
    /// pause anywhere in the message ("…, but ask me first") makes it not yet
    /// a command to post now.
    private static let deferringRegex = try? NSRegularExpression(
        pattern: #"\b(?:after|once|when|whenever|until|till|if|unless|before|only|later|tomorrow)\b"#
    )
    private static let pausingRegex = try? NSRegularExpression(
        pattern: #"\b(?:ask me|check with me|let me|wait|hold|don't|do not|dont|never|not yet|first|approve|approval|confirm|draft|prepare|i will|i'll|i am going to|i'm going to|we will|we'll|myself|ourselves)\b"#
    )
    /// A message that closes an open request without restating it: "don't post
    /// it", "cancel that", and the noun forms — "cancel the review", "stop the
    /// review", "withdraw the comments". Auto posts while a request is open,
    /// so a cancellation it cannot read is a post the user called off.
    private static let cancellationRegex = try? NSRegularExpression(
        pattern: #"\b(?:(?:do not|don't|dont|never)\s+(?:post|publish|submit|send|add)\s+(?:it|that|them|this)|(?:cancel|stop|withdraw|abort|scrap|drop|discard|forget)\s+(?:that|it|this|(?:(?:the|that|this|my|your|our)\s+)?(?:github\s+)?(?:pr\s+)?(?:review|reviews|posting|post|comments?)))\b"#
    )

    struct PostingRequest {
        let text: String
        let timestamp: Date?
        let eventID: UUID?
    }

    static func isPending(task: AgentTask) -> Bool {
        guard let request = postingRequest(task: task) else { return false }
        guard let target = GitHubReviewTargetResolver.durableTarget(task: task, request: request.text)
                ?? boundTarget(task: task, request: request) else {
            return hasUnresolvedTarget(task: task, request: request)
        }
        return !task.events.contains { event in
            guard [GitHubReviewPublicationEventTypes.receipt,
                   GitHubReviewPublicationEventTypes.receiptRecovery].contains(event.type),
                  (request.timestamp.map { event.timestamp >= $0 } ?? true),
                  let data = event.payload.data(using: .utf8),
                  let receipt = try? JSONDecoder().decode(GitHubReviewPublicationRecord.self, from: data) else {
                return false
            }
            return receipt.pullRequestURL.caseInsensitiveCompare(target.url) == .orderedSame
        }
    }

    static func postingRequest(task: AgentTask) -> PostingRequest? {
        var current = publicationIntent(in: task.goal) == .publish
            ? PostingRequest(text: task.goal, timestamp: nil, eventID: nil) : nil
        let messages = task.events
            .filter {
                $0.type == TaskEventTypes.Conversation.userMessage.rawValue
                    || $0.type == TaskPlanConversationEventTypes.userMessage
            }
            .sorted { lhs, rhs in
                lhs.timestamp == rhs.timestamp
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.timestamp < rhs.timestamp
            }
        for message in messages {
            switch publicationIntent(in: message.payload) {
            case .publish:
                current = PostingRequest(text: message.payload, timestamp: message.timestamp, eventID: message.id)
            case .cancel:
                current = nil
            case nil:
                if current != nil, cancellation(in: message.payload) {
                    current = nil
                }
            }
        }
        return current
    }

    fileprivate static func boundTarget(task: AgentTask, request: PostingRequest) -> GitHubReviewTargetResolver.Target? {
        task.events
            .filter { $0.type == GitHubReviewPublicationEventTypes.targetBound }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { event -> GitHubReviewTargetResolver.Target? in
                guard let data = event.payload.data(using: .utf8),
                      let record = try? JSONDecoder().decode(GitHubReviewBoundTargetRecord.self, from: data),
                      record.requestEventID == request.eventID,
                      record.requestDigest == requestDigest(request.text),
                      record.number > 0,
                      GitHubReviewTargetResolver.repository(in: "https://github.com/\(record.repository)") == record.repository else {
                    return nil
                }
                return GitHubReviewTargetResolver.Target(repository: record.repository, number: record.number)
            }
            .first
    }

    static func hasUnresolvedTarget(task: AgentTask, request: PostingRequest? = nil) -> Bool {
        guard let request = request ?? postingRequest(task: task) else { return false }
        return task.events.contains { event in
            guard event.type == GitHubReviewPublicationEventTypes.targetUnresolved,
                  let data = event.payload.data(using: .utf8),
                  let record = try? JSONDecoder().decode(GitHubReviewUnresolvedTargetRecord.self, from: data) else {
                return false
            }
            return record.requestEventID == request.eventID
                && record.requestDigest == requestDigest(request.text)
        }
    }

    static func unresolvedTargetMessage(task: AgentTask) -> String? {
        guard hasUnresolvedTarget(task: task) else { return nil }
        return "ASTRA is waiting for a GitHub target. Add a full pull request URL or reconnect this workspace to its GitHub repository, then ask ASTRA to post the review again."
    }

    static func needsOriginTargetBinding(task: AgentTask) -> Bool {
        guard let request = postingRequest(task: task) else { return false }
        return GitHubReviewTargetResolver.durableTarget(task: task, request: request.text) == nil
            && boundTarget(task: task, request: request) == nil
            && request.text.range(of: "github.com/", options: .caseInsensitive) == nil
            && GitHubReviewTargetResolver.shorthandNumber(in: request.text) != nil
    }

    @MainActor
    static func bindOriginTargetIfNeeded(
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext,
        originURL: (String) async -> String? = { path in
            await GitService.shared.getRemoteOriginURL(at: path)
        }
    ) async -> Bool {
        guard needsOriginTargetBinding(task: task),
              let request = postingRequest(task: task),
              let number = GitHubReviewTargetResolver.shorthandNumber(in: request.text) else { return false }
        let path = task.executionRootPath ?? task.workspace?.primaryPath
        let origin: String?
        if let path {
            origin = await originURL(path)
        } else {
            origin = nil
        }
        let repository = origin.flatMap(GitService.githubRepositoryArgument(from:))
        guard let repository, repository.hasPrefix("github.com/") else {
            guard !hasUnresolvedTarget(task: task, request: request) else { return false }
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: GitHubReviewPublicationEventTypes.targetUnresolved,
                payload: GitHubReviewUnresolvedTargetRecord(
                    requestEventID: request.eventID,
                    requestDigest: requestDigest(request.text),
                    reason: "The workspace GitHub origin could not be resolved."
                ),
                run: run
            ))
            return true
        }
        let record = GitHubReviewBoundTargetRecord(
            requestEventID: request.eventID,
            requestDigest: requestDigest(request.text),
            repository: String(repository.dropFirst("github.com/".count)),
            number: number
        )
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: GitHubReviewPublicationEventTypes.targetBound,
            payload: record,
            run: run
        ))
        return true
    }

    private static func requestDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func requestsPublication(in request: String) -> Bool {
        publicationIntent(in: request) == .publish
    }

    /// Whether the open posting request asks, in so many words, to post,
    /// publish or submit the review — what Auto requires before it posts one
    /// without the sheet. Offline: it reads the request, not GitHub.
    static func explicitlyRequestsPosting(task: AgentTask) -> Bool {
        guard let request = postingRequest(task: task) else { return false }
        return commandsPosting(request.text)
    }

    /// The positive list `imperativePublicationRegex` describes.
    static func commandsPosting(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard let imperative = imperativePublicationRegex, let deferring = deferringRegex,
              let pausing = pausingRegex,
              pausing.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)) == nil else {
            return false
        }
        // Clauses end at punctuation before a space or the end of the text, so
        // a link's dots do not split one, and a joined command ("review it
        // and post the review") starts after its `and` or `then`.
        let clauses = lower
            .replacingOccurrences(of: #"[.!?;,](?=\s|$)|\n"#, with: "\u{1E}", options: .regularExpression)
            .components(separatedBy: "\u{1E}")
        let joiners: Set<String> = ["and", "then"]
        return clauses.contains { clause in
            let range = NSRange(clause.startIndex..<clause.endIndex, in: clause)
            return imperative.matches(in: clause, range: range).contains { match in
                guard let matched = Range(match.range, in: clause) else { return false }
                let words = clause[..<matched.lowerBound].split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                let lead = words.lastIndex(where: joiners.contains).map { Array(words[($0 + 1)...]) } ?? words
                let rest = String(clause[matched.upperBound...])
                return lead.allSatisfy(imperativeLeadWords.contains)
                    && deferring.firstMatch(in: rest, range: NSRange(rest.startIndex..<rest.endIndex, in: rest)) == nil
            }
        }
    }

    private enum Intent { case publish, cancel }

    private static func cancellation(in request: String) -> Bool {
        guard let regex = cancellationRegex else { return false }
        let lower = request.lowercased()
        return regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)) != nil
    }

    private static func publicationIntent(in request: String) -> Intent? {
        publicationIntent(in: request, using: publicationRegex)
    }

    private static func publicationIntent(in request: String, using regex: NSRegularExpression?) -> Intent? {
        let lower = request.lowercased()
        // Bind the publishing verb to the review object. A request to add
        // tests while reviewing a PR must not become permission to post.
        guard let regex else { return nil }
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        return regex.matches(in: lower, range: range).last.flatMap { match in
            guard let matchRange = Range(match.range, in: lower) else { return nil }
        let prefix = lower[..<matchRange.lowerBound]
        let clause = String(prefix.suffix(64))
            .components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
            .last ?? ""
        // Negation is scoped to the same short phrase as the verb.
        let words = clause.split(whereSeparator: { $0.isWhitespace }).suffix(4)
        let lead = words.joined(separator: " ")
        let matchedClause = String(lower[matchRange])
        // "stop posting the review" calls it off as surely as "don't post it".
        let negationPattern = #"\b(?:do not|don't|dont|never|without|no|not|stop|cancel|abort|withdraw|skip)\b"#
        let negatedBeforeVerb = lead.range(of: negationPattern, options: .regularExpression) != nil
        let negatedBetweenVerbAndObject = matchedClause.range(of: negationPattern, options: .regularExpression) != nil
        return !negatedBeforeVerb && !negatedBetweenVerbAndObject
            ? .publish : .cancel
        }
    }
}

enum GitHubReviewPublicationError: LocalizedError {
    case invalid(String)
    case unusableArtifact(String)
    case alreadyDispatched
    case staleHead
    case uncertain
    case receiptPersistenceFailed(String)
    /// Auto posts a review only because the user asked for one to be posted,
    /// and only while that request is open.
    case notRequested

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .unusableArtifact(let message): message
        case .alreadyDispatched:
            "This review was already sent or its outcome is uncertain. Check GitHub before preparing a new review."
        case .staleHead:
            "The pull request has changed since these comments were prepared. Recheck the diff and prepare a new review."
        case .uncertain:
            "ASTRA sent the review request but could not confirm the result. Check the pull request on GitHub before trying again."
        case .receiptPersistenceFailed(let reviewURL):
            "GitHub confirmed the review at \(reviewURL), but ASTRA could not save its receipt. Check GitHub before continuing; ASTRA will not resend this file."
        case .notRequested:
            "No request to post a review is open on this task: the user has not asked ASTRA to post, publish "
                + "or submit one, withdrew it, or it was already posted. Without that request ASTRA does not post "
                + "a review on its own; the file waits for the user's review."
        }
    }
}

enum GitHubReviewArtifactPolicy {
    static func candidatePath(in paths: [String]) -> String? {
        paths.first { path in
            isReviewFile(path)
        }
    }

    /// The one rule, shared with the broker's post-review request, so a file
    /// the agent can ask ASTRA to post is a file the dock would offer.
    static func isReviewFile(_ path: String) -> Bool {
        GitHubReviewHostControlOperations.isReviewFileName(URL(fileURLWithPath: path).lastPathComponent)
    }

    /// Whether two spellings name the same review file in the task folder.
    ///
    /// Dispatch and dismissal are recorded against the path the poster used,
    /// and the dock asks about paths from artifacts and tool events, which may
    /// spell the task folder through a symlink (`/var` and `/private/var`) or
    /// not. Compared as strings, a review Auto posted under one spelling would
    /// be offered again under the other — and a second Post is a second
    /// review. Compared by their place under the task folder, lexically, so the
    /// dock's check stays free of per-path filesystem work.
    ///
    /// And without regard to case. The default macOS volume does not tell
    /// `PR12_REVIEW.JSON` from `pr12_review.json`, and the review-file rule
    /// accepts both, so a case-sensitive comparison let one file be posted
    /// twice under two spellings. On a case-sensitive volume this can only
    /// refuse a second file whose name differs by case alone — the safe way to
    /// be wrong, and a new review takes a new name anyway.
    static func sameFile(_ lhs: String, _ rhs: String, root: TaskOutputArtifactPathPolicy.ResolvedRoot) -> Bool {
        lhs == rhs || (taskFolderKey(lhs, root: root).map { $0 == taskFolderKey(rhs, root: root) } ?? false)
    }

    private static func taskFolderKey(_ path: String, root: TaskOutputArtifactPathPolicy.ResolvedRoot) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for base in [root.standardized, root.resolved] where !base.isEmpty && standardized.hasPrefix(base + "/") {
            return String(standardized.dropFirst(base.count + 1)).lowercased()
        }
        return nil
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
    private let saveReceipt: ((AgentTask, ModelContext) throws -> Void)?
    private let originURL: (String) async -> String?

    init(
        modelContext: ModelContext,
        cli: any GitHubReviewCLI = NativeGitHubReviewCLI(),
        saveReceipt: ((AgentTask, ModelContext) throws -> Void)? = nil,
        originURL: @escaping (String) async -> String? = { path in
            await GitService.shared.getRemoteOriginURL(at: path)
        }
    ) {
        self.modelContext = modelContext
        self.cli = cli
        self.saveReceipt = saveReceipt
        self.originURL = originURL
    }

    static func hasDispatched(task: AgentTask, filePath: String) -> Bool {
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(TaskWorkspaceAccess(task: task).taskFolder)
        return task.events.contains { event in
            guard event.type == GitHubReviewPublicationEventTypes.dispatched,
                  let data = event.payload.data(using: .utf8),
                  let record = try? JSONDecoder().decode(GitHubReviewPublicationRecord.self, from: data) else {
                return false
            }
            return GitHubReviewArtifactPolicy.sameFile(record.filePath, filePath, root: root)
        }
    }

    static func hasDismissed(task: AgentTask, filePath: String) -> Bool {
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(TaskWorkspaceAccess(task: task).taskFolder)
        return task.events.contains { event in
            guard event.type == GitHubReviewPublicationEventTypes.unusable,
                  let data = event.payload.data(using: .utf8),
                  let record = try? JSONDecoder().decode(GitHubReviewUnusableArtifactRecord.self, from: data) else {
                return false
            }
            return GitHubReviewArtifactPolicy.sameFile(record.filePath, filePath, root: root)
        }
    }

    static func pendingCandidatePath(task: AgentTask, filePaths: [String]) -> String? {
        filePaths.first { path in
            GitHubReviewArtifactPolicy.isReviewFile(path)
                && !hasDispatched(task: task, filePath: path)
                && !hasDismissed(task: task, filePath: path)
        }
    }

    static func hasReceipt(task: AgentTask, run: TaskRun) -> Bool {
        task.events.contains { event in
            event.run?.id == run.id
                && [GitHubReviewPublicationEventTypes.receipt,
                    GitHubReviewPublicationEventTypes.receiptRecovery].contains(event.type)
        }
    }

    func prepareFirstAvailable(task: AgentTask, filePaths: [String]) async throws -> GitHubReviewProposal {
        var lastUnusable: Error?
        var dismissals: [GitHubReviewUnusableArtifactRecord] = []
        for path in filePaths where GitHubReviewArtifactPolicy.isReviewFile(path)
            && !Self.hasDispatched(task: task, filePath: path)
            && !Self.hasDismissed(task: task, filePath: path) {
            do {
                let proposal = try await prepare(task: task, filePath: path)
                try persistDismissals(dismissals, task: task)
                return proposal
            } catch let error as GitHubReviewPublicationError {
                lastUnusable = error
                switch error {
                case .unusableArtifact, .staleHead:
                    dismissals.append(.init(filePath: path, reason: error.localizedDescription))
                default:
                    break
                }
            }
        }
        try persistDismissals(dismissals, task: task)
        throw lastUnusable ?? GitHubReviewPublicationError.invalid("No review proposal is available to post.")
    }

    private func persistDismissals(_ records: [GitHubReviewUnusableArtifactRecord], task: AgentTask) throws {
        guard !records.isEmpty else { return }
        let events = records.map { record in
            TaskEvent.structuredPayloadEvent(task: task, type: GitHubReviewPublicationEventTypes.unusable, payload: record)
        }
        events.forEach(modelContext.insert)
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "github_review_unusable_artifacts"]
            )
        } catch {
            events.forEach { modelContext.delete($0) }
            task.events.removeAll { event in events.contains { $0.id == event.id } }
            throw error
        }
    }

    func prepare(task: AgentTask, filePath: String) async throws -> GitHubReviewProposal {
        guard !Self.hasDispatched(task: task, filePath: filePath) else {
            throw GitHubReviewPublicationError.alreadyDispatched
        }
        guard !Self.hasDismissed(task: task, filePath: filePath) else {
            throw GitHubReviewPublicationError.unusableArtifact("This review proposal was dismissed after validation failed. Save a corrected review under a new versioned filename.")
        }
        let data: Data
        let payload: GitHubReviewPayload
        do {
            (data, payload) = try readPayload(task: task, filePath: filePath)
        } catch let error as GitHubReviewPublicationError {
            throw GitHubReviewPublicationError.unusableArtifact(error.localizedDescription)
        } catch {
            throw GitHubReviewPublicationError.unusableArtifact("The review file could not be read as valid JSON.")
        }
        let targetBindingChanged = await GitHubReviewPublicationRequirement.bindOriginTargetIfNeeded(
            task: task,
            run: task.runs.max(by: { $0.startedAt < $1.startedAt }),
            modelContext: modelContext,
            originURL: originURL
        )
        if targetBindingChanged {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "github_review_target_resolution"]
            )
        }
        let target = try await target(for: task, filePath: filePath)
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent.lowercased()
        let expectedPrefix = "pr\(target.number)_review"
        if fileName != "github_review.json",
           fileName != "\(expectedPrefix).json",
           !(fileName.hasPrefix(expectedPrefix + "_") && fileName.hasSuffix(".json")) {
            throw GitHubReviewPublicationError.unusableArtifact("The review filename does not match the target pull request.")
        }
        let metadata = try await pullRequestMetadata(task: task, target: target)
        guard metadata.state.lowercased() == "open" else {
            throw GitHubReviewPublicationError.unusableArtifact("The target pull request is no longer open.")
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
            payload: payload,
            validatedData: data
        )
    }

    /// The dispatch event is durably saved before the network call. If ASTRA
    /// exits or the response is lost, this file cannot be submitted again by a
    /// later click without first checking GitHub and creating a new proposal.
    /// `authorization` says who let ASTRA post it: the user in the sheet, or
    /// Auto without asking. It is recorded on the receipt and changes none of
    /// the checks below.
    func publish(
        task: AgentTask,
        proposal: GitHubReviewProposal,
        authorization: ExternalActionAuthorization = .userReviewed
    ) async throws -> GitHubReviewPublicationRecord {
        guard !Self.hasDispatched(task: task, filePath: proposal.filePath) else {
            throw GitHubReviewPublicationError.alreadyDispatched
        }
        let current = try await prepare(task: task, filePath: proposal.filePath)
        guard current.id == proposal.id, current.digest == proposal.digest else {
            throw GitHubReviewPublicationError.invalid("The review file changed after you opened it. Review the new content before posting.")
        }
        guard !Self.hasDispatched(task: task, filePath: proposal.filePath) else {
            throw GitHubReviewPublicationError.alreadyDispatched
        }
        // Auto posts because the user asked; a "don't post it" recorded while
        // the checks above awaited, or a review already posted for the
        // request, closes it, so it is read here, with no suspension before
        // dispatch is recorded.
        if authorization == .autoPolicy,
           !(GitHubReviewPublicationRequirement.isPending(task: task)
               && GitHubReviewPublicationRequirement.explicitlyRequestsPosting(task: task)) {
            throw GitHubReviewPublicationError.notRequested
        }
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-github-review-\(UUID().uuidString).json")
        try current.validatedData.write(to: inputURL, options: [.atomic])
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

        let response: ReviewResponse
        do {
            let output = try await cli.run(
                at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
                arguments: ["api", proposal.endpoint, "--hostname", "github.com", "--method", "POST", "--input", inputURL.path],
                label: "Post reviewed GitHub pull request review"
            )
            let responseDecoder = JSONDecoder()
            responseDecoder.keyDecodingStrategy = .convertFromSnakeCase
            response = try responseDecoder.decode(ReviewResponse.self, from: Data(output.utf8))
            let expectedState = proposal.payload.event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED"
            guard response.id > 0,
                  Self.matchesReviewURL(response.htmlUrl, proposal: proposal, reviewID: response.id),
                  response.state == expectedState,
                  response.commitId.caseInsensitiveCompare(proposal.payload.commitId) == .orderedSame,
                  response.submittedAt != nil else {
                throw GitHubReviewPublicationError.uncertain
            }
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

        let receipt = GitHubReviewPublicationRecord(
            proposalID: proposal.id,
            filePath: proposal.filePath,
            pullRequestURL: proposal.pullRequestURL,
            reviewURL: response.htmlUrl,
            reviewID: response.id,
            authorization: authorization
        )
        let persistedEventIDs = Set(task.events.map(\.id))
        let priorState = TaskStateMachine.ExternalOutcomeReceiptSnapshot(task: task, run: run)
        do {
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
            if completesRequestedReview, task.status == .pendingUser,
               run?.typedStopReason == .externalOutcomePending, let run {
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Task.approved,
                    payload: "Posted GitHub review: \(response.htmlUrl)",
                    run: run
                ))
                _ = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
            }
            if let saveReceipt {
                try saveReceipt(task, modelContext)
            } else {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: ["operation": "github_review_receipt", "review_id": String(response.id)]
                )
            }
            return receipt
        } catch {
            // Dispatch was saved before the network call. Retry the confirmed
            // receipt in its own event so a transient receipt transaction
            // failure does not strand an already-posted review.
            modelContext.rollback()
            task.events.removeAll { !persistedEventIDs.contains($0.id) }
            TaskStateMachine.restoreFailedExternalOutcomeReceipt(
                task: task, run: run, snapshot: priorState
            )
            let recoveryEvent = TaskEvent.structuredPayloadEvent(
                task: task,
                type: GitHubReviewPublicationEventTypes.receiptRecovery,
                payload: receipt,
                run: run
            )
            modelContext.insert(recoveryEvent)
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.info,
                payload: "GitHub confirmed the review at \(response.htmlUrl). ASTRA saved a recovery receipt after the first receipt save failed.",
                run: run
            ))
            if let run {
                _ = await TaskSuccessfulCompletionService.applyAfterRequiredExternalOutcome(
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
            }
            do {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: ["operation": "github_review_receipt_recovery", "review_id": String(response.id)]
                )
                return receipt
            } catch {
                modelContext.rollback()
                task.events.removeAll { !persistedEventIDs.contains($0.id) }
                TaskStateMachine.restoreFailedExternalOutcomeReceipt(
                    task: task, run: run, snapshot: priorState
                )
                throw GitHubReviewPublicationError.receiptPersistenceFailed(response.htmlUrl)
            }
        }
    }

    /// Auto: posts the review file the agent asked ASTRA to post, at the moment
    /// it asks, and returns the receipt to it.
    ///
    /// What is eligible is this request's artifact: the file it names, holding
    /// the bytes whose digest the broker read when the agent asked. Never a
    /// review file a run wrote or touched — that rule let Auto post a review an
    /// earlier Ask run had left for the user — and never anything after the
    /// run, so there is no window in which a cancel, a failed check, a crash
    /// or a decline has to decide whether to post. Every check `prepare` and
    /// `publish` make for the sheet still holds, including that the user asked
    /// for a review to be posted and has not withdrawn it.
    func publishWhenRequested(
        task: AgentTask,
        fileName: String,
        contentDigest: String
    ) async throws -> GitHubReviewPublicationRecord {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard GitHubReviewHostControlOperations.isReviewFileName(fileName), !fileName.contains("/"),
              !taskFolder.isEmpty else {
            throw GitHubReviewPublicationError.invalid("Choose a PR review JSON file from this task’s folder.")
        }
        // Offline and first, so a task whose user never asked for a review to
        // be posted reaches no GitHub endpoint. Whether that request is still
        // open is read by `publish`, after `prepare` has bound a shorthand
        // target ("post a review on PR 12") to the workspace's origin — before
        // that binding a shorthand request does not yet read as pending.
        guard GitHubReviewPublicationRequirement.explicitlyRequestsPosting(task: task) else {
            throw GitHubReviewPublicationError.notRequested
        }
        let filePath = URL(fileURLWithPath: taskFolder, isDirectory: true).appendingPathComponent(fileName).path
        let proposal = try await prepare(task: task, filePath: filePath)
        guard proposal.digest == contentDigest.lowercased() else {
            throw GitHubReviewPublicationError.invalid(
                "The review file changed after you asked to post it. Write the review you want posted to a new "
                    + "file name and ask again."
            )
        }
        return try await publish(task: task, proposal: proposal, authorization: .autoPolicy)
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
                        && comment.startLine! <= comment.line
                        && ["LEFT", "RIGHT"].contains(comment.startSide!)) else {
                throw GitHubReviewPublicationError.invalid("An inline comment has an invalid path, line, side, or body.")
            }
        }
    }

    private func target(for task: AgentTask, filePath: String) async throws -> GitHubReviewTargetResolver.Target {
        let postingRequest = GitHubReviewPublicationRequirement.postingRequest(task: task)
        let request = postingRequest?.text
        if let target = GitHubReviewTargetResolver.durableTarget(task: task, request: request)
            ?? postingRequest.flatMap({ GitHubReviewPublicationRequirement.boundTarget(task: task, request: $0) }) {
            return target
        }
        if let postingRequest,
           GitHubReviewPublicationRequirement.hasUnresolvedTarget(task: task, request: postingRequest) {
            throw GitHubReviewPublicationError.invalid(
                "The workspace GitHub origin could not be resolved. Add a full pull request URL or reconnect this workspace to GitHub."
            )
        }
        if let request, request.range(of: "github.com/", options: .caseInsensitive) != nil {
            throw GitHubReviewPublicationError.invalid("The posting request must contain one valid GitHub pull request URL.")
        }
        guard let number = request.flatMap(GitHubReviewTargetResolver.shorthandNumber(in:))
                ?? GitHubReviewTargetResolver.fileNumber(in: filePath) else {
            throw GitHubReviewPublicationError.invalid("Add the pull request number to the task or use a numbered review filename.")
        }
        if let repository = GitHubReviewTargetResolver.repository(in: task.goal) {
            return GitHubReviewTargetResolver.Target(repository: repository, number: number)
        }
        guard task.goal.range(of: "github.com/", options: .caseInsensitive) == nil,
              let path = task.executionRootPath ?? task.workspace?.primaryPath,
              let origin = await originURL(path),
              let repository = GitService.githubRepositoryArgument(from: origin),
              repository.hasPrefix("github.com/") else {
            throw GitHubReviewPublicationError.invalid("Add a full GitHub pull request URL to the task or connect its workspace to a GitHub origin.")
        }
        return GitHubReviewTargetResolver.Target(
            repository: String(repository.dropFirst("github.com/".count)), number: number
        )
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

    private static func matchesReviewURL(
        _ reviewURL: String,
        proposal: GitHubReviewProposal,
        reviewID: Int
    ) -> Bool {
        guard let actual = URLComponents(string: reviewURL),
              let expected = URLComponents(string: proposal.pullRequestURL) else { return false }
        return actual.scheme?.lowercased() == "https"
            && actual.host?.lowercased() == "github.com"
            && actual.path.caseInsensitiveCompare(expected.path) == .orderedSame
            && actual.fragment == "pullrequestreview-\(reviewID)"
    }

    private func pullRequestMetadata(task: AgentTask, target: GitHubReviewTargetResolver.Target) async throws -> PullRequestMetadata {
        let output = try await cli.run(
            at: task.executionRootPath ?? task.workspace?.primaryPath ?? "",
            arguments: ["api", "repos/\(target.repository)/pulls/\(target.number)", "--hostname", "github.com", "--method", "GET"],
            label: "Check GitHub pull request review target"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PullRequestMetadata.self, from: Data(output.utf8))
    }
}
