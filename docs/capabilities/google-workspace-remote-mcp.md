# Google Workspace Remote MCP Backend

This document records ASTRA's registry contract for Google's official remote
Google Workspace MCP servers as of June 27, 2026. The implementation in this PR
intentionally does not project Google's remote URLs directly into provider MCP
configuration. ASTRA must route through its OAuth-aware local gateway so token
lookup, refresh, policy checks, and failure reporting stay owned by ASTRA.

## Official Servers

Google documents the Gmail, Drive, and Calendar MCP servers as Developer Preview
features. Each page instructs clients to use HTTP transport and OAuth 2.0.

| Product | Official server URL | Required APIs | Registered ASTRA server id |
| --- | --- | --- | --- |
| Gmail | `https://gmailmcp.googleapis.com/mcp/v1` | Gmail API, Gmail MCP API | `google_workspace_gmail` |
| Google Drive | `https://drivemcp.googleapis.com/mcp/v1` | Google Drive API, Google Drive MCP API | `google_workspace_drive` |
| Google Calendar | `https://calendarmcp.googleapis.com/mcp/v1` | Google Calendar API, Google Calendar MCP API | `google_workspace_calendar` |

Sources:

- Gmail: https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server
- Drive: https://developers.google.com/workspace/drive/api/guides/configure-mcp-server
- Calendar: https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server
- Safety/tiering context: https://developers.google.com/workspace/tools-safety

## Registry Scope

`GoogleWorkspaceRemoteMCPRegistry` records:

- Product metadata for Gmail, Drive, and Calendar.
- Official upstream endpoint URLs.
- Required OAuth scopes currently needed by ASTRA's first supported tool set.
- Google-documented tool names.
- Tool-family mappings used by policy enforcement.
- Developer Preview caveats.

The registry is not a runtime MCP manifest. Runtime providers should never see
Google's upstream URL directly. They should receive only the ASTRA local gateway
URL once the gateway/vault/policy stack is available.

## Route Planning

`GoogleWorkspaceRemoteMCPBackendPlanner` builds a route plan only when all
required dependencies are present:

- ASTRA OAuth vault is available.
- ASTRA local MCP gateway is available.
- ASTRA MCP tool policy enforcer is available.
- The selected Google MCP service is available.
- A Google account is selected.
- The account has every required scope for the product.
- The OAuth vault returns a usable access token.
- The policy decision allows the requested tool.

The route plan contains the local gateway URL, upstream Google URL, injected
`Authorization: Bearer ...` header value, required scopes, account id, and tool
family. This is deliberately a pure plan for testability; the actual gateway
transport belongs to the PR 3 gateway implementation.

## Failure States

The planner fails closed with explicit states for:

- Missing OAuth vault.
- Missing local gateway.
- Missing policy enforcer.
- Unavailable Google MCP service.
- Missing account.
- Missing scope.
- Token refresh failure.
- Policy denial.
- Unsupported product.
- Unsupported tool.

Default tests use fake access tokens and fake remote MCP response bodies only.
No live Google calls should run in the default test suite.

## Dependency Blockers

The requested PR depends on prior OAuth vault, gateway skeleton, and policy
enforcement interfaces. In this checkout, branches named
`alvaro/google-oauth-vault`, `alvaro/google-mcp-contracts`, and
`alvaro/mcp-tool-policy-audit` exist only at `main` and contain no additional
interfaces. Because of that, this PR prepares the registry and route-planning
contract, but does not create a parallel OAuth vault, gateway, or policy
implementation.

When those dependencies land, the next integration should:

1. Replace the planner dependency flags with the real OAuth vault, local gateway,
   and policy interfaces.
2. Register local gateway routes for the product ids in
   `GoogleWorkspaceRemoteMCPRegistry`.
3. Resolve tokens only through the ASTRA-owned vault.
4. Inject tokens at the gateway boundary, never in provider MCP config files.
5. Forward policy-approved calls to the official Google upstream URL.
6. Keep fake-transport tests as the default and add opt-in live-provider smoke
   tests separately.
