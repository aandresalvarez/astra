import Foundation

/// The MCP definition of the `jira` host-control tool: what an agent is told it
/// can call and with which fields.
///
/// Lives beside the policies it describes rather than in the server, so adding an
/// operation is a change to one module's Jira files and the schema, the
/// validators and the shell grammar are edited in the same review.
///
/// Two names here are deliberate. The comment text is `comment`, not `body`:
/// `body` is on the runtime guard's list of keys that mean "a raw HTTP request
/// body", and this tool's contract is that the agent never supplies one — the
/// bridge owns paths, methods and payload shapes. And there is no `arguments_file`
/// property: an MCP runtime passes fields directly, and that key exists only so a
/// CLI-relay runtime can hand over text it cannot quote.
enum JiraToolSchema {
    static func definition(timeoutDescription: String) -> [String: Any] {
        let description = """
            Use typed ASTRA-projected Jira connector operations on the host. Reads return data \
            directly. Writes are proposals: propose_issue, propose_comment, propose_update and \
            propose_transition only stage a change for the user to approve — this tool never posts \
            to Jira and never exposes the credential, so do not fall back to curl or a script.
            """
        return [
            "name": "jira",
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "operation": [
                        "type": "string",
                        "description": "status, get_issue, search_jql, get_comments, get_transitions, propose_issue, propose_comment, propose_update, or propose_transition. Defaults to status."
                    ],
                    "alias": ["type": "string", "description": "Connector alias, or its id. Optional when one Jira connector is projected and required when more than one is: ASTRA refuses the call rather than choosing a tenant for you, and names the aliases in scope."],
                    "issue_key": ["type": "string", "description": "For get_issue, get_comments, get_transitions, propose_comment, propose_update and propose_transition: Jira issue key, for example ASTRA-123."],
                    "jql": ["type": "string", "description": "For search_jql: Jira Query Language expression."],
                    "max_results": ["type": "number", "description": "For search_jql and get_comments: maximum result count from 1 to 100. Defaults to 20."],
                    "start_at": ["type": "integer", "minimum": 0, "description": "For get_comments: zero-based comment offset. Defaults to 0; use next_start_at from an incomplete response to fetch the next page."],
                    "next_page_token": ["type": "string", "description": "For search_jql: opaque Jira nextPageToken returned by a previous page."],
                    "project_key": ["type": "string", "description": "For propose_issue: destination project key, for example STAR."],
                    "issue_type": ["type": "string", "description": "For propose_issue: issue type name as configured in the project, for example Bug."],
                    "summary": ["type": "string", "description": "For propose_issue and propose_update: single-line ticket title, at most 255 characters."],
                    "description": ["type": "string", "description": "For propose_issue and propose_update: ticket body as Jira wiki markup, at most 32768 characters. Jira renders it; do not send Atlassian Document Format JSON."],
                    "priority": ["type": "string", "description": "For propose_issue and propose_update: optional priority name, for example Highest."],
                    "labels": ["type": "array", "items": ["type": "string"], "description": "For propose_issue and propose_update: optional labels, at most 20. Each must be a single word without spaces. On propose_update the list replaces the ticket's whole label set."],
                    "assignee_account_id": ["type": "string", "description": "For propose_issue and propose_update: optional Jira account id to assign."],
                    "parent_key": ["type": "string", "description": "For propose_issue: optional parent issue key, for example STAR-123."],
                    "comment": ["type": "string", "description": "For propose_comment: the comment as Jira wiki markup, at most 32768 characters."],
                    "visibility": [
                        "type": "string",
                        "enum": ["public", "internal"],
                        "description": "For propose_comment, required: public is seen by everyone who can see the ticket, including the customer on a Jira Service Management ticket; internal is visible to agents only."
                    ],
                    "transition_id": ["type": "string", "description": "For propose_transition: the numeric id of the transition, taken from get_transitions."],
                    "transition_name": ["type": "string", "description": "For propose_transition: the name get_transitions gave that id, shown to the user in the review."],
                    "resolution": ["type": "string", "description": "For propose_transition: optional resolution name the transition requires, for example Done."],
                    "timeout_seconds": ["type": "number", "description": timeoutDescription]
                ],
                "additionalProperties": false
            ]
        ]
    }
}
