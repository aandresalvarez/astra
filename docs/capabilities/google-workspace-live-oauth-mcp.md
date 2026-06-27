# Google Workspace Live OAuth MCP

ASTRA's robust Google Workspace path is intentionally ASTRA-owned end to end:

- OAuth uses an explicit Google client id, loopback redirect URI, and PKCE.
- Access and refresh tokens are stored through `GoogleOAuthCredentialVault`, not in app manifests or provider MCP config.
- Provider runtimes see a local stdio MCP gateway command. The gateway forwards approved JSON-RPC calls to Google's remote MCP HTTP endpoint.
- Policy, tool-family classification, scope checks, and token refresh happen before a remote call is routed.

## Local Configuration

Set the Google OAuth client configuration before trying a real sign-in:

```bash
export ASTRA_GOOGLE_OAUTH_CLIENT_ID="<client>.apps.googleusercontent.com"
export ASTRA_GOOGLE_OAUTH_REDIRECT_URI="http://127.0.0.1:48119/oauth/google/callback"
```

The redirect URI must be loopback HTTP. Production code fails closed when the client id is missing or the redirect URI is not local.

## Deterministic Verification

Run the focused non-live suite:

```bash
swift test --filter 'GoogleOAuthAccountServiceTests|RemoteMCPHTTPClientTests|GoogleWorkspaceRemoteMCPRuntimeServiceTests|GoogleOAuthConfigurationTests|GoogleOAuthPKCETests|GoogleOAuthHTTPTokenClientTests|RemoteMCPGatewaySupportTests|MCPRuntimeProjectionTests'
```

This validates PKCE, token exchange, account profile persistence, token redaction, gateway projection, remote MCP JSON-RPC transport, policy-first routing, and refresh-before-route behavior with fake transports.

## Opt-In Live Smoke

Live Google calls are opt-in because they require a real Google account, an OAuth client, enabled Google Workspace MCP/APIs, and a short-lived access token with the required scopes.

```bash
export RUN_GOOGLE_WORKSPACE_LIVE_SMOKE=1
export ASTRA_GOOGLE_OAUTH_CLIENT_ID="<client>.apps.googleusercontent.com"
export ASTRA_GOOGLE_WORKSPACE_LIVE_ACCESS_TOKEN="<short-lived access token>"
swift test --filter GoogleWorkspaceLiveSmokeTests
```

Do not commit or paste the live access token. The smoke test only checks `tools/list` against the Gmail MCP endpoint and asserts the response does not echo the token.
