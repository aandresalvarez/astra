import Foundation
import CoreFoundation
import MCPServerKit

// Typed Jira access held on the host: the shape of every request the broker is
// allowed to send, and the validators the proposals share.
//
// Split out of `HostControlToolSupport.swift` when `propose_issue` landed. The
// read gate and the proposal gate have to be read side by side to see that they
// are the same idiom — enumerate what is allowed, refuse the rest — and that
// only one of them produces something with a body. Buried a thousand lines into
// the server they were not readable as a pair. The proposals themselves — the
// writes an agent may compose and ASTRA stages for review — live in
// `JiraProposalPolicy.swift`; only their field validators are here.
//
// What stays in the server: the HTTP client, the response types, and the
// readiness check, because sending is the server's job and this file's whole
// claim is that it never sends.

struct JiraHTTPRequest {
    var method: String
    var path: String
    var queryItems: [URLQueryItem]

    var diagnosticPath: String {
        if queryItems.isEmpty {
            return path
        }
        return "\(path)?<query>"
    }
}

/// A validated `create_issue` payload, composed by the agent and not yet sent.
///
/// Kept separate from `JiraHTTPRequest` deliberately. That type has no body
/// field and is only ever built with `method: "GET"` — it is the shape of a
/// read, and giving it a body would quietly turn every read path into one that
/// could write. A proposal is a different thing with a different destination:
/// it goes to a file, and only the app turns it into a request.
struct JiraIssueProposal {
    var projectKey: String
    var issueType: String
    var summary: String
    var description: String?
    var priority: String?
    var labels: [String]
    var assigneeAccountID: String?
    var parentKey: String?

    /// REST v2, where the reads use v3. v3 requires the description as
    /// Atlassian Document Format — a nested JSON tree the agent would have to
    /// build node by node, and would build subtly wrong. v2 takes text and Jira
    /// converts it server-side, so what the user reviews in the staged file is
    /// what they get in the ticket.
    var requestPath: String { "/rest/api/2/issue" }
    var requestMethod: String { "POST" }

    /// Scope, not content: the ticket's destination, for the approval row.
    var target: String { "\(projectKey) / \(issueType)" }

    var body: [String: Any] {
        var fields: [String: Any] = [
            "project": ["key": projectKey],
            "issuetype": ["name": issueType],
            "summary": summary
        ]
        if let description { fields["description"] = description }
        if let priority { fields["priority"] = ["name": priority] }
        if !labels.isEmpty { fields["labels"] = labels }
        if let assigneeAccountID { fields["assignee"] = ["accountId": assigneeAccountID] }
        if let parentKey { fields["parent"] = ["key": parentKey] }
        return ["fields": fields]
    }
}

enum JiraRequestPolicy {
    /// The vetted field set for a list of issues: enough to identify and
    /// triage each row, small enough that a page of them survives the
    /// response byte cap.
    private static let summaryFields = [
        "summary",
        "status",
        "assignee",
        "reporter",
        "priority",
        "issuetype",
        "project",
        "created",
        "updated"
    ]

    /// One issue can afford its body. `description` is what a ticket is
    /// actually *about*; without it "open the ticket and give me the detail"
    /// returns the same status board the search already returned, and the
    /// user has to open Jira in a browser to do the work — the one thing the
    /// connector exists to avoid. It stays out of `summaryFields` because a
    /// page of descriptions is what blows the cap, not a single one.
    private static let detailFields = summaryFields + ["description"]

    static func readRequest(operation: String, arguments: [String: Any]) throws -> JiraHTTPRequest {
        switch operation {
        case "get_issue":
            guard let issueKey = clean(arguments["issue_key"] as? String),
                  isValidIssueKey(issueKey) else {
                throw JiraRequestPolicyError("jira get_issue requires an issue_key such as ASTRA-123")
            }
            return JiraHTTPRequest(
                method: "GET",
                path: "/rest/api/3/issue/\(issueKey)",
                queryItems: [
                    URLQueryItem(name: "fields", value: Self.detailFields.joined(separator: ","))
                ]
            )
        case "search_jql":
            guard let jql = clean(arguments["jql"] as? String),
                  jql.count <= 1_000 else {
                throw JiraRequestPolicyError("jira search_jql requires a non-empty jql string up to 1000 characters")
            }
            var queryItems = [
                URLQueryItem(name: "jql", value: jql),
                URLQueryItem(name: "maxResults", value: String(maxResults(from: arguments["max_results"]))),
                URLQueryItem(name: "fields", value: Self.summaryFields.joined(separator: ","))
            ]
            if let nextPageToken = try nextPageToken(from: arguments["next_page_token"]) {
                queryItems.append(URLQueryItem(name: "nextPageToken", value: nextPageToken))
            }
            return JiraHTTPRequest(
                method: "GET",
                path: "/rest/api/3/search/jql",
                queryItems: queryItems
            )
        case "get_comments":
            guard let issueKey = clean(arguments["issue_key"] as? String),
                  isValidIssueKey(issueKey) else {
                throw JiraRequestPolicyError("jira get_comments requires an issue_key such as ASTRA-123")
            }
            // Oldest first: a support thread reads as a conversation, and the
            // response is byte-capped, so keeping the head keeps the request.
            return JiraHTTPRequest(
                method: "GET",
                path: "/rest/api/3/issue/\(issueKey)/comment",
                queryItems: [
                    URLQueryItem(name: "maxResults", value: String(maxResults(from: arguments["max_results"]))),
                    URLQueryItem(name: "startAt", value: String(try startAt(from: arguments["start_at"]))),
                    URLQueryItem(name: "orderBy", value: "created")
                ]
            )
        case "get_transitions":
            guard let issueKey = clean(arguments["issue_key"] as? String),
                  isValidIssueKey(issueKey) else {
                throw JiraRequestPolicyError("jira get_transitions requires an issue_key such as ASTRA-123")
            }
            // What `propose_transition` has to name. Transition ids belong to a
            // project's workflow, so there is no list to hardcode and no way to
            // guess one — the agent asks the ticket which moves it offers.
            return JiraHTTPRequest(
                method: "GET",
                path: "/rest/api/3/issue/\(issueKey)/transitions",
                queryItems: []
            )
        default:
            throw JiraRequestPolicyError("Unsupported Jira operation '\(operation)'")
        }
    }

    /// Routing and timing, accepted alongside every proposal's own fields. They
    /// steer the call and never appear in a staged payload.
    private static let routingArgumentKeys: Set<String> = ["operation", "alias", "timeout_seconds"]

    /// The fields `propose_issue` accepts. Default-deny on *names*, matching
    /// how every other operation in this module is gated: an argument that is
    /// not on this list is refused rather than dropped.
    ///
    /// Dropping is the dangerous variant. Jira's create endpoint takes an open
    /// `fields` map — security level, custom fields, watchers — and an agent
    /// that sets one and is silently ignored will report the ticket as filed
    /// with a restriction it does not have. Refusing says so.
    static let issueProposalFields: Set<String> = [
        "project_key", "issue_type", "summary", "description",
        "priority", "labels", "assignee_account_id", "parent_key"
    ]

    /// Refuses any argument the proposal does not declare, naming what it does.
    static func refuseUnknownArguments(
        _ arguments: [String: Any],
        fields: Set<String>,
        operation: String
    ) throws {
        let unknown = Set(arguments.keys).subtracting(fields.union(routingArgumentKeys)).sorted()
        guard unknown.isEmpty else {
            throw JiraRequestPolicyError(
                "jira \(operation) does not accept \(unknown.joined(separator: ", ")). "
                    + "Supported fields: \(fields.sorted().joined(separator: ", "))"
            )
        }
    }

    /// Validates a `create_issue` payload the agent composed. Builds no request
    /// and reaches no network: the caller stages the result and returns a
    /// digest.
    static func issueProposal(arguments: [String: Any]) throws -> JiraIssueProposal {
        let operation = "propose_issue"
        try refuseUnknownArguments(arguments, fields: issueProposalFields, operation: operation)
        guard let projectKey = try presentString(arguments["project_key"], field: "project_key", operation: operation),
              projectKey.range(of: #"^[A-Z][A-Z0-9_]{1,9}$"#, options: [.regularExpression]) != nil else {
            throw JiraRequestPolicyError("jira propose_issue requires a project_key such as STAR")
        }
        // Issue types are configured per project, so there is no value list to
        // check against — only a shape. Same for priority.
        let issueType = try label(
            arguments["issue_type"], field: "issue_type", limit: 50, required: true, operation: operation
        ) ?? ""
        return JiraIssueProposal(
            projectKey: projectKey,
            issueType: issueType,
            summary: try singleLineSummary(arguments["summary"], operation: operation, required: true) ?? "",
            description: try boundedText(arguments["description"], field: "description", operation: operation),
            priority: try label(
                arguments["priority"], field: "priority", limit: 50, required: false, operation: operation
            ),
            labels: try labels(from: arguments["labels"], operation: operation) ?? [],
            assigneeAccountID: try assigneeAccountID(arguments["assignee_account_id"], operation: operation),
            parentKey: try issueKey(arguments["parent_key"], field: "parent_key", operation: operation, required: false)
        )
    }

    /// A string argument, or `nil` when the agent left it out.
    ///
    /// A value of the wrong *type* is refused rather than treated as absent.
    /// Reading `value as? String` alone turns `summary: 42` into "no summary",
    /// and on an update that is a field the agent asked to change and the user
    /// reviewed a proposal without.
    static func presentString(_ value: Any?, field: String, operation: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            throw JiraRequestPolicyError("jira \(operation) \(field) must be a string")
        }
        return clean(string)
    }

    static func label(
        _ value: Any?,
        field: String,
        limit: Int,
        required: Bool,
        operation: String
    ) throws -> String? {
        guard let cleaned = try presentString(value, field: field, operation: operation) else {
            if required {
                throw JiraRequestPolicyError("jira \(operation) requires \(field)")
            }
            return nil
        }
        guard cleaned.count <= limit, !cleaned.contains("\n"), !cleaned.contains("\r") else {
            throw JiraRequestPolicyError("jira \(operation) \(field) must be a single line of up to \(limit) characters")
        }
        return cleaned
    }

    /// Jira's own summary limit. Enforced here so the failure is a message the
    /// agent can act on rather than a 400 after the user approved it.
    static func singleLineSummary(_ value: Any?, operation: String, required: Bool) throws -> String? {
        guard let summary = try presentString(value, field: "summary", operation: operation) else {
            if required {
                throw JiraRequestPolicyError("jira \(operation) requires a single-line summary of up to 255 characters")
            }
            return nil
        }
        guard summary.count <= 255, !summary.contains("\n"), !summary.contains("\r") else {
            throw JiraRequestPolicyError(
                required
                    ? "jira \(operation) requires a single-line summary of up to 255 characters"
                    : "jira \(operation) summary must be a single line of up to 255 characters"
            )
        }
        return summary
    }

    /// Prose the user will read and Jira will render: a description or a
    /// comment. Bounded to what Jira itself accepts.
    static func boundedText(
        _ value: Any?,
        field: String,
        operation: String,
        required: Bool = false
    ) throws -> String? {
        guard let text = try presentString(value, field: field, operation: operation) else {
            if required {
                throw JiraRequestPolicyError("jira \(operation) requires \(field)")
            }
            return nil
        }
        guard text.count <= 32_768 else {
            throw JiraRequestPolicyError("jira \(operation) \(field) must be at most 32768 characters")
        }
        return text
    }

    static func assigneeAccountID(_ value: Any?, operation: String) throws -> String? {
        guard let raw = try presentString(value, field: "assignee_account_id", operation: operation) else {
            return nil
        }
        guard raw.range(of: #"^[A-Za-z0-9:_-]{1,128}$"#, options: [.regularExpression]) != nil else {
            throw JiraRequestPolicyError("jira \(operation) assignee_account_id must be a Jira account id")
        }
        return raw
    }

    static func issueKey(_ value: Any?, field: String, operation: String, required: Bool) throws -> String? {
        guard let raw = try presentString(value, field: field, operation: operation) else {
            if required {
                throw JiraRequestPolicyError("jira \(operation) requires an \(field) such as STAR-123")
            }
            return nil
        }
        guard isValidIssueKey(raw) else {
            throw JiraRequestPolicyError("jira \(operation) \(field) must be an issue key such as STAR-123")
        }
        return raw
    }

    /// `nil` when the agent left `labels` out, and an empty array when it sent
    /// one — on an update those are different requests, "leave the labels
    /// alone" and "remove every label".
    static func labels(from value: Any?, operation: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? [Any] else {
            throw JiraRequestPolicyError("jira \(operation) labels must be an array of strings")
        }
        guard raw.count <= 20 else {
            throw JiraRequestPolicyError("jira \(operation) accepts at most 20 labels")
        }
        return try raw.map { element in
            // Jira silently rejects a label containing a space, so a
            // space-separated string here is a list the user would review and
            // not get. Reject it and say why.
            guard let label = clean(element as? String),
                  label.range(of: #"^[A-Za-z0-9_.:-]{1,255}$"#, options: [.regularExpression]) != nil else {
                throw JiraRequestPolicyError(
                    "jira \(operation) labels must each be a single word of letters, digits, or _.:- characters"
                )
            }
            return label
        }
    }

    private static func maxResults(from value: Any?) -> Int {
        let raw: Int?
        switch value {
        case let number as NSNumber:
            raw = number.intValue
        case let string as String:
            raw = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            raw = nil
        }
        return min(max(raw ?? 20, 1), 100)
    }

    static func startAt(from value: Any?) throws -> Int {
        guard let value else { return 0 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue),
              integer >= 0 else {
            throw JiraRequestPolicyError("jira get_comments start_at must be a non-negative integer")
        }
        return integer
    }

    private static func nextPageToken(from value: Any?) throws -> String? {
        guard let raw = value else { return nil }
        guard let token = clean(raw as? String),
              token.count <= 2_000,
              !token.contains("\n"),
              !token.contains("\r") else {
            throw JiraRequestPolicyError("jira search_jql next_page_token must be a non-empty string up to 2000 characters")
        }
        return token
    }

    static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isValidIssueKey(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Z][A-Z0-9_]+-[1-9][0-9]*$"#,
            options: [.regularExpression]
        ) != nil
    }
}

enum JiraCommentPagination {
    static func marker(body: String, requestedStartAt: Int) -> String? {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let comments = payload["comments"] as? [Any],
              let totalNumber = payload["total"] as? NSNumber,
              CFGetTypeID(totalNumber) != CFBooleanGetTypeID(),
              let total = Int(totalNumber.stringValue),
              total >= 0 else {
            return nil
        }
        let (nextStartAt, overflow) = requestedStartAt.addingReportingOverflow(comments.count)
        guard !overflow else { return nil }
        guard nextStartAt < total else { return nil }
        return "comments_complete: false\nnext_start_at: \(nextStartAt)"
    }
}

struct JiraRequestPolicyError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
