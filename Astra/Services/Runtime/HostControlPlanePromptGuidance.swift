import Foundation

enum HostControlPlanePromptGuidance {
    /// Appended wherever the routing contract is stated, because "use the host
    /// tool" is only half the instruction. An agent that finds no write
    /// operation concludes the tool is the wrong route and goes looking for a
    /// right one, and the right one it finds is a shell command with an
    /// exported API token. Naming the propose-and-review path — and naming the
    /// dead end as a dead end — is what stops that.
    ///
    /// It also has to say that a request to *send* is a request to *propose*.
    /// A user who writes "can you send the answer using Jira?" is asking for the
    /// outcome, and an agent that reads "send" literally finds it has no send
    /// operation and reports the change cannot be made.
    ///
    /// And it has to name the route the run actually has. This used to describe
    /// only the MCP spelling, so a CLI-relay run was told to call a tool it was
    /// never given, could not find another way, and reported the change
    /// impossible. Stating the wrong transport is the same failure as stating
    /// none, so each run is told about exactly one.
    static func mutationUnderReviewContract(usesHostControlCLIRelay: Bool) -> String {
        let transport = usesHostControlCLIRelay
            ? """
            On Jira the proposals are `propose-issue` (a new ticket), `propose-comment` (a comment on an existing ticket; say whether it is `public` or `internal`), `propose-update` (edit an existing ticket's fields), and `propose-transition` (move a ticket to another status; run `get-transitions` first for the ids). Write the proposal's fields as a JSON object to a `.json` file in the task output folder — the same field names the MCP tool takes, such as `issue_key`, `comment` and `visibility` — and pass only its name with `--arguments-file`, exactly as the Jira runtime example for writes shows.
            """
            : """
            On Jira the proposals are `propose_issue` (a new ticket), `propose_comment` (a comment on an existing ticket; say whether it is `public` or `internal`), `propose_update` (edit an existing ticket's fields), and `propose_transition` (move a ticket to another status; read `get_transitions` first for the ids). Call them on `mcp__astra_host__jira` and pass the fields as arguments.
            """
        return """
        Writes through host control-plane connectors are staged, not sent. Where a typed operation exists to propose a change, call it, report that the proposal is staged for the user's review, and stop. When the user asks you to file, send, reply, comment, update, or move something, that is a request to propose it: stage it and say it is waiting for their review. \(transport) A reply saying nothing was sent is the operation succeeding. ASTRA performs the write itself, after the user reads the exact payload and decides to send it, using a credential you are never given. Do not retry a staged proposal, do not stage the same change twice hoping the second one sends, and never substitute a script, curl command, or written instructions that would have someone run the write with an API token — moving a credential out of ASTRA and into a shell is worse than the change not happening. If no propose operation exists for what you were asked to change, say the change cannot be made through ASTRA and stop.
        """
    }

    static let dockerRoutingContract = """
    Routing contract: provider reasoning runs on host macOS, workspace shell commands run in Docker, and host control-plane actions such as GitHub PR metadata, Jira, read-only Google Cloud checks, SSH, browser, and Keychain access must use ASTRA-exposed host capabilities when available. Use `mcp__astra_host__github`, `mcp__astra_host__gcloud`, `mcp__astra_host__ssh`, or `mcp__astra_host__jira` for host control-plane work; GitHub Copilot CLI may display these as `astra_host-github`, `astra_host-gcloud`, `astra_host-ssh`, and `astra_host-jira`. Use `mcp__astra_host__bq` only for bq help/version metadata; GitHub Copilot CLI may display it as `astra_host-bq`. BigQuery data access is not available through host-control; use an explicitly approved BigQuery capability, or report BigQuery data access as unavailable if no such capability is present. Do not ask a subagent to "run locally" or to use native host Bash to escape this routing; subagents must use the same Docker workspace MCP tools for project commands and ASTRA host-control MCP tools for host services. If a host control-plane capability is missing, report that capability as missing instead of trying to run a host CLI from the Docker workspace.
    """

    static let dockerConnectorAPIGuidance = """
    IMPORTANT: This task is routed through a Docker workspace executor. Do not use native host Bash or Docker workspace_shell for host connector APIs. For Jira, use `mcp__astra_host__jira` (or Copilot's `astra_host-jira`) with the projected ASTRA_CONNECTORS credentials. For read-only Google Cloud host control-plane checks, use `mcp__astra_host__gcloud` (or Copilot's `astra_host-gcloud`). Use `mcp__astra_host__bq` only for bq help/version metadata. BigQuery data access is not available through host-control; use an explicitly approved BigQuery capability, or report BigQuery data access as unavailable if no such capability is present. Use workspace_shell only for project commands that belong inside the container image. WebFetch cannot handle SSO, session cookies, or token-based auth headers.
    """
}
