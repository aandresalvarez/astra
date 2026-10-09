import Foundation
import ASTRAModels

/// One action ASTRA took outside the machine, as the chat shows it.
///
/// A presentation value, not a second owner: every field is read from the
/// typed receipt event the action already wrote. A record therefore exists only
/// for an action that completed, and the receipt stays the authority for what
/// happened. In Ask it confirms what an approval did; in Auto it is the only
/// notice the user gets.
struct ExternalActionRecord: Equatable, Hashable, Sendable, Identifiable {
    /// The receipt event's id.
    let id: UUID
    let kind: ExternalActionKind
    /// Noun-led and past tense: "Created STAR-12558", "Opened draft pull request #12".
    let title: String
    /// Where it happened: "Jira · STAR / Bug", "owner/repo".
    let destination: String
    let url: URL?
    let authorization: ExternalActionAuthorization
    let timestamp: Date
    /// Text notices older builds wrote beside this receipt. The thread hides
    /// them while the record is shown, so one action is not narrated twice.
    let legacyNotices: [String]

    /// The record as one line of conversation context for a provider.
    var contextLine: String {
        var line = "\(title) (\(destination))"
        if let url { line += ": \(url.absoluteString)" }
        return line
    }
}

/// Turns one kind of receipt event into a record. A new external action — the
/// GitHub thread replies of PR #482, for example — adds a source here and
/// nothing else in the chat changes.
protocol ExternalActionRecordSource {
    static var eventTypes: Set<String> { get }
    static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord?
}

enum ExternalActionRecordProjection {
    static let sources: [any ExternalActionRecordSource.Type] = [
        ConnectorMutationRecordSource.self,
        GitHubReviewRecordSource.self,
        GitPullRequestRecordSource.self,
        ObservedExternalActionRecordSource.self
    ]

    static let eventTypes: Set<String> = sources.reduce(into: []) { $0.formUnion($1.eventTypes) }

    static func record(type: String, payload: String, eventID: UUID, timestamp: Date) -> ExternalActionRecord? {
        guard let source = sources.first(where: { $0.eventTypes.contains(type) }),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return source.record(payload: data, eventID: eventID, timestamp: timestamp)
    }

    static func repository(fromGitHubURL url: String) -> String? {
        guard let components = URLComponents(string: url),
              components.host?.lowercased() == "github.com" else {
            return nil
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    fileprivate static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? TaskEventPayloadCodec.makeDecoder().decode(type, from: data)
    }
}

/// A Jira write ASTRA sent: `connector.mutation.receipt`.
enum ConnectorMutationRecordSource: ExternalActionRecordSource {
    static let eventTypes: Set<String> = [ConnectorMutationEventTypes.receipt]

    private struct Fields: Decodable {
        let serviceType: String
        let operation: String
        let target: String
        let createdKey: String?
        let createdURL: String?
        let destinationURL: String?
        let authorization: ExternalActionAuthorization?
    }

    static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord? {
        guard let fields = ExternalActionRecordProjection.decode(Fields.self, from: payload) else { return nil }
        let service = serviceName(fields.serviceType)
        let title: String
        var destination = service
        switch fields.operation.lowercased() {
        case "create_issue":
            title = "Created \(fields.createdKey ?? "an issue")"
            destination = "\(service) · \(fields.target)"
        case "add_comment":
            title = "Commented on \(fields.target)"
        case "update_issue":
            title = "Updated \(fields.target)"
        case "transition_issue":
            title = "Changed the status of \(fields.target)"
        default:
            title = "Sent \(fields.operation.replacingOccurrences(of: "_", with: " ")) to \(fields.target)"
        }
        return ExternalActionRecord(
            id: eventID,
            kind: .connectorMutation,
            title: title,
            destination: destination,
            url: fields.createdURL.flatMap { linkOnTheConnector($0, destination: fields.destinationURL) },
            authorization: fields.authorization ?? .userReviewed,
            timestamp: timestamp,
            legacyNotices: []
        )
    }

    /// The created item's link comes from the connector's response, so it is
    /// shown only as an http(s) link on the host the request went to.
    private static func linkOnTheConnector(_ value: String, destination: String?) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(),
              let expected = destination.flatMap(URL.init(string:))?.host?.lowercased(),
              host == expected,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // A user, query or fragment from the response can carry a token.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func serviceName(_ serviceType: String) -> String {
        switch serviceType.lowercased() {
        case "jira": "Jira"
        case "redcap": "REDCap"
        default: serviceType.capitalized
        }
    }
}

/// A pull-request review ASTRA posted: `github.review.receipt` and its recovery.
enum GitHubReviewRecordSource: ExternalActionRecordSource {
    static let eventTypes: Set<String> = [
        GitHubReviewPublicationEventTypes.receipt,
        GitHubReviewPublicationEventTypes.receiptRecovery
    ]

    static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord? {
        guard let receipt = ExternalActionRecordProjection.decode(GitHubReviewPublicationRecord.self, from: payload) else {
            return nil
        }
        let number = URL(string: receipt.pullRequestURL)?.lastPathComponent
        let link = receipt.reviewURL ?? receipt.pullRequestURL
        return ExternalActionRecord(
            id: eventID,
            kind: .githubReviewPublication,
            title: number.map { "Posted a review on pull request #\($0)" } ?? "Posted a pull request review",
            destination: ExternalActionRecordProjection.repository(fromGitHubURL: receipt.pullRequestURL) ?? "GitHub",
            url: URL(string: link),
            authorization: receipt.authorization ?? .userReviewed,
            timestamp: timestamp,
            legacyNotices: receipt.reviewURL.map { ["Posted GitHub review: \($0)"] } ?? []
        )
    }
}

/// A draft pull request ASTRA published: `git.publish.receipt`.
enum GitPullRequestRecordSource: ExternalActionRecordSource {
    static let eventTypes: Set<String> = [TaskExternalOutcomeEventTypes.publicationReceipt]

    private struct Fields: Decodable {
        let pullRequestNumber: Int
        let pullRequestURL: String
        let isDraft: Bool
        let source: GitPullRequestPublishReceiptSource?
        let authorization: ExternalActionAuthorization?
    }

    static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord? {
        guard let fields = ExternalActionRecordProjection.decode(Fields.self, from: payload) else { return nil }
        let noun = fields.isDraft ? "draft pull request" : "pull request"
        // The publisher reuses an already-open pull request instead of opening
        // a second one; that path pushes and creates nothing, and the row must
        // not say it did.
        let title = fields.source == .existing
            ? "Found existing \(noun) #\(fields.pullRequestNumber)"
            : "Opened \(noun) #\(fields.pullRequestNumber)"
        return ExternalActionRecord(
            id: eventID,
            kind: .gitPullRequestPublication,
            title: title,
            destination: ExternalActionRecordProjection.repository(fromGitHubURL: fields.pullRequestURL) ?? "GitHub",
            url: URL(string: fields.pullRequestURL),
            authorization: fields.authorization ?? .userReviewed,
            timestamp: timestamp,
            legacyNotices: ["Published draft pull request #\(fields.pullRequestNumber): \(fields.pullRequestURL)"]
        )
    }
}
