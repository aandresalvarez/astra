# ASTRA Security Review
**Date:** 2026-06-09
**Scope:** Full repository codebase audit
**Areas covered:** Secrets handling, process execution, data persistence, network/API, policy enforcement, prompt injection, MCP/plugin interactions

---

## Executive Summary

ASTRA has a well-considered security architecture. Defense is layered: Seatbelt sandboxing wraps provider processes, a permission broker sanitizes all grants, shell commands are risk-classified before execution, credentials go through Keychain, and plugin packages must pass a validator before installation. The patterns are generally correct.

Three findings stand out as needing immediate attention: a silent failure in plugin signature generation that can produce undetectable tampered payloads, a simplistic shell tokenizer used for risk classification that can be bypassed with crafted quoting, and a gap in HTTPS enforcement that misses connectors whose credentials come from environment variables rather than declared credential keys. Everything else ranges from minor hardening opportunities to informational notes.

---

## Findings

### 🔴 CRITICAL

#### C1 — `PluginSigning.sign()` silently returns empty `Data()` on failure

**File:** `ASTRACore/PluginSigning.swift`

```swift
public static func sign(pluginJSON data: Data, privateKey: Curve25519.Signing.PrivateKey) -> Data {
    (try? privateKey.signature(for: data)) ?? Data()
}
```

When signing fails (e.g., key corruption, CryptoKit internal error), the function returns an empty byte array with no error surfaced. Any caller that does not explicitly guard for `signature.isEmpty` will silently proceed with an unsigned — and potentially tampered — plugin package. There is no propagation of the failure to the install flow.

**Recommendation:** Change the signature to `throws` and propagate the CryptoKit error. The install path should treat a missing or zero-length signature as a blocker, not as an acceptable payload.

---

### 🟠 HIGH

#### H1 — Shell risk classifier uses simplistic whitespace tokenization

**File:** `Astra/Services/Runtime/ShellCommandRiskClassifier.swift`

`shellTokens()` splits command strings on whitespace and strips quotes but does not implement a proper POSIX shell lexer. Commands that use unusual quoting, `$'...'` ANSI-C quoting, here-strings, or process substitution may be misclassified as lower-risk. The risk classifier is a gate for user-visible permission prompts and reusable grant creation — a misclassification towards lower risk means a destructive or credential-touching command could be approved without the appropriate escalation.

**Recommendation:** Either use a well-tested POSIX tokenizer library, add regression tests that cover edge cases (nested quotes, `$()`, `<()`, heredocs), or apply a conservative "unknown" fallback whenever the tokenizer encounters constructs it cannot confidently parse.

#### H2 — `ConnectorSecurityPolicy` HTTPS check bypassed for env-var credentials

**File:** `Astra/Services/Runtime/SecurityPolicies.swift`

```swift
private static func requiresProtectedTransport(authMethod: String, credentialKeys: [String]) -> Bool {
    !credentialKeys.isEmpty
}
```

The HTTPS requirement is gated solely on `credentialKeys`. A connector that declares `authMethod = "bearer"` (or any auth method) but sources its token from an environment variable injected at runtime will have an empty `credentialKeys` array and silently pass this check over plain HTTP. The credential is just as sensitive regardless of where it originates.

**Recommendation:** Require HTTPS (or loopback HTTP) for any connector where `authMethod` is not `"none"`, independent of `credentialKeys`. The current logic should be: `authMethod != "none" || !credentialKeys.isEmpty`.

#### H3 — `wildcardMatch()` compiles a fresh `NSRegularExpression` per call (no caching)

**File:** `Astra/Services/Runtime/AgentRuntimePolicyGuard.swift`

Every tool-call policy evaluation compiles a new `NSRegularExpression` from a pattern string. If shell patterns in `allowedTools` / `deniedTools` are ever sourced from a plugin or user input, a pathological pattern can cause catastrophic backtracking (ReDoS), stalling the policy guard — which acts as a security gate. Even without adversarial input, the repeated compilation is wasteful in hot paths.

**Recommendation:** Cache compiled patterns (keyed by pattern string) with a simple dictionary. Add a timeout or complexity limit on regex compilation when patterns originate from external sources.

---

### 🟡 MEDIUM

#### M1 — Keychain items use `kSecAttrAccessibleWhenUnlocked` instead of `...ThisDeviceOnly`

**Files:** `Astra/Services/Persistence/KeychainService.swift`, `KeychainSecretStore.swift`

`kSecAttrAccessibleWhenUnlocked` allows keychain items to be included in encrypted iCloud Keychain backups and to migrate to a new device via device-to-device transfer. For connector credentials (API keys, OAuth tokens) that are scoped to organizational infrastructure, this may not be intended behaviour.

**Recommendation:** Evaluate whether `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is more appropriate for connector credentials. If cross-device sync is desired, the current setting is correct but should be a documented, explicit choice.

#### M2 — Redaction minimum length of 4 chars may miss short tokens

**Files:** `Astra/Services/Runtime/AgentSensitiveRedactions.swift`, `Astra/Services/Persistence/SessionHistoryManager.swift`

Both the runtime redaction pass and the session-history redaction filter out secrets shorter than 4 characters. Some internal tokens, short PIN-style credentials, or partial keys may be shorter. Additionally, the `SessionHistoryManager` regex patterns cover `sk-*`, `Authorization: Bearer`, and `api_key=...` but do not cover common formats like GitHub PATs (`ghp_...`, `github_pat_...`), AWS access keys (`AKIA...`), or Anthropic API keys (`sk-ant-...`).

**Recommendation:** Add regex patterns for the common credential formats your connectors actually use. Consider lowering the minimum length guard to 2 or removing it entirely (single-character redaction is harmless noise).

#### M3 — `copy` isolation strategy places workspace copy in parent directory without access controls

**File:** `Astra/Services/Runtime/IsolationService.swift`

```swift
let copyName = "\(originalName)-astra-\(taskId.uuidString.prefix(8).lowercased())"
let copyPath = parentDir.appendingPathComponent(copyName).path
```

The copy is placed as a sibling of the original workspace, named with a short (8-char) task ID suffix. Any other process with read access to the parent directory can access the full workspace copy, including any sensitive config files in the repo. The copy is not removed automatically on task completion (the audit log notes `copy_retained: true`).

**Recommendation:** Place copies in a dedicated, permission-restricted scratch area (e.g., under the app's container or `/tmp` within a sandboxed scope). Delete copies promptly after the task completes unless explicitly retained by the user.

#### M4 — Plan JSON injected verbatim into agent prompt

**File:** `Astra/Services/Runtime/AgentPromptBuilder.swift` (around line 2195)

```swift
parts.append("Approved plan JSON:\n\(TaskPlanService.encodePlanPayload(plan))")
```

The full plan payload JSON — including `userRequest` and step titles — is embedded into the provider system prompt. If a plan step title or user request contains prompt-injection text (e.g., "Ignore previous instructions and..."), it will appear directly in the instruction stream sent to the underlying LLM. There is no sanitisation of plan content before prompt injection.

**Recommendation:** Strip or escape any content in plan fields that could be mistaken for instructions. At minimum, wrap injected user-controlled strings in a clearly-delimited block so the model can distinguish plan data from instructions.

#### M5 — Workspace memories are included verbatim in the agent prompt without sanitization

**File:** `Astra/Services/Runtime/AgentPromptBuilder.swift` (`workspaceMemoriesBlock`)

Workspace memories are user-controlled text stored over time and retrieved by relevance score. They are injected directly as prompt lines (`- <memory text>`). A memory entry created from malicious user input or a compromised workspace could include prompt-injection instructions that persist across sessions.

**Recommendation:** Treat workspace memories as untrusted data in the prompt. Consider prefixing all memory lines with a consistent structural delimiter and instructing the model (in the system prompt) to treat that section as data-only.

---

### 🔵 LOW / INFORMATIONAL

#### L1 — `BrowserBridgeServer` uses HTTP (no TLS) on loopback

**File:** `Astra/Services/Browser/BrowserBridgeServer.swift`

The bridge server binds exclusively to `127.0.0.1` and uses a 256-bit random token for authentication. On a standard macOS system, loopback-only HTTP without TLS is an accepted risk — no network interface is exposed. This is acceptable, but worth noting: any local process running as the same user can attempt to enumerate the port and brute-force the token (the token is two concatenated UUIDs, making brute-force impractical).

**No action required** unless the threat model expands beyond single-user workstations.

#### L2 — `isLoopbackHost()` accepts any `.localhost` suffix

**Files:** `SecurityPolicies.swift`, `CapabilityPackageValidator.swift`, `ConnectorPreflightService.swift`

`host.hasSuffix(".localhost")` is intentionally broad (e.g., `evil.localhost` resolves on macOS). The DNS rebinding risk is minimal because remote MCP HTTP and connector HTTP policies still require loopback IPs or the literal string `localhost`. The suffix check is consistent across all three call sites.

**No action required.**

#### L3 — Git branch creation uses `workspacePath` as lock key, not canonical path

**File:** `Astra/Services/Runtime/IsolationService.swift`

`WorkspaceLockManager` keys locks by the raw `path` string. If the same repository is referred to by two different path strings (symlink vs. real path), concurrent git operations could interleave. This is a theoretical TOCTOU risk rather than a practical exploit.

**Recommendation:** Normalise the path (`URL(fileURLWithPath:).standardizedFileURL.path`) before using it as the lock key.

#### L4 — Package ID validation allows filesystem-unsafe constructs via case collision

**File:** `Astra/Services/Capabilities/CapabilityPackageValidator.swift`

`isValidPackageIDLiteral` enforces ASCII alphanumerics plus `.`, `-`, `_`. The downstream `safeFileName` function produces the final filename. The validator checks for filename collision against installed packages, but the collision check is case-sensitive (`$0.id == package.id`) while filesystems on macOS are case-insensitive by default. A new package with ID `MyPkg` could silently overwrite an installed package with ID `mypkg` if `allowReplacingExistingPackageID` is true.

**Recommendation:** Normalise package IDs to lowercase before collision checks, or use case-insensitive comparison.

#### L5 — No rate-limiting on `BrowserBridgeServer` request handler

**File:** `Astra/Services/Browser/BrowserBridgeServer.swift`

The 1 MB request-body limit is present, but there is no limit on request rate from localhost. A malfunctioning or compromised browser extension could flood the bridge. This is a local DoS only, not a security boundary breach.

**Recommendation:** Add a simple token bucket or per-connection rate limit.

---

## Positive Findings (Security Controls Working Well)

The following controls are correctly implemented and worth preserving:

- **No hardcoded secrets** found anywhere in the codebase. All credentials flow through Keychain.
- **Seatbelt sandboxing** (`ExecutionSandbox`) is fail-closed under strict enforcement; autonomous tasks auto-escalate to strict. Path injection into SBPL profiles is prevented by `(param "ROOT_N")` references.
- **Shell script generation** in `AgentRuntimeProcessRunner` uses correct single-quote escaping (`shellSingleQuoted`) and validates for embedded newlines before injection.
- **`PermissionBroker`** explicitly blocks `bash`, `shell`, and broad-wildcard grant names, and strips metacharacters from all grant strings.
- **`PathValidator.validate(_:withinRoot:)`** resolves symlinks before checking containment, preventing symlink escape from workspace roots.
- **Broad workspace root guard** in `ExecutionSandbox` prevents `/`, `/Users`, `/System`, `/Library`, `/Applications`, `/var`, `/tmp`, `/etc` from being used as writable seatbelt roots.
- **Plugin package governance** is hard-reset to `draft / adminOnly / requiresAdminApproval` on every local import, regardless of what the JSON declares.
- **MCP server transport validation** in `CapabilityPackageValidator` requires HTTPS for remote MCP URLs, with an explicit localhost HTTP carve-out.
- **Audit logging** via `AppLogger.audit` is pervasive — keychain access, capability install/enable/fail, isolation events, and git operations are all logged.
- **Browser bridge token** is 256-bit random (two UUIDs) with constant-time-adjacent header validation, loopback-only binding.
- **Connector runtime projection** (`ConnectorRuntimeProjection`) injects credentials as environment variable *names* (`$ENV_KEY`), not raw values, into agent prompts.

---

## Recommended Priority Order

1. **C1** — Fix `PluginSigning.sign()` to throw instead of silently returning empty data. Blocker for supply-chain integrity.
2. **H2** — Expand HTTPS gate to cover all non-`none` auth methods.
3. **H1** — Add regression tests and a conservative fallback for the shell tokenizer.
4. **M4 / M5** — Add structural delimiters around user-controlled content injected into agent prompts.
5. **M3** — Move workspace copies to a sandboxed temp location with automatic cleanup.
6. **M2** — Expand redaction patterns to cover formats used by connected services.
7. **H3** — Cache compiled regexes in the policy guard.
8. **M1** — Evaluate `ThisDeviceOnly` keychain accessibility for connector credentials.
9. **L4** — Case-insensitive package ID collision check.
