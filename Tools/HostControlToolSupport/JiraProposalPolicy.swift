import Foundation
import MCPServerKit

// The writes an agent may *compose* against Jira, and the single place that stages
// them. Nothing here reaches the network, and nothing here can: the staged file is
// the whole channel, and ASTRA's own review-and-send path is the only thing that
// turns one into a request.
//
// Split from `JiraHostControlPolicy.swift`, which is the read gate. The two are the
// same idiom — enumerate what is allowed, refuse the rest — and the fitness suite
// pins that only one of them ever produces a body.

/// The operation names the Jira host-control tool answers to, and the one place
/// every consumer reads them from: the broker, the `astra-host-control` argument
/// parser, and the app's shell policy for CLI-relay runtimes.
///
/// Three hand-written lists is how they stop agreeing, and here disagreement has a
/// concrete shape: an operation the broker offers that the relay policy rejects is
/// one the agent is told exists and then denied at the shell.
public enum JiraHostControlOperations {
    /// `status`, and the operations that read Jira and return the answer directly.
    public static let readOperations: Set<String> = [
        "status", "get_issue", "search_jql", "get_comments", "get_transitions"
    ]

    /// Operations that compose a write and stage it for the user's approval. None
    /// of them sends anything.
    public static let proposalOperations: Set<String> = [
        "propose_issue", "propose_comment", "propose_update", "propose_transition"
    ]

    /// Names the JSON file a proposal's fields are read from.
    ///
    /// Not part of the MCP tool's schema: an MCP runtime passes the fields as
    /// structured arguments. It exists for the CLI relay, where the alternative is
    /// a ticket body squeezed through shell quoting — which the relay's tokenizer
    /// rejects outright for anything with a newline, a `$`, or a backtick, and
    /// which mangles the rest into one line.
    public static let argumentsFileKey = "arguments_file"

    /// A bare file name, never a path. It is resolved directly under the task
    /// folder, so there is no separator for a traversal to hide in.
    public static func isValidArgumentsFileName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$"#, options: .regularExpression) != nil
    }

    /// The one definition of a well-formed issue key. The app derives an outbound
    /// route from it, so it reads this rather than restating the pattern.
    public static func isValidIssueKey(_ value: String) -> Bool {
        JiraRequestPolicy.isValidIssueKey(value)
    }
}

/// A write the agent composed and ASTRA will offer for review.
///
/// Kept separate from `JiraHTTPRequest` deliberately. That type has no body field
/// and is only ever built with `method: "GET"` — it is the shape of a read, and
/// giving it a body would quietly turn every read path into one that could write.
/// A proposal is a different thing with a different destination: it goes to a
/// file, and only the app turns it into a request.
protocol JiraStagedProposal {
    /// What the agent called.
    var operation: String { get }
    /// What ASTRA will do if the user approves — the name the app's route table
    /// knows it by. Proposing and committing are different acts by different
    /// parties, and one name for both is how they get conflated.
    var stagedOperation: String { get }
    var requestMethod: String { get }
    var requestPath: String { get }
    /// Scope, not content: where the change lands, for the approval row.
    var target: String { get }
    /// One line of content, for the dock row.
    var summary: String { get }
    var body: [String: Any] { get }
    /// What the agent is told about the proposal, beyond the fixed receipt lines.
    var replyDetails: [String] { get }
}

extension JiraIssueProposal: JiraStagedProposal {
    var operation: String { "propose_issue" }
    var stagedOperation: String { "create_issue" }

    var replyDetails: [String] {
        var lines = ["description_bytes: \(description?.utf8.count ?? 0)"]
        if !labels.isEmpty {
            lines.append("labels: \(labels.joined(separator: ", "))")
        }
        return lines
    }
}

/// A comment on an existing ticket.
///
/// Visibility is a required, explicit field and not a default, because the
/// default is the dangerous half. On a Jira Service Management ticket a comment
/// posted without the `sd.public.comment` property is a *public* one: the
/// customer receives it. A reply the agent meant as an internal note would go
/// out to a requester, so the agent has to say which it is and the review shows
/// it.
struct JiraCommentProposal: JiraStagedProposal {
    enum Visibility: String {
        case `public`
        case `internal`
    }

    var issueKey: String
    var comment: String
    var visibility: Visibility

    var operation: String { "propose_comment" }
    var stagedOperation: String { "add_comment" }
    var requestMethod: String { "POST" }

    /// REST v2, where the reads use v3, for the reason `create_issue` does: v3
    /// wants the text as Atlassian Document Format, a nested tree the agent would
    /// build subtly wrong. v2 takes wiki markup and Jira converts it, so what the
    /// user reviews is what lands on the ticket.
    var requestPath: String { "/rest/api/2/issue/\(issueKey)/comment" }

    var target: String {
        "\(issueKey) · \(visibility == .public ? "public comment" : "internal comment")"
    }

    var summary: String { Self.oneLine(comment) }

    var body: [String: Any] {
        var body: [String: Any] = ["body": comment]
        // Only an internal comment names the property. Its absence is the
        // documented meaning of "public", so a public comment carries nothing
        // Jira could reject on a project that is not a service desk.
        if visibility == .internal {
            body["properties"] = [["key": "sd.public.comment", "value": ["internal": true]]]
        }
        return body
    }

    var replyDetails: [String] {
        ["visibility: \(visibility.rawValue)", "comment_bytes: \(comment.utf8.count)"]
    }

    private static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 140 else { return collapsed }
        return String(collapsed.prefix(139)) + "…"
    }
}

/// An edit to the fields of an existing ticket.
struct JiraIssueUpdateProposal: JiraStagedProposal {
    var issueKey: String
    var newSummary: String?
    var description: String?
    var priority: String?
    /// `nil` leaves the labels alone; an array — even an empty one — replaces the
    /// whole set. Jira has no "add one" on this endpoint's `fields` map.
    var labels: [String]?
    var assigneeAccountID: String?

    var operation: String { "propose_update" }
    var stagedOperation: String { "update_issue" }
    var requestMethod: String { "PUT" }
    var requestPath: String { "/rest/api/2/issue/\(issueKey)" }

    /// In the order the review lists them.
    var changedFields: [String] {
        var names: [String] = []
        if newSummary != nil { names.append("summary") }
        if description != nil { names.append("description") }
        if priority != nil { names.append("priority") }
        if labels != nil { names.append("labels") }
        if assigneeAccountID != nil { names.append("assignee") }
        return names
    }

    var target: String { "\(issueKey) · update \(changedFields.joined(separator: ", "))" }
    var summary: String { "Update \(changedFields.joined(separator: ", ")) on \(issueKey)" }

    var body: [String: Any] {
        var fields: [String: Any] = [:]
        if let newSummary { fields["summary"] = newSummary }
        if let description { fields["description"] = description }
        if let priority { fields["priority"] = ["name": priority] }
        if let labels { fields["labels"] = labels }
        if let assigneeAccountID { fields["assignee"] = ["accountId": assigneeAccountID] }
        return ["fields": fields]
    }

    var replyDetails: [String] {
        var lines = ["changes: \(changedFields.joined(separator: ", "))"]
        if let labels {
            lines.append("labels: \(labels.isEmpty ? "(remove all)" : labels.joined(separator: ", "))")
        }
        return lines
    }
}

/// A move of an existing ticket to another status.
struct JiraTransitionProposal: JiraStagedProposal {
    var issueKey: String
    var transitionID: String
    /// What the agent says the transition is called. Unverified: the broker
    /// stages without reaching Jira, so this is the agent's description of the id
    /// and the review labels it that way.
    var transitionName: String
    var resolution: String?

    var operation: String { "propose_transition" }
    var stagedOperation: String { "transition_issue" }
    var requestMethod: String { "POST" }
    var requestPath: String { "/rest/api/2/issue/\(issueKey)/transitions" }
    var target: String { "\(issueKey) · transition \(transitionID)" }
    var summary: String { "Move \(issueKey) to “\(transitionName)” (transition \(transitionID))" }

    var body: [String: Any] {
        var body: [String: Any] = ["transition": ["id": transitionID]]
        if let resolution {
            body["fields"] = ["resolution": ["name": resolution]]
        }
        return body
    }

    var replyDetails: [String] {
        var lines = ["transition_id: \(transitionID)", "transition_name: \(transitionName)"]
        if let resolution { lines.append("resolution: \(resolution)") }
        return lines
    }
}

extension JiraRequestPolicy {
    static let commentProposalFields: Set<String> = ["issue_key", "comment", "visibility"]
    static let updateProposalFields: Set<String> = [
        "issue_key", "summary", "description", "priority", "labels", "assignee_account_id"
    ]
    static let transitionProposalFields: Set<String> = [
        "issue_key", "transition_id", "transition_name", "resolution"
    ]

    static func commentProposal(arguments: [String: Any]) throws -> JiraCommentProposal {
        let operation = "propose_comment"
        try refuseUnknownArguments(arguments, fields: commentProposalFields, operation: operation)
        let issueKey = try issueKey(
            arguments["issue_key"], field: "issue_key", operation: operation, required: true
        ) ?? ""
        let comment = try boundedText(
            arguments["comment"], field: "comment", operation: operation, required: true
        ) ?? ""
        guard let raw = try presentString(arguments["visibility"], field: "visibility", operation: operation),
              let visibility = JiraCommentProposal.Visibility(rawValue: raw.lowercased()) else {
            throw JiraRequestPolicyError(
                "jira propose_comment requires visibility: \"public\" (seen by everyone who can see the "
                    + "ticket, including the customer on a service-desk ticket) or \"internal\" (agents only)"
            )
        }
        return JiraCommentProposal(issueKey: issueKey, comment: comment, visibility: visibility)
    }

    static func updateProposal(arguments: [String: Any]) throws -> JiraIssueUpdateProposal {
        let operation = "propose_update"
        try refuseUnknownArguments(arguments, fields: updateProposalFields, operation: operation)
        let proposal = JiraIssueUpdateProposal(
            issueKey: try issueKey(
                arguments["issue_key"], field: "issue_key", operation: operation, required: true
            ) ?? "",
            newSummary: try singleLineSummary(arguments["summary"], operation: operation, required: false),
            description: try boundedText(arguments["description"], field: "description", operation: operation),
            priority: try label(
                arguments["priority"], field: "priority", limit: 50, required: false, operation: operation
            ),
            labels: try labels(from: arguments["labels"], operation: operation),
            assigneeAccountID: try assigneeAccountID(arguments["assignee_account_id"], operation: operation)
        )
        // An update that changes nothing would stage, get reviewed, be sent, and
        // report success for a request that did nothing.
        guard !proposal.changedFields.isEmpty else {
            throw JiraRequestPolicyError(
                "jira propose_update needs at least one of summary, description, priority, labels, "
                    + "assignee_account_id"
            )
        }
        return proposal
    }

    static func transitionProposal(arguments: [String: Any]) throws -> JiraTransitionProposal {
        let operation = "propose_transition"
        try refuseUnknownArguments(arguments, fields: transitionProposalFields, operation: operation)
        let issueKey = try issueKey(
            arguments["issue_key"], field: "issue_key", operation: operation, required: true
        ) ?? ""
        guard let transitionID = try presentString(
            arguments["transition_id"], field: "transition_id", operation: operation
        ),
              transitionID.range(of: #"^[0-9]{1,10}$"#, options: [.regularExpression]) != nil else {
            throw JiraRequestPolicyError(
                "jira propose_transition requires a numeric transition_id from get_transitions"
            )
        }
        let transitionName = try label(
            arguments["transition_name"], field: "transition_name", limit: 100, required: true, operation: operation
        ) ?? ""
        return JiraTransitionProposal(
            issueKey: issueKey,
            transitionID: transitionID,
            transitionName: transitionName,
            resolution: try label(
                arguments["resolution"], field: "resolution", limit: 50, required: false, operation: operation
            )
        )
    }
}

/// Composes and stages a Jira write. Reaches no network.
///
/// The operation the agent calls is named for what this process does — propose —
/// and the staged envelope is named for what the app will do: `create_issue`,
/// `add_comment`, `update_issue`, `transition_issue`. They are kept distinct
/// because the agent's grant covers the first and only the user's approval covers
/// the second.
enum JiraProposalPolicy {
    static let serviceType = "jira"

    /// Ceiling on a proposal file. A comment or description is capped at 32,768
    /// characters, which is up to 128 KiB of UTF-8, and the staged envelope has a
    /// 1 MiB limit of its own.
    static let argumentsFileByteLimit = 512 * 1024

    static func stage(
        operation: String,
        arguments: [String: Any],
        connector: HostControlConnector,
        configuration: HostControlToolConfiguration,
        diagnostics: HostControlToolDiagnosticsRecorder?
    ) -> MCPServerReply {
        let proposal: any JiraStagedProposal
        do {
            let resolved = try resolvedArguments(arguments, configuration: configuration)
            proposal = try compose(operation: operation, arguments: resolved)
        } catch {
            return .error(code: -32602, message: error.localizedDescription)
        }

        let staged: ConnectorMutationStaging.StagedConnectorMutation
        do {
            staged = try ConnectorMutationStaging.stage(
                serviceType: serviceType,
                operation: proposal.stagedOperation,
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
            summary: "jira \(proposal.operation) \(proposal.target) staged \(staged.digest)",
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

    private static func compose(
        operation: String,
        arguments: [String: Any]
    ) throws -> any JiraStagedProposal {
        switch operation {
        case "propose_issue":
            return try JiraRequestPolicy.issueProposal(arguments: arguments)
        case "propose_comment":
            return try JiraRequestPolicy.commentProposal(arguments: arguments)
        case "propose_update":
            return try JiraRequestPolicy.updateProposal(arguments: arguments)
        case "propose_transition":
            return try JiraRequestPolicy.transitionProposal(arguments: arguments)
        default:
            throw JiraRequestPolicyError("Unsupported Jira operation '\(operation)'")
        }
    }

    /// The proposal's fields, from the call itself or from the file it names.
    ///
    /// A file is all-or-nothing: naming one means the fields live there, and a
    /// call that also carries some inline is refused rather than merged, because
    /// two sources for one payload leaves the user reviewing whichever one won.
    static func resolvedArguments(
        _ arguments: [String: Any],
        configuration: HostControlToolConfiguration
    ) throws -> [String: Any] {
        let fileKey = JiraHostControlOperations.argumentsFileKey
        guard let raw = arguments[fileKey], !(raw is NSNull) else { return arguments }
        guard let name = raw as? String, JiraHostControlOperations.isValidArgumentsFileName(name) else {
            throw JiraRequestPolicyError(
                "jira \(fileKey) must be the name of a .json file in the task folder, for example jira_comment.json"
            )
        }
        let routing: Set<String> = ["operation", "alias", "timeout_seconds", fileKey]
        let inline = Set(arguments.keys).subtracting(routing).sorted()
        guard inline.isEmpty else {
            throw JiraRequestPolicyError(
                "jira \(fileKey) replaces the other arguments; move \(inline.joined(separator: ", ")) into \(name)"
            )
        }
        guard !configuration.taskFolder.isEmpty else {
            throw JiraRequestPolicyError(
                "No task folder is projected, so \(name) cannot be read where ASTRA would find it"
            )
        }
        let data = try TaskFolderContainment.readRegularFile(
            named: name,
            beneath: TaskFolderContainment.resolvedRoot(configuration.taskFolder),
            byteLimit: argumentsFileByteLimit,
            refusal: "read a proposal file",
            makeError: { JiraRequestPolicyError($0) }
        )
        // The parse error is not surfaced: it can quote the offending bytes, and
        // this is a file the agent is not the only party able to have written.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraRequestPolicyError("\(name) must hold a single JSON object of the proposal's fields")
        }
        let overlap = Set(object.keys).intersection(routing).sorted()
        guard overlap.isEmpty else {
            throw JiraRequestPolicyError(
                "\(name) must not set \(overlap.joined(separator: ", ")); those belong on the command"
            )
        }
        var merged = arguments.filter { routing.contains($0.key) && $0.key != fileKey }
        merged.merge(object) { _, fromFile in fromFile }
        return merged
    }

    private static func formatted(
        _ staged: ConnectorMutationStaging.StagedConnectorMutation,
        proposal: any JiraStagedProposal,
        configuration: HostControlToolConfiguration
    ) -> String {
        var lines = [
            "staged_operation: \(proposal.stagedOperation)",
            "target: \(staged.target)",
            "summary: \(configuration.redacted(proposal.summary, includingSecretFragments: false))"
        ]
        lines.append(contentsOf: proposal.replyDetails)
        let note = """
            note: nothing was sent. ASTRA will ask the user to review this exact payload and, if \
            they approve, will post it using the connector credential — the user decides whether \
            and when. Read the staged file if you need to check what you composed. Do not retry \
            this call and do not attempt the write another way — a second proposal is a second \
            thing for the user to approve, not a faster one.
            """
        lines.append("staged_path: \(staged.path)")
        lines.append("request_digest: \(staged.digest)")
        lines.append("sent: false")
        lines.append(note)
        return lines.joined(separator: "\n")
    }
}
