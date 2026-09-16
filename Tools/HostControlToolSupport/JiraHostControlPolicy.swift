import Foundation
import MCPServerKit

// Typed Jira access held on the host: the shape of every request the broker is
// allowed to compose, and the one operation that composes a request it is not
// allowed to send.
//
// Split out of `HostControlToolSupport.swift` when `propose_issue` landed. The
// read gate and the proposal gate have to be read side by side to see that they
// are the same idiom — enumerate what is allowed, refuse the rest — and that
// only one of them produces something with a body. Buried a thousand lines into
// the server they were not readable as a pair.
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
                    URLQueryItem(name: "orderBy", value: "created")
                ]
            )
        default:
            throw JiraRequestPolicyError("Unsupported Jira operation '\(operation)'")
        }
    }

    /// The arguments `propose_issue` accepts. Default-deny on *names*, matching
    /// how every other operation in this module is gated: an argument that is
    /// not on this list is refused rather than dropped.
    ///
    /// Dropping is the dangerous variant. Jira's create endpoint takes an open
    /// `fields` map — security level, custom fields, watchers — and an agent
    /// that sets one and is silently ignored will report the ticket as filed
    /// with a restriction it does not have. Refusing says so.
    private static let proposalArgumentKeys: Set<String> = [
        "operation", "alias", "timeout_seconds",
        "project_key", "issue_type", "summary", "description",
        "priority", "labels", "assignee_account_id", "parent_key"
    ]

    /// Validates a `create_issue` payload the agent composed. Builds no request
    /// and reaches no network: the caller stages the result and returns a
    /// digest.
    static func issueProposal(arguments: [String: Any]) throws -> JiraIssueProposal {
        let unknown = Set(arguments.keys).subtracting(proposalArgumentKeys).sorted()
        guard unknown.isEmpty else {
            throw JiraRequestPolicyError(
                "jira propose_issue does not accept \(unknown.joined(separator: ", ")). "
                    + "Supported fields: \(proposalArgumentKeys.subtracting(["operation", "alias", "timeout_seconds"]).sorted().joined(separator: ", "))"
            )
        }
        guard let projectKey = clean(arguments["project_key"] as? String),
              projectKey.range(of: #"^[A-Z][A-Z0-9_]{1,9}$"#, options: [.regularExpression]) != nil else {
            throw JiraRequestPolicyError("jira propose_issue requires a project_key such as STAR")
        }
        // Issue types are configured per project, so there is no value list to
        // check against — only a shape. Same for priority.
        let issueType = try label(arguments["issue_type"], field: "issue_type", limit: 50, required: true) ?? ""
        // Jira's own summary limit. Enforced here so the failure is a message
        // the agent can act on rather than a 400 after the user approved it.
        guard let summary = clean(arguments["summary"] as? String),
              summary.count <= 255,
              !summary.contains("\n"), !summary.contains("\r") else {
            throw JiraRequestPolicyError("jira propose_issue requires a single-line summary of up to 255 characters")
        }
        var description: String?
        if let raw = clean(arguments["description"] as? String) {
            guard raw.count <= 32_768 else {
                throw JiraRequestPolicyError("jira propose_issue description must be at most 32768 characters")
            }
            description = raw
        }
        let labels = try labels(from: arguments["labels"])
        var parentKey: String?
        if let raw = clean(arguments["parent_key"] as? String) {
            guard isValidIssueKey(raw) else {
                throw JiraRequestPolicyError("jira propose_issue parent_key must be an issue key such as STAR-123")
            }
            parentKey = raw
        }
        var assignee: String?
        if let raw = clean(arguments["assignee_account_id"] as? String) {
            guard raw.range(of: #"^[A-Za-z0-9:_-]{1,128}$"#, options: [.regularExpression]) != nil else {
                throw JiraRequestPolicyError("jira propose_issue assignee_account_id must be a Jira account id")
            }
            assignee = raw
        }
        return JiraIssueProposal(
            projectKey: projectKey,
            issueType: issueType,
            summary: summary,
            description: description,
            priority: try label(arguments["priority"], field: "priority", limit: 50, required: false),
            labels: labels,
            assigneeAccountID: assignee,
            parentKey: parentKey
        )
    }

    private static func label(_ value: Any?, field: String, limit: Int, required: Bool) throws -> String? {
        guard let cleaned = clean(value as? String) else {
            if required {
                throw JiraRequestPolicyError("jira propose_issue requires \(field)")
            }
            return nil
        }
        guard cleaned.count <= limit, !cleaned.contains("\n"), !cleaned.contains("\r") else {
            throw JiraRequestPolicyError("jira propose_issue \(field) must be a single line of up to \(limit) characters")
        }
        return cleaned
    }

    private static func labels(from value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let raw = value as? [Any] else {
            throw JiraRequestPolicyError("jira propose_issue labels must be an array of strings")
        }
        guard raw.count <= 20 else {
            throw JiraRequestPolicyError("jira propose_issue accepts at most 20 labels")
        }
        return try raw.map { element in
            // Jira silently rejects a label containing a space, so a
            // space-separated string here is a list the user would review and
            // not get. Reject it and say why.
            guard let label = clean(element as? String),
                  label.range(of: #"^[A-Za-z0-9_.:-]{1,255}$"#, options: [.regularExpression]) != nil else {
                throw JiraRequestPolicyError(
                    "jira propose_issue labels must each be a single word of letters, digits, or _.:- characters"
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

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidIssueKey(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Z][A-Z0-9_]+-[1-9][0-9]*$"#,
            options: [.regularExpression]
        ) != nil
    }
}

struct JiraRequestPolicyError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// Composes and stages a `create_issue` payload. Reaches no network.
///
/// The operation the agent calls is named for what this process does —
/// propose — and the staged envelope is named for what the app will do,
/// `create_issue`. They are kept distinct because the agent's grant covers the
/// first and only the user's approval covers the second, and a single name for
/// both is how that distinction gets lost.
enum JiraIssueProposalPolicy {
    static let serviceType = "jira"
    static let operation = "propose_issue"

    /// What the app is being asked to do, which is not what the agent did.
    static let stagedOperation = "create_issue"

    static func stage(
        arguments: [String: Any],
        connector: HostControlConnector,
        configuration: HostControlToolConfiguration,
        diagnostics: HostControlToolDiagnosticsRecorder?
    ) -> MCPServerReply {
        let proposal: JiraIssueProposal
        do {
            proposal = try JiraRequestPolicy.issueProposal(arguments: arguments)
        } catch {
            return .error(code: -32602, message: error.localizedDescription)
        }

        let staged: ConnectorMutationStaging.StagedConnectorMutation
        do {
            staged = try ConnectorMutationStaging.stage(
                serviceType: serviceType,
                operation: stagedOperation,
                connector: connector,
                target: proposal.target,
                summary: proposal.summary,
                requestMethod: proposal.requestMethod,
                requestPath: proposal.requestPath,
                body: proposal.body,
                configuration: configuration
            )
        } catch {
            // No inline fallback and no send. Failing to stage is not a reason
            // to do the write here instead.
            return .result([
                "content": [[
                    "type": "text",
                    "text": "Jira proposal could not be staged: \(error.localizedDescription)"
                ]],
                "isError": true
            ])
        }

        diagnostics?.record(
            toolName: "jira",
            summary: "jira \(operation) \(proposal.target) staged \(staged.digest)",
            result: nil
        )
        return .result([
            "content": [[
                "type": "text",
                "text": formatted(staged, proposal: proposal, configuration: configuration)
            ]],
            "isError": false
        ])
    }

    private static func formatted(
        _ staged: ConnectorMutationStaging.StagedConnectorMutation,
        proposal: JiraIssueProposal,
        configuration: HostControlToolConfiguration
    ) -> String {
        var lines = [
            "staged_operation: \(stagedOperation)",
            "target: \(staged.target)",
            "summary: \(configuration.redacted(proposal.summary, includingSecretFragments: false))",
            "description_bytes: \(proposal.description?.utf8.count ?? 0)"
        ]
        if !proposal.labels.isEmpty {
            lines.append("labels: \(proposal.labels.joined(separator: ", "))")
        }
        let note = """
            note: nothing was sent. ASTRA will ask the user to review this exact payload and, if \
            they approve, will post it using the connector credential. Read the staged file if you \
            need to check what you composed. Do not retry this call and do not attempt the write \
            another way — a second proposal is a second thing for the user to approve, not a \
            faster one.
            """
        lines.append("staged_path: \(staged.path)")
        lines.append("request_digest: \(staged.digest)")
        lines.append("sent: false")
        lines.append(note)
        return lines.joined(separator: "\n")
    }
}
