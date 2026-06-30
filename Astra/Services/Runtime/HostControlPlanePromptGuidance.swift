import Foundation

enum HostControlPlanePromptGuidance {
    static let dockerRoutingContract = """
    Routing contract: provider reasoning runs on host macOS, workspace shell commands run in Docker, and host control-plane actions such as GitHub PR metadata, Jira, read-only Google Cloud checks, SSH, browser, and Keychain access must use ASTRA-exposed host capabilities when available. Use `mcp__astra_host__github`, `mcp__astra_host__gcloud`, `mcp__astra_host__ssh`, or `mcp__astra_host__jira` for host control-plane work; GitHub Copilot CLI may display these as `astra_host-github`, `astra_host-gcloud`, `astra_host-ssh`, and `astra_host-jira`. Use `mcp__astra_host__bq` only for bq help/version metadata; GitHub Copilot CLI may display it as `astra_host-bq`. BigQuery data access is not available through host-control; use an explicitly approved BigQuery capability, or report BigQuery data access as unavailable if no such capability is present. Do not ask a subagent to "run locally" or to use native host Bash to escape this routing; subagents must use the same Docker workspace MCP tools for project commands and ASTRA host-control MCP tools for host services. If a host control-plane capability is missing, report that capability as missing instead of trying to run a host CLI from the Docker workspace.
    """

    static let dockerConnectorAPIGuidance = """
    IMPORTANT: This task is routed through a Docker workspace executor. Do not use native host Bash or Docker workspace_shell for host connector APIs. For Jira, use `mcp__astra_host__jira` (or Copilot's `astra_host-jira`) with the projected ASTRA_CONNECTORS credentials. For read-only Google Cloud host control-plane checks, use `mcp__astra_host__gcloud` (or Copilot's `astra_host-gcloud`). Use `mcp__astra_host__bq` only for bq help/version metadata. BigQuery data access is not available through host-control; use an explicitly approved BigQuery capability, or report BigQuery data access as unavailable if no such capability is present. Use workspace_shell only for project commands that belong inside the container image. WebFetch cannot handle SSO, session cookies, or token-based auth headers.
    """
}
