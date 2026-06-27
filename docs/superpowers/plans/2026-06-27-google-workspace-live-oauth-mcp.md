# Google Workspace Live OAuth MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the live Google Workspace path so ASTRA can sign in to Google, store/refresh tokens in Keychain, route provider MCP calls through ASTRA's local gateway, forward approved calls to Google's remote MCP servers, and run opt-in live smoke tests.

**Architecture:** Keep the robust invariant already established by the merged PR stack: providers connect only to ASTRA's local MCP gateway; Google tokens stay in ASTRA's Keychain-backed vault; generated apps use stable ASTRA contracts and never see raw Google MCP tools or OAuth credentials. Replace the current fake/planner-only seams with production services behind the same tested interfaces.

**Tech Stack:** SwiftPM macOS app, SwiftUI/AppKit, `ASWebAuthenticationSession` or loopback PKCE OAuth, Keychain-backed `SecretStore`, `URLSession`, existing `MCPGatewaySupport`, ASTRA capability policy, Swift Testing.

---

## Current Gap

The unified branch includes the foundation, but not live Google execution:

- `GoogleOAuthTokenService` can exchange an authorization code, but no UI/session obtains a real Google authorization code.
- `GoogleOAuthCredentialVault` stores tokens, but no production Google token HTTP client exists.
- `LocalMCPGateway` can forward through a `RemoteMCPClient`, but the CLI currently uses `UnconfiguredRemoteMCPClient`.
- `GoogleWorkspaceRemoteMCPBackendPlanner` validates fake dependency flags and fake tokens, but is not wired to the real vault, policy engine, gateway lifecycle, or remote MCP transport.
- Default tests use fake tokens and fake remote MCP bodies only.

The fix is not another fake adapter. The fix is to connect the already-created seams to real OAuth, real gateway transport, real policy composition, and explicit live smoke gates.

## File Structure

- `Astra/Services/GoogleWorkspace/GoogleOAuthAuthorizationSession.swift`
  - Builds authorization URLs with PKCE, launches user auth, validates callback state, and returns authorization code data.
- `Astra/Services/GoogleWorkspace/GoogleOAuthPKCE.swift`
  - Pure PKCE verifier/challenge/state generator and validator.
- `Astra/Services/GoogleWorkspace/GoogleOAuthHTTPTokenClient.swift`
  - URLSession-backed token exchange/refresh client for Google's OAuth token endpoint.
- `Astra/Services/GoogleWorkspace/GoogleOAuthAccountService.swift`
  - Coordinates authorization session, token service, profile creation/update, scope upgrades, refresh, and revoke.
- `Astra/Services/GoogleWorkspace/GoogleOAuthConfiguration.swift`
  - Loads client id, redirect URI, and allowed scopes from app configuration or environment in tests.
- `Tools/MCPGatewaySupport/RemoteMCPHTTPClient.swift`
  - URLSession-backed JSON-RPC client for Google's remote MCP HTTP endpoint.
- `Tools/MCPGatewaySupport/GoogleWorkspaceGatewayAuthProvider.swift`
  - Gateway-side token provider that resolves the selected account and obtains an access token without exposing it to provider config.
- `Astra/Services/Capabilities/GoogleWorkspaceRemoteMCPRuntimeService.swift`
  - Replaces dependency-flag planning with real composition of vault, gateway, policy, registry, and selected account.
- `Astra/Services/Capabilities/GoogleWorkspaceCapabilityPackageFactory.swift`
  - Creates or seeds the first-class Google Workspace capability package with remote registry metadata.
- `Astra/Views/Capabilities/GoogleWorkspaceSetupPanel.swift`
  - Wire existing presentation states to real connect, upgrade, reauthorize, retry, and revoke actions.
- `Tests/GoogleOAuthPKCETests.swift`
- `Tests/GoogleOAuthHTTPTokenClientTests.swift`
- `Tests/GoogleOAuthAccountServiceTests.swift`
- `Tests/RemoteMCPHTTPClientTests.swift`
- `Tests/GoogleWorkspaceRemoteMCPRuntimeServiceTests.swift`
- `Tests/GoogleWorkspaceLiveSmokeTests.swift`
- `docs/capabilities/google-workspace-live-oauth-mcp.md`

## Phase 1: Real OAuth Configuration And PKCE

### Task 1: Add OAuth Configuration

**Files:**
- Create: `Astra/Services/GoogleWorkspace/GoogleOAuthConfiguration.swift`
- Create: `Tests/GoogleOAuthConfigurationTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests that prove configuration is explicit and fails closed:

```swift
import Foundation
import Testing
@testable import ASTRA

@Suite("Google OAuth Configuration")
struct GoogleOAuthConfigurationTests {
    @Test("configuration loads explicit client id and loopback redirect uri")
    func loadsExplicitConfiguration() throws {
        let config = try GoogleOAuthConfiguration.load(
            environment: [
                "ASTRA_GOOGLE_OAUTH_CLIENT_ID": "client.apps.googleusercontent.com",
                "ASTRA_GOOGLE_OAUTH_REDIRECT_URI": "http://127.0.0.1:48119/oauth/google/callback"
            ]
        )

        #expect(config.clientID == "client.apps.googleusercontent.com")
        #expect(config.redirectURI.absoluteString == "http://127.0.0.1:48119/oauth/google/callback")
        #expect(config.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(config.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
    }

    @Test("configuration rejects missing client id")
    func rejectsMissingClientID() {
        #expect(throws: GoogleOAuthConfiguration.Error.self) {
            try GoogleOAuthConfiguration.load(environment: [
                "ASTRA_GOOGLE_OAUTH_REDIRECT_URI": "http://127.0.0.1:48119/oauth/google/callback"
            ])
        }
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
swift test --filter GoogleOAuthConfigurationTests
```

Expected: fails because `GoogleOAuthConfiguration` does not exist.

- [ ] **Step 3: Implement configuration**

Create `GoogleOAuthConfiguration` as a small value type:

```swift
import Foundation

struct GoogleOAuthConfiguration: Equatable, Sendable {
    enum Error: LocalizedError, Equatable {
        case missingClientID
        case invalidRedirectURI(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                "Google OAuth client id is not configured."
            case .invalidRedirectURI(let value):
                "Google OAuth redirect URI is invalid: \(value)"
            }
        }
    }

    var clientID: String
    var redirectURI: URL
    var authorizationEndpoint: URL
    var tokenEndpoint: URL

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let clientID = environment["ASTRA_GOOGLE_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clientID.isEmpty else { throw Error.missingClientID }
        let redirectText = environment["ASTRA_GOOGLE_OAUTH_REDIRECT_URI"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "http://127.0.0.1:48119/oauth/google/callback"
        guard let redirectURI = URL(string: redirectText),
              redirectURI.scheme == "http",
              redirectURI.host == "127.0.0.1" || redirectURI.host == "localhost" else {
            throw Error.invalidRedirectURI(redirectText)
        }
        return Self(
            clientID: clientID,
            redirectURI: redirectURI,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter GoogleOAuthConfigurationTests
```

Expected: pass.

### Task 2: Add PKCE Generator

**Files:**
- Create: `Astra/Services/GoogleWorkspace/GoogleOAuthPKCE.swift`
- Create: `Tests/GoogleOAuthPKCETests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import ASTRA

@Suite("Google OAuth PKCE")
struct GoogleOAuthPKCETests {
    @Test("challenge is URL safe and deterministic for a verifier")
    func challengeIsURLSafe() throws {
        let verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        let challenge = try GoogleOAuthPKCE.challenge(for: verifier)

        #expect(challenge.range(of: "+") == nil)
        #expect(challenge.range(of: "/") == nil)
        #expect(challenge.range(of: "=") == nil)
        #expect(challenge == try GoogleOAuthPKCE.challenge(for: verifier))
    }

    @Test("authorization state validation rejects mismatches")
    func stateValidationRejectsMismatch() {
        #expect(GoogleOAuthPKCE.validate(returnedState: "abc", expectedState: "abc"))
        #expect(!GoogleOAuthPKCE.validate(returnedState: "abc", expectedState: "xyz"))
        #expect(!GoogleOAuthPKCE.validate(returnedState: "", expectedState: "xyz"))
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
swift test --filter GoogleOAuthPKCETests
```

Expected: fails because `GoogleOAuthPKCE` does not exist.

- [ ] **Step 3: Implement PKCE**

Use `CryptoKit` SHA256 and base64url encoding. Keep random generation injectable for tests if needed.

- [ ] **Step 4: Run tests**

```bash
swift test --filter GoogleOAuthPKCETests
```

Expected: pass.

## Phase 2: Live Google Token HTTP Client

### Task 3: Implement Token Endpoint Client

**Files:**
- Create: `Astra/Services/GoogleWorkspace/GoogleOAuthHTTPTokenClient.swift`
- Modify: `Astra/Services/GoogleWorkspace/GoogleOAuthTypes.swift`
- Create: `Tests/GoogleOAuthHTTPTokenClientTests.swift`

- [ ] **Step 1: Write failing tests with a fake URL protocol**

Test cases:

- authorization-code exchange posts `grant_type=authorization_code`, `code`, `client_id`, `redirect_uri`, and `code_verifier`.
- refresh posts `grant_type=refresh_token`, `refresh_token`, and `client_id`.
- returned `access_token`, optional `refresh_token`, `expires_in`, and `scope` become `GoogleOAuthTokenSet`.
- HTTP 400 `invalid_grant` becomes a stable error without logging token values.

- [ ] **Step 2: Run the failing test**

```bash
swift test --filter GoogleOAuthHTTPTokenClientTests
```

Expected: fails because `GoogleOAuthHTTPTokenClient` does not exist.

- [ ] **Step 3: Implement the client**

Implementation contract:

```swift
final class GoogleOAuthHTTPTokenClient: GoogleOAuthTokenClient {
    init(configuration: GoogleOAuthConfiguration, session: URLSession = .shared)
    func exchangeAuthorizationCode(_ request: GoogleOAuthAuthorizationCodeRequest) async throws -> GoogleOAuthTokenSet
    func refreshAccessToken(_ request: GoogleOAuthRefreshRequest) async throws -> GoogleOAuthTokenSet
}
```

Requirements:

- Use `application/x-www-form-urlencoded`.
- Never log request body or tokens.
- Parse `expires_in` relative to `Date()`.
- Normalize returned scopes through `GoogleOAuthScopeNormalizer`.
- Preserve existing refresh token when Google omits a new refresh token during refresh.

- [ ] **Step 4: Run tests**

```bash
swift test --filter GoogleOAuthHTTPTokenClientTests
```

Expected: pass.

## Phase 3: User Authorization Session And Account Service

### Task 4: Add Authorization Session Interface

**Files:**
- Create: `Astra/Services/GoogleWorkspace/GoogleOAuthAuthorizationSession.swift`
- Create: `Tests/GoogleOAuthAuthorizationSessionTests.swift`

- [ ] **Step 1: Write failing pure tests**

Test that authorization URL includes:

- `response_type=code`
- configured `client_id`
- configured `redirect_uri`
- requested scopes joined by spaces
- `access_type=offline`
- `prompt=consent` for first connection or scope upgrades
- `code_challenge`
- `code_challenge_method=S256`
- `state`

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter GoogleOAuthAuthorizationSessionTests
```

Expected: fails because the session does not exist.

- [ ] **Step 3: Implement pure URL builder plus UI adapter**

Define:

```swift
struct GoogleOAuthAuthorizationRequest: Equatable, Sendable {
    var scopes: [String]
    var promptConsent: Bool
}

struct GoogleOAuthAuthorizationResult: Equatable, Sendable {
    var code: String
    var redirectURI: String
    var codeVerifier: String
}

protocol GoogleOAuthAuthorizationSessioning {
    func authorize(_ request: GoogleOAuthAuthorizationRequest) async throws -> GoogleOAuthAuthorizationResult
}
```

Add a production adapter using `ASWebAuthenticationSession` on macOS. Keep the URL-building logic pure and tested separately.

- [ ] **Step 4: Run tests**

```bash
swift test --filter GoogleOAuthAuthorizationSessionTests
```

Expected: pass.

### Task 5: Coordinate Connect, Upgrade, Reauthorize, Revoke

**Files:**
- Create: `Astra/Services/GoogleWorkspace/GoogleOAuthAccountService.swift`
- Modify: `Astra/Views/Capabilities/GoogleWorkspaceSetupPanel.swift`
- Create: `Tests/GoogleOAuthAccountServiceTests.swift`

- [ ] **Step 1: Write failing service tests**

Cover:

- `connect(scopes:)` creates/updates a `GoogleOAuthAccountProfile`, exchanges code, saves token in vault.
- `upgrade(profile:scopes:)` requests only missing scopes but saves the merged granted scope set.
- `reauthorize(profile:)` reuses requested scopes.
- `revoke(profile:)` clears tokens and marks profile revoked.
- no token string appears in returned presentation/errors.

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter GoogleOAuthAccountServiceTests
```

Expected: fails because `GoogleOAuthAccountService` does not exist.

- [ ] **Step 3: Implement service and panel actions**

Keep SwiftUI thin:

- `GoogleWorkspaceSetupPanel` calls closures for connect/upgrade/reauthorize/retry/revoke.
- `GoogleOAuthAccountService` owns auth session + token exchange + vault + profile mutation.
- UI tests use fake service closures.

- [ ] **Step 4: Run tests**

```bash
swift test --filter 'GoogleOAuthAccountServiceTests|GoogleWorkspaceSetupPresentationTests'
```

Expected: pass.

## Phase 4: Real Remote MCP HTTP Transport

### Task 6: Implement URLSession Remote MCP Client

**Files:**
- Create: `Tools/MCPGatewaySupport/RemoteMCPHTTPClient.swift`
- Create: `Tests/RemoteMCPHTTPClientTests.swift`

- [ ] **Step 1: Write failing transport tests**

Test cases:

- `tools/list` sends a JSON-RPC request to the remote endpoint with `Authorization: Bearer ...`.
- `tools/call` forwards name and arguments as JSON-RPC.
- no auth header is sent when auth context is empty.
- non-2xx or malformed JSON returns a stable transport error.
- error messages do not include bearer token values.

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter RemoteMCPHTTPClientTests
```

Expected: fails because `RemoteMCPHTTPClient` does not exist.

- [ ] **Step 3: Implement transport**

Implementation contract:

```swift
public final class RemoteMCPHTTPClient: RemoteMCPClient {
    public init(session: URLSession = .shared)
    public func listTools(for server: RemoteMCPServerDescriptor, auth: MCPGatewayAuthContext) async throws -> [[String: Any]]
    public func callTool(_ name: String, arguments: [String: Any], for server: RemoteMCPServerDescriptor, auth: MCPGatewayAuthContext) async throws -> RemoteMCPToolResult
}
```

If the existing `RemoteMCPClient` protocol is synchronous, split the async URLSession client from a small sync test adapter or update the gateway protocol and tests in one focused commit.

- [ ] **Step 4: Run tests**

```bash
swift test --filter 'RemoteMCPHTTPClientTests|RemoteMCPGatewaySupportTests'
```

Expected: pass.

### Task 7: Wire Gateway CLI To Real Google Registry

**Files:**
- Modify: `Tools/AstraMCPGatewayTool/main.swift`
- Create: `Tools/MCPGatewaySupport/GoogleWorkspaceGatewayConfiguration.swift`
- Create: `Tools/MCPGatewaySupport/GoogleWorkspaceGatewayAuthProvider.swift`
- Create: `Tests/AstraMCPGatewayToolTests.swift`

- [ ] **Step 1: Write failing CLI configuration tests**

Test:

- `--package-id google-workspace --server-id google_workspace_gmail` resolves Gmail endpoint.
- unsupported server id fails closed with a JSON-RPC error.
- provider-facing config still contains only ASTRA gateway command/args, never Google upstream URLs or bearer tokens.

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter AstraMCPGatewayToolTests
```

Expected: fails because production gateway configuration is not wired.

- [ ] **Step 3: Implement gateway configuration**

The gateway CLI should:

- resolve server descriptor from `GoogleWorkspaceRemoteMCPRegistry`;
- load selected account id from a non-secret ASTRA config record;
- use `GoogleOAuthCredentialVault.accessToken` for that account;
- instantiate `RemoteMCPHTTPClient`;
- keep provider-visible args limited to package/server ids.

- [ ] **Step 4: Run tests**

```bash
swift test --filter 'AstraMCPGatewayToolTests|MCPRuntimeProjectionTests|RemoteMCPGatewaySupportTests'
```

Expected: pass.

## Phase 5: Real Backend Runtime Composition

### Task 8: Replace Dependency Flags With Runtime Service

**Files:**
- Create: `Astra/Services/Capabilities/GoogleWorkspaceRemoteMCPRuntimeService.swift`
- Modify: `Astra/Services/Capabilities/GoogleWorkspaceRemoteMCPBackendPlanner.swift`
- Create: `Tests/GoogleWorkspaceRemoteMCPRuntimeServiceTests.swift`

- [ ] **Step 1: Write failing runtime composition tests**

Cover:

- selected account with required scopes and valid token yields a gateway route.
- missing selected account returns `.missingAccount`.
- expired token triggers refresh through `GoogleOAuthTokenService`.
- policy denial prevents route creation before token injection.
- unsupported tools fail before any token lookup.

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter GoogleWorkspaceRemoteMCPRuntimeServiceTests
```

Expected: fails because the runtime service does not exist.

- [ ] **Step 3: Implement runtime service**

Use the existing planner as a pure inner function, but feed it real dependency values from:

- `GoogleOAuthCredentialVault`
- `GoogleOAuthTokenService`
- `MCPToolPolicyEngine`
- `GoogleWorkspaceRemoteMCPRegistry`
- selected workspace/capability/account state

- [ ] **Step 4: Run tests**

```bash
swift test --filter 'GoogleWorkspaceRemoteMCPRuntimeServiceTests|GoogleWorkspaceRemoteMCPBackendTests|MCPToolPolicyEngineTests'
```

Expected: pass.

## Phase 6: Capability Package And App Studio Production Wiring

### Task 9: Seed Google Workspace Capability Package

**Files:**
- Create: `Astra/Resources/Capabilities/google-workspace-remote-mcp.json`
- Create: `Astra/Services/Capabilities/GoogleWorkspaceCapabilityPackageFactory.swift`
- Modify: `Astra/Services/Capabilities/PluginCatalog.swift`
- Create: `Tests/GoogleWorkspaceCapabilityPackageTests.swift`

- [ ] **Step 1: Write failing package tests**

Assert:

- package is hidden/admin-gated until live smoke flag or feature flag is enabled;
- remote registry metadata exists for Gmail, Drive, Calendar;
- package declares OAuth scopes but no token values;
- package mcp server entries point to ASTRA gateway command, not Google upstream URLs.

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter GoogleWorkspaceCapabilityPackageTests
```

Expected: fails because the package does not exist.

- [ ] **Step 3: Implement package and catalog registration**

Keep risk level `restricted`, require explicit consent, and list external effects by product/tool family.

- [ ] **Step 4: Run tests**

```bash
swift test --filter 'GoogleWorkspaceCapabilityPackageTests|PluginCatalogTests|CapabilityPackageValidatorTests'
```

Expected: pass.

### Task 10: Wire App Studio Google Contracts To Runtime Service

**Files:**
- Modify: `Astra/Services/WorkspaceApps/WorkspaceAppContractRegistry.swift`
- Modify: `Astra/Services/WorkspaceApps/WorkspaceAppSourceResolver.swift`
- Modify: `Astra/Services/WorkspaceApps/WorkspaceAppCapabilityReadExecution.swift`
- Create: `Tests/WorkspaceAppGoogleWorkspaceLiveContractTests.swift`

- [ ] **Step 1: Write failing contract execution tests**

Cover:

- `gmail.thread.read` maps to Gmail `search_threads` or `get_thread` through runtime service.
- `drive.file.read` maps to Drive `read_file_content`.
- `calendar.event.read` maps to Calendar `list_events` or `get_event`.
- write contracts suspend to native approval instead of running from JS.
- generated app rows redact credential-shaped fields.

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter WorkspaceAppGoogleWorkspaceLiveContractTests
```

Expected: fails because production contract execution is not wired.

- [ ] **Step 3: Implement mapping**

Keep App Studio contract IDs stable. Raw Google MCP tool names remain inside the runtime service, not in generated app manifests.

- [ ] **Step 4: Run tests**

```bash
swift test --filter 'WorkspaceAppGoogleWorkspaceLiveContractTests|WorkspaceAppGoogleWorkspaceContractTests|WorkspaceAppDataBridgeTests'
```

Expected: pass.

## Phase 7: Opt-In Live Smoke Tests

### Task 11: Add Disabled-By-Default Live Smoke Tests

**Files:**
- Create: `Tests/GoogleWorkspaceLiveSmokeTests.swift`
- Modify: `Tests/LiveProviderTestConfiguration.swift`
- Create: `docs/capabilities/google-workspace-live-oauth-mcp.md`

- [ ] **Step 1: Write live smoke test harness**

Live tests must run only when every required variable is present:

```bash
RUN_E2E=1 \
RUN_GOOGLE_WORKSPACE_LIVE=1 \
ASTRA_GOOGLE_OAUTH_CLIENT_ID=... \
ASTRA_GOOGLE_TEST_ACCOUNT=... \
swift test --filter GoogleWorkspaceLiveSmokeTests
```

Test sequence:

- skip with a clear message when live flags are absent;
- validate OAuth config;
- verify selected account profile has required scopes;
- call Gmail `tools/list` through ASTRA gateway;
- optionally read a harmless Gmail/Drive/Calendar fixture only when fixture ids are supplied;
- never create/send/delete by default.

- [ ] **Step 2: Run default tests**

```bash
swift test --filter GoogleWorkspaceLiveSmokeTests
```

Expected: pass by skipping live execution with explicit skip message.

- [ ] **Step 3: Run focused fake-backed regression suite**

```bash
swift test --filter 'GoogleOAuth|RemoteMCP|GoogleWorkspace|WorkspaceAppGoogleWorkspace|MCPToolPolicy'
```

Expected: pass.

- [ ] **Step 4: Run optional live smoke**

Run only with a real configured Google OAuth client and test account:

```bash
RUN_E2E=1 RUN_GOOGLE_WORKSPACE_LIVE=1 swift test --filter GoogleWorkspaceLiveSmokeTests
```

Expected: either pass live read-only smoke or fail with a specific setup/scopes/API-disabled message.

## Phase 8: Verification And Release Gate

### Task 12: Final Local Verification

**Files:**
- Modify: `docs/capabilities/google-workspace-live-oauth-mcp.md`
- Modify: `docs/capabilities/google-workspace-remote-mcp.md`

- [ ] **Step 1: Run focused tests**

```bash
swift test --filter 'GoogleOAuth|RemoteMCP|GoogleWorkspace|WorkspaceAppGoogleWorkspace|MCPToolPolicy'
```

Expected: pass.

- [ ] **Step 2: Run architecture and package tests**

```bash
swift test --filter 'ArchitectureFitnessTests|PluginCatalogTests|CapabilityPackageValidatorTests|MCPRuntimeProjectionTests'
```

Expected: pass.

- [ ] **Step 3: Run whitespace and build verification**

```bash
git diff --check
./script/build_and_run.sh --verify
```

Expected: pass and launch `ASTRA Dev.app`.

- [ ] **Step 4: Manual app smoke**

In `ASTRA Dev.app`:

- open Capabilities;
- enable Google Workspace only in the dev workspace;
- connect Google test account;
- verify missing-scope and upgrade flows;
- verify Gmail/Drive/Calendar tool discovery through ASTRA gateway;
- generate or import an App Studio app that declares a Google read contract;
- confirm read contracts execute through `astra.read`;
- confirm write/destructive contracts suspend to native approval.

## Parallelization

This gap can be split into multiple PRs without becoming temporary work:

- PR A: OAuth configuration + PKCE + token HTTP client.
- PR B: authorization session + account service + setup panel actions.
- PR C: remote MCP HTTP client + gateway CLI wiring.
- PR D: real runtime composition + capability package registration.
- PR E: App Studio production contract execution.
- PR F: live smoke tests, docs, and release gate.

PR A and PR C can start in parallel because they meet at the token-provider interface. PR B depends on PR A. PR D depends on PR A, PR B, and PR C. PR E depends on PR D. PR F should be last.

## Self-Review

- Spec coverage: the plan covers real OAuth auth code acquisition, token exchange/refresh, Keychain use, gateway-to-Google transport, policy composition, capability package registration, App Studio runtime mapping, and live smoke tests.
- Placeholder scan: no intentionally blank implementation slots are left; tasks name concrete files, tests, commands, and expected behavior.
- Type consistency: new services extend the current merged contracts (`GoogleOAuthTokenService`, `GoogleOAuthCredentialVault`, `LocalMCPGateway`, `RemoteMCPClient`, `GoogleWorkspaceRemoteMCPRegistry`, `MCPToolPolicyEngine`, and App Studio contract registry).
