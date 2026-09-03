import Foundation

enum HostControlPlanePromptGuidance {
    /// Appended wherever the routing contract is stated, because "use the host
    /// tool" is only half the instruction. An agent that finds no write
    /// operation concludes the tool is the wrong route and goes looking for a
    /// right one, and the right one it finds is a shell command with an
    /// exported API token. Naming the propose-and-review path — and naming the
    /// dead end as a dead end — is what stops that.
    static let mutationUnderReviewContract = """
    Writes through host control-plane connectors are staged, not sent. Where a typed operation exists to propose a change — `propose_issue` on `mcp__astra_host__jira` is the one that exists today — call it, report that the proposal is staged for the user's review, and stop. A reply saying nothing was sent is the operation succeeding. ASTRA performs the write itself, after the user reads the exact payload, using a credential you are never given. Do not retry a staged proposal, do not stage the same change twice hoping the second one sends, and never substitute a script, curl command, or written instructions that would have someone run the write with an API token — moving a credential out of ASTRA and into a shell is worse than the change not happening. If no propose operation exists for what you were asked to change, say the change cannot be made through ASTRA and stop.
    """

    static let dockerRoutingContract = """
    Routing contract: provider reasoning runs on host macOS, workspace shell commands run in Docker, and host control-plane actions such as GitHub PR metadata, Jira, read-only Google Cloud checks, SSH, browser, and Keychain access must use ASTRA-exposed host capabilities when available. Use `mcp__astra_host__github`, `mcp__astra_host__gcloud`, `mcp__astra_host__ssh`, or `mcp__astra_host__jira` for host control-plane work; GitHub Copilot CLI may display these as `astra_host-github`, `astra_host-gcloud`, `astra_host-ssh`, and `astra_host-jira`. Use `mcp__astra_host__bq` only for bq help/version metadata; GitHub Copilot CLI may display it as `astra_host-bq`. BigQuery data access is not available through host-control; use an explicitly approved BigQuery capability, or report BigQuery data access as unavailable if no such capability is present. Do not ask a subagent to "run locally" or to use native host Bash to escape this routing; subagents must use the same Docker workspace MCP tools for project commands and ASTRA host-control MCP tools for host services. If a host control-plane capability is missing, report that capability as missing instead of trying to run a host CLI from the Docker workspace.
    """

    static let dockerConnectorAPIGuidance = """
    IMPORTANT: This task is routed through a Docker workspace executor. Do not use native host Bash or Docker workspace_shell for host connector APIs. For Jira, use `mcp__astra_host__jira` (or Copilot's `astra_host-jira`) with the projected ASTRA_CONNECTORS credentials. For read-only Google Cloud host control-plane checks, use `mcp__astra_host__gcloud` (or Copilot's `astra_host-gcloud`). Use `mcp__astra_host__bq` only for bq help/version metadata. BigQuery data access is not available through host-control; use an explicitly approved BigQuery capability, or report BigQuery data access as unavailable if no such capability is present. Use workspace_shell only for project commands that belong inside the container image. WebFetch cannot handle SSO, session cookies, or token-based auth headers.
    """
}
