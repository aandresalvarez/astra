# Provider Policy And Observability PRD

**Status:** Draft for product and implementation review  
**Authoring date:** 2026-05-13  
**Audience:** Product, design, and engineers adding provider runtimes or security controls  
**Scope:** User-configurable agent strictness, provider-specific permission rendering, and run observability for Claude Code, GitHub Copilot CLI, and future ASTRA providers

## 1. Purpose

ASTRA lets users delegate work to local AI agents. Delegation only works when users understand two things:

1. What the agent is allowed to do.
2. What the agent actually did.

This PRD defines a provider-neutral policy and observability layer that lets users choose a strictness level in ASTRA, inspect or customize the resulting provider configuration, and review a run manifest before and after execution.

The system must support today's Claude Code and GitHub Copilot CLI integrations without hard-coding the product model to either provider. Future providers should be added by implementing a policy adapter, not by adding new policy concepts to the UI every time a provider exposes a different flag, settings file, protocol, or permission schema.

## 2. First Principles

### 2.1 The user owns the computer

ASTRA is running on the user's Mac, with access to local files, credentials, CLIs, and network identity. Any agent permission model must start from the fact that the user's machine is the asset at risk.

### 2.2 Provider permissions are implementation details

Claude Code, Copilot CLI, and future runtimes may each expose different permission controls. Those controls matter, but they should not be the primary product model. The user should choose intent in ASTRA, and ASTRA should translate that intent into provider-native configuration.

### 2.3 Visibility is a safety control

Users cannot evaluate risk if the app hides access scope, command scope, environment injection, or provider mode. A run should always expose a concise manifest of what was allowed, what was denied, and what actually happened.

### 2.4 Default behavior must be useful, not maximal

The default strictness should let ASTRA inspect, reason, and ask for approval when needed. It should not silently grant broad shell, network, credential, or write permissions.

### 2.5 Advanced users need escape hatches

Some users will want custom Claude settings, Copilot flags, enterprise managed settings, local model sandboxes, or provider-specific experiments. ASTRA should support that without forcing every user to understand provider internals.

### 2.6 ASTRA's own enforcement is stronger than provider-only enforcement

Provider-native permission systems are necessary but not sufficient for the strongest product claim. If ASTRA wants to promise that unsafe commands cannot run, it must add ASTRA-owned enforcement for the relevant surfaces, especially shell commands, file paths, network destinations, and credential access.

## 3. Problem Statement

Users are asking:

- "What is the app doing?"
- "Can it run unsafe commands?"
- "Can I make the agent stricter?"
- "Can I configure Claude/Copilot directly if I know what I am doing?"
- "Will this design work when ASTRA adds another provider?"

Today ASTRA has meaningful building blocks: restricted permission defaults, skill-level allowed/disallowed tools, provider command planning, task events, audit logs, and Sensitive Mode. The remaining product gap is that policy, provider rendering, and observability are not a single coherent user-facing system.

## 4. Goals

- Give every task a visible strictness level near the run control.
- Make `Review` the default middle-ground policy for normal task work.
- Let users choose stricter or looser ASTRA policy levels per task, workspace, and global default.
- Let users inspect the generated provider configuration before a run.
- Let advanced users customize provider-specific configuration without breaking ASTRA's canonical policy model.
- Persist a run manifest for each execution attempt.
- Keep the policy model provider-neutral so new providers can be added by implementing adapters.
- Prepare for ASTRA-owned command and path enforcement without requiring that all enforcement ship in V1.

## 5. Non-Goals

- Build a full visual policy programming language in V1.
- Guarantee OS-level sandboxing for all provider processes in V1.
- Replace Claude Code or Copilot CLI permission systems.
- Expose every provider setting in the default UI.
- Let provider-specific settings become the canonical product model.
- Solve enterprise MDM or organization-wide policy management in V1.
- Rework task scheduling, provider selection, or model availability beyond what is needed for policy display and execution.

## 6. Users And Use Cases

### 6.1 Cautious individual user

Wants ASTRA to inspect a repo, explain issues, and propose changes without running risky commands or editing files unexpectedly.

Primary need: default safety and clear "what can happen" preview.

### 6.2 Builder using ASTRA daily

Wants agents to edit files and run tests after approval, but not deploy, delete files, push branches, or access unrelated directories.

Primary need: useful middle-ground policy with one-run escalations.

### 6.3 Power user

Understands Claude or Copilot configuration and wants to tune provider-native settings directly.

Primary need: advanced provider config, diff preview, and recovery to ASTRA defaults.

### 6.4 Organization or team admin

Wants consistent defaults and auditable behavior across workspaces.

Primary need: policy presets, managed defaults, and exportable audit records. This is mostly V2, but V1 should not block it.

### 6.5 Future provider implementer

Adds a new runtime and needs to map ASTRA policies into that runtime's capabilities.

Primary need: stable adapter interface and compatibility tests.

## 7. Product Model

### 7.1 Canonical objects

ASTRA should introduce these product concepts:

| Concept | Definition |
| --- | --- |
| `AgentPolicy` | Provider-neutral ASTRA permission intent. |
| `PolicyLevel` | A named preset such as `Locked`, `Review`, `Build`, `Network`, `Autonomous`, or `Custom`. |
| `PolicyScope` | Where a policy applies: global default, workspace default, task override, one-run escalation. |
| `ProviderPolicyAdapter` | Runtime-specific renderer that maps `AgentPolicy` into provider settings, flags, env, or protocol messages. |
| `ProviderPolicyRender` | The concrete provider configuration planned for a run. |
| `RunPermissionManifest` | A persisted record of intended permissions, rendered provider config summary, paths, env keys, approvals, denials, and observed tool activity. |
| `CommandBrokerPolicy` | ASTRA-owned enforcement policy for command, path, network, and credential access. V1 may be partial. |

### 7.2 Source of truth

The source of truth should be:

```text
ASTRA AgentPolicy
  -> provider adapter render
  -> provider execution config
  -> run manifest
  -> observed events
```

Provider files and flags are generated artifacts or advanced overrides. They are not the primary source of truth.

### 7.3 Policy levels

#### Locked

For reading and planning only.

Default behavior:

- Allow file read inside workspace.
- Allow listing and search inside workspace.
- Deny file writes.
- Deny shell except provider-internal read/search tools when possible.
- Deny network except provider auth/session traffic required by the runtime.
- Deny credential injection.
- Require approval for every escalation.

#### Review

Default middle-ground policy.

Default behavior:

- Allow file read inside workspace.
- Allow repo inspection commands such as `git status`, `git diff`, and `git log`.
- Allow safe search and static analysis where the provider can express it.
- Allow planning, explanation, and proposed edits.
- Require approval before file writes.
- Require approval before general shell.
- Require approval before network access beyond approved connectors.
- Require approval before credential injection.
- Deny destructive shell patterns.

#### Build

For implementation work after the user trusts the task.

Default behavior:

- Allow file reads and scoped file writes inside workspace.
- Allow project build/test commands from a configured allowlist.
- Allow package manager inspect/install commands only if explicitly enabled.
- Deny deploy, publish, push, delete, credential export, and system mutation commands.
- Require approval for network access unless a connector grants it.

#### Network

For connector and API work.

Default behavior:

- Includes Build permissions if enabled by the workspace policy.
- Allow network calls only to approved connector domains or configured URL patterns.
- Allow credential injection only for selected connectors.
- Require approval for new domains, broad curl access, file uploads, or mutations against external systems.

#### Autonomous

For isolated or highly trusted work.

Default behavior:

- Use provider broad-permission mode only after explicit user selection.
- Require a visible high-trust warning.
- Persist a run manifest showing that broad provider permissions were used.
- Prefer an isolated workspace or disposable clone.
- Still apply ASTRA-owned hard denies where available.

#### Custom

For advanced users.

Default behavior:

- Start from a named policy level.
- Allow editing ASTRA policy details.
- Allow provider-specific overrides.
- Show warnings when custom provider config is broader than ASTRA's selected policy.
- Offer "Reset to ASTRA default" and "Show generated provider config".

## 8. UX Requirements

### 8.1 Composer policy chip

The composer should show the current policy level next to provider/model metadata.

Example:

```text
[lock icon] Review     Copilot · Sonnet · 200k     Run
```

Clicking the policy chip opens a policy sheet.

### 8.2 Policy sheet

The policy sheet should contain:

- Current policy level.
- Short explanation of what can happen without asking.
- Allowed actions.
- Ask-first actions.
- Denied actions.
- Paths in scope.
- Network scope.
- Credential scope.
- Provider-specific render summary.
- Link to advanced provider settings.

The sheet should avoid raw provider jargon in the default tab.

### 8.3 Advanced provider settings

Advanced settings should be reachable from the policy sheet and global settings.

The advanced view should show:

- Provider runtime.
- Provider version if known.
- Provider config source: generated by ASTRA, user override, managed external config, or mixed.
- Generated config preview.
- Effective provider settings summary.
- Conflicts or unsupported policy parts.
- Reset to ASTRA generated defaults.
- Open provider settings file or docs link when applicable.

### 8.4 Run preflight manifest

Before starting a run, ASTRA should be able to show:

- Provider and model.
- Policy level.
- Permission mode.
- Allowed tools.
- Denied tools.
- Allowed shell patterns.
- Denied shell patterns.
- Workspace path.
- Additional paths.
- Environment variable names, never values.
- Connector credentials that will be injected by label, never secret values.
- Network destinations allowed by policy.
- Whether provider-native enforcement, ASTRA enforcement, or both are active.

The user should not need to open logs to answer "what is this agent allowed to do?"

### 8.5 During-run observability

The task UI should show a compact live activity stream:

- Reading files.
- Searching workspace.
- Requesting permission.
- Running command.
- Editing file.
- Calling connector.
- Denied action.
- Waiting for user.
- Completed.

Raw logs remain available, but the default supervision surface should summarize meaningful activity.

### 8.6 Post-run summary

After a run, ASTRA should persist and display:

- Final status.
- Stop reason.
- Provider session ID if available.
- Tools used.
- Commands run, redacted and normalized.
- Denied commands/actions.
- Files changed.
- External domains contacted.
- Environment variable names used.
- Approvals granted.
- Whether the run exceeded its initial permission level.

## 9. Provider-Neutral Architecture

### 9.1 Policy adapter protocol

Each provider should implement a policy adapter that answers:

```swift
protocol ProviderPolicyAdapter {
    var providerID: AgentRuntimeID { get }
    var supportedFeatures: ProviderPolicyFeatures { get }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender
    func validate(render: ProviderPolicyRender, context: PolicyRenderContext) -> [PolicyDiagnostic]
    func observedEvent(from providerEvent: ProviderEvent) -> PolicyObservedEvent?
}
```

The actual type names can vary, but the boundary should stay stable:

- Input: ASTRA policy and run context.
- Output: provider config plus diagnostics.
- Runtime: provider uses the rendered config.
- Observability: provider events map back into normalized policy events.

### 9.2 Provider feature flags

Providers should declare capabilities instead of ASTRA assuming support:

- Supports allow tools.
- Supports deny tools.
- Supports ask-first mode.
- Supports file path scoping.
- Supports additional directories.
- Supports URL allowlist.
- Supports URL denylist.
- Supports secret env redaction.
- Supports generated settings file.
- Supports per-run flags.
- Supports interactive permission callbacks.
- Supports managed settings.
- Supports machine-readable event stream.

Unsupported policy requirements should produce diagnostics.

Example:

```text
Policy diagnostic:
Review requires ask-before-write, but this provider version cannot request write approval non-interactively. ASTRA will block writes through the command broker where possible and require approval before retry.
```

### 9.3 Configuration ownership

ASTRA should distinguish:

- `Generated`: ASTRA generated provider config from the selected policy.
- `UserOverride`: user edited provider-specific config.
- `ExternalManaged`: provider config is managed outside ASTRA.
- `Mixed`: ASTRA generated some settings and preserved external/user settings.

The UI should make ownership visible because it changes supportability.

### 9.4 Provider config should be rendered per run

Provider config should be planned per run so task history is reproducible.

For providers that require settings files, ASTRA may write a local generated file. The run manifest must record a summary of what was written, and ASTRA must preserve user-owned provider settings.

## 10. Initial Provider Mappings

### 10.1 Claude Code

Claude Code exposes settings files and permission controls. ASTRA should map `AgentPolicy` into Claude-native settings and CLI arguments where appropriate.

V1 Claude requirements:

- Continue supporting restricted default behavior.
- Generate or update workspace-local Claude settings without deleting unrelated user settings.
- Mark ASTRA-managed settings where possible.
- Prefer deny rules for hard blocks when Claude supports them.
- Avoid broad autonomous flags unless policy is `Autonomous` or a one-run escalation explicitly requires it.
- Persist whether broad permission flags were used.
- Detect and report conflicts between ASTRA policy and existing Claude settings.

Implementation note:

ASTRA currently writes `.claude/settings.local.json` for subagent permissions. This direction is correct, but the product should treat that file as provider render output, not the policy source of truth.

### 10.2 GitHub Copilot CLI

Copilot CLI exposes command-line policy controls and may vary by installed version. ASTRA should render policies into supported flags after capability detection.

V1 Copilot requirements:

- Use capability detection before assuming a flag exists.
- Prefer specific `--allow-tool` style grants over all-tools modes.
- Add deny rules when supported.
- Use additional directory flags only for paths included by ASTRA policy.
- Avoid all-tools modes except `Autonomous` or explicitly approved one-run escalation.
- Persist whether all-tools mode was used.
- Distinguish provider limitations from policy decisions in diagnostics.

### 10.3 Future providers

A future provider should need to add:

- Runtime descriptor.
- Policy adapter.
- Event parser or protocol bridge.
- Capability detection.
- Fixture tests for policy rendering.
- Manual verification recipe.

It should not need to add a new user-facing strictness model unless the provider introduces a fundamentally new kind of authority.

## 11. ASTRA-Owned Enforcement

### 11.1 Enforcement tiers

ASTRA should report enforcement as one of:

| Tier | Meaning |
| --- | --- |
| Provider Native | ASTRA passed policy to the provider and relies on provider enforcement. |
| ASTRA Brokered | Sensitive actions go through ASTRA-owned validation before execution. |
| OS Sandboxed | Provider process is isolated by OS-level controls. Future. |
| Mixed | Different surfaces use different enforcement tiers. |

### 11.2 Command broker direction

The strongest version of this feature replaces broad raw shell in safe modes with ASTRA-owned commands:

- Read file.
- Write file.
- List files.
- Search files.
- Git status.
- Git diff.
- Git log.
- Swift test.
- Build script.
- Connector request.
- Browser action.

Each brokered command should validate:

- executable or tool ID
- argv
- working directory
- file path scope
- environment keys
- network destination
- mutation classification
- user approval state

V1 may still use provider-native tool controls, but the PRD should not claim hard prevention until ASTRA-owned enforcement covers the relevant action.

## 12. Data Model Requirements

Add or evolve storage for:

### 12.1 Policy configuration

- global default policy level
- workspace default policy level
- task policy override
- provider-specific advanced overrides
- custom policy rules
- managed/external config state

### 12.2 Run manifest

Persist per run:

- policy level
- policy scope
- provider ID
- provider version
- model
- rendered config summary
- enforcement tiers
- allowed tool names
- denied tool names
- allowed shell patterns
- denied shell patterns
- allowed paths
- additional paths
- allowed URL patterns
- denied URL patterns
- injected env key names
- credential labels
- approvals granted
- unsupported policy diagnostics

### 12.3 Observed activity

Persist normalized policy events:

- tool used
- command planned
- command started
- command completed
- command denied
- file read
- file written
- network request
- credential used
- approval requested
- approval granted
- approval denied
- provider permission prompt
- provider policy failure

## 13. Security And Privacy Requirements

- Never log secret values.
- Never log full prompt or model output in operational logs when Sensitive Mode is enabled.
- Never use `Autonomous` as the default.
- Never silently switch from a stricter policy to a looser policy.
- Never hide that broad provider permissions were used.
- Deny rules should take precedence over allow rules in ASTRA policy.
- Provider adapters should preserve provider-specific deny precedence where supported.
- When ASTRA cannot enforce a policy part, show a diagnostic before the run or block the run if the gap is material.
- Environment variable display must show names only.
- Path display should respect Sensitive Mode while still being useful in task-level product history.

## 14. Settings Hierarchy

Policy resolution order:

1. One-run approval or escalation.
2. Task override.
3. Workspace default.
4. Global user default.
5. ASTRA built-in default.

Provider config resolution order:

1. Managed external provider config, if ASTRA detects it and the user cannot edit it.
2. User provider override.
3. ASTRA generated provider config from effective policy.
4. Provider defaults.

If provider config is broader than ASTRA policy, ASTRA should warn or block depending on severity.

## 15. Policy Conflict Semantics

Policy conflicts happen when two sources disagree about what an agent may do. ASTRA should resolve conflicts deterministically and expose the result before execution.

### 15.1 Conflict classes

| Conflict | Example | Default behavior |
| --- | --- | --- |
| ASTRA deny vs ASTRA allow | A skill allows `Bash`, but the task policy denies shell. | Deny wins. |
| ASTRA ask-first vs ASTRA allow | Workspace allows writes, but task policy says ask before writes. | Ask-first wins. |
| ASTRA policy vs provider generated config | `Review` requires ask-before-write, but the provider render grants broad write. | Block render as invalid. |
| ASTRA policy vs user provider override | User override grants all shell while task policy is `Review`. | Warn or block based on severity. |
| ASTRA policy vs managed provider config | Organization-managed provider config grants or denies capabilities differently than ASTRA. | Respect managed config, show diagnostic, block if ASTRA cannot satisfy the selected policy. |
| Provider limitation vs ASTRA policy | Provider cannot express URL allowlists. | Show unsupported-feature diagnostic and decide warn/block by risk. |
| One-run escalation vs default policy | User approves one shell command during a `Review` task. | Escalation applies only to that run and only to the approved scope. |

### 15.2 Precedence rules

ASTRA policy resolution should use these rules:

1. Explicit deny beats allow.
2. Ask-first beats allow.
3. Narrower scope beats broader scope.
4. One-run escalation beats default policy only for the approved run and approved capability.
5. Managed external provider config beats ASTRA-generated provider config, but it does not silently weaken ASTRA's user-facing policy.
6. Provider defaults are used only when ASTRA policy is silent and no user or managed config applies.

### 15.3 Warn vs block

ASTRA should block a run when:

- The provider render would grant broader shell, write, network, credential, or path access than the effective ASTRA policy.
- The selected policy depends on an enforcement feature the provider cannot express and ASTRA-owned enforcement is not available.
- Existing provider settings include broad bypass modes while the selected ASTRA policy is not `Autonomous`.
- A deny rule cannot be represented or enforced for a material risk.

ASTRA may warn and continue when:

- The unsupported policy feature is informational or low risk.
- The provider config is narrower than ASTRA policy.
- A managed provider setting blocks work more strictly than ASTRA requested.
- A user override is broader than workspace defaults but still within the explicit task policy.

### 15.4 Conflict UI

Policy sheets and preflight manifests should show conflicts as:

- `Blocked`: run cannot start until the policy, provider config, or enforcement tier changes.
- `Warning`: run can start, but the user should understand the difference.
- `Info`: provider or managed config is narrower than ASTRA requested.

Each conflict should name:

- the policy source
- the provider config source
- the affected capability
- the effective decision
- the remediation path

## 16. Default Policy

The built-in default should be `Review`.

Default `Review` should be conservative enough that a new user can trust it, but useful enough that ASTRA can inspect a workspace and prepare a plan without constant prompts.

Recommended V1 default:

- Read/search workspace: allow.
- Git status/diff/log: allow.
- File writes: ask.
- Build/test commands: ask or allow only when workspace policy opts in.
- General shell: ask.
- Network: ask unless covered by enabled connector policy.
- Credential injection: ask unless covered by enabled connector policy.
- Destructive actions: deny by default.
- Broad provider bypass modes: deny unless one-run approval or `Autonomous`.

## 17. Migration From Current Runtime Policy

ASTRA already has runtime permission concepts. The new policy layer should preserve current behavior while making the model explicit and provider-neutral.

### 17.1 Current concepts to migrate

| Current concept | Target concept |
| --- | --- |
| `PermissionPolicy.restricted` | `AgentPolicy(level: .review)` by default, with current restricted behavior as the initial provider render. |
| `PermissionPolicy.interactive` | `AgentPolicy` with ask-first behavior where the provider supports it. |
| `PermissionPolicy.autonomous` | `AgentPolicy(level: .autonomous)` or a one-run escalation. |
| `allowedTools` / `disallowedTools` | Provider-neutral allow, ask-first, and deny rules. |
| Skill-level allowed/disallowed tools | Inputs into effective workspace/task policy, with deny precedence. |
| Claude `.claude/settings.local.json` writes | Claude provider render output, not the source of truth. |
| Copilot `--allow-tool` / `--allow-all-tools` flags | Copilot provider render output, not the source of truth. |
| `runtime.command_planned` audit events | Run manifest provider-render summary plus audit event. |
| `permission.approval.requested` task events | Normalized policy approval events. |

### 17.2 Migration principles

- Existing users should keep the same effective default safety posture.
- Existing restricted tasks should appear as `Review`.
- Existing autonomous or skip-permission flows should appear as `Autonomous` or explicit one-run escalations, never as an invisible internal state.
- Existing provider-specific settings should be preserved and classified as `UserOverride`, `ExternalManaged`, or `Mixed` when possible.
- ASTRA should not delete or rewrite unrelated provider settings during migration.
- If migration cannot confidently classify an existing provider setting, mark it `Mixed` and show an advanced-settings diagnostic.

### 17.3 Phased migration plan

Phase 1 should add policy display without changing runtime behavior:

- Map current `PermissionPolicy` values into visible policy levels.
- Persist policy level on new runs.
- Include current allowed tool counts and permission policy in run manifests.
- Keep existing Claude and Copilot command construction unchanged.

Phase 2 should introduce provider adapters:

- Move Claude permission rendering behind a Claude policy adapter.
- Move Copilot permission flag rendering behind a Copilot policy adapter.
- Add adapter version to run manifests.
- Compare adapter output against current command construction in tests.

Phase 3 should migrate advanced settings:

- Detect existing Claude local settings and Copilot flag defaults.
- Preserve unrelated provider settings.
- Show ownership state in the advanced provider settings view.
- Add reset-to-generated behavior.

Phase 4 should tighten enforcement:

- Introduce ASTRA-owned command broker controls for safe modes.
- Move broad provider bypass behavior behind explicit `Autonomous` selection or one-run approval.
- Block runs where provider settings are materially broader than selected ASTRA policy and ASTRA cannot enforce the narrower policy itself.

### 17.4 Compatibility requirements

- Existing task history should remain readable.
- Existing schedules should inherit the workspace default policy unless they have an explicit runtime policy.
- Existing task templates should preserve their intended permission posture.
- Mixed-provider continuations should record the effective policy for each run independently.
- Migration should be reversible during development-channel testing.

## 18. Metrics And Diagnostics

Track locally and safely:

- policy level selected per run
- provider used per run
- count of approvals requested
- count of approvals granted or denied
- count of provider policy failures
- count of ASTRA policy denials
- count of unsupported policy diagnostics
- whether broad provider mode was used
- whether user opened advanced provider config

Do not collect secret values, prompt text, command output, or file contents as analytics.

## 19. Acceptance Criteria

### 19.1 Product

- A user can see the current policy level in the task composer before running a task.
- A user can change the policy level for a task.
- A user can set workspace and global defaults.
- A user can inspect what the selected provider will be allowed to do.
- A user can see when ASTRA is relying on provider-native enforcement only.
- A user can tell whether a completed run used broad provider permissions.
- A user can reset advanced provider settings to ASTRA-generated defaults.

### 19.2 Architecture

- Policy model is provider-neutral.
- Claude and Copilot have separate policy adapters.
- New providers can declare capabilities and render policy without changing the core strictness UI.
- Run manifests are persisted per run.
- Provider config ownership is represented.
- Unsupported policy features produce diagnostics.

### 19.3 Security

- `Review` is the built-in default.
- `Autonomous` requires explicit user selection.
- Broad provider permission flags are never used silently.
- Secret values are not written to logs or manifests.
- Deny rules override allow rules in ASTRA policy.
- Provider settings are merged without deleting unrelated user settings.

### 19.4 Testing

- Unit tests cover policy resolution order.
- Unit tests cover provider rendering for Claude.
- Unit tests cover provider rendering for Copilot.
- Unit tests cover unsupported capability diagnostics.
- Unit tests cover deny-over-allow precedence.
- Unit tests cover Sensitive Mode redaction for run manifests and logs.
- Integration or fixture tests verify generated provider config for at least one restricted run and one autonomous run per provider.

## 20. Milestones

### Milestone 1: Policy model and UI preview

- Add provider-neutral policy types.
- Add composer policy chip.
- Add policy sheet with allowed, ask-first, denied, and path scope sections.
- Add global and workspace default setting.
- Persist selected policy level on task/run.

### Milestone 2: Provider adapters

- Add Claude policy adapter.
- Add Copilot policy adapter.
- Add provider capability detection.
- Add generated provider config preview.
- Add diagnostics for unsupported policy features.

### Milestone 3: Run manifest

- Persist run permission manifest.
- Show preflight manifest.
- Show post-run permission summary.
- Add activity summaries for tool use, command use, approvals, denials, and changed files.

### Milestone 4: Advanced provider settings

- Add advanced provider config view.
- Show config ownership.
- Support user override and reset.
- Preserve user-owned provider settings.

### Milestone 5: ASTRA-owned enforcement

- Add command broker policy.
- Broker read/search/write/git/build/test operations in safe modes.
- Add shell command validation.
- Add network destination validation.
- Update enforcement tier display.

## 21. Rollout

- Ship `Review` policy display first without changing runtime behavior.
- Add provider render previews behind an internal flag.
- Enable Claude and Copilot adapter rendering in development channel.
- Compare rendered config against current runtime command behavior.
- Enable run manifests in development channel.
- Run manual verification in `ASTRA Dev.app` only.
- Promote to production after provider parity tests and redaction tests pass.

## 22. Open Questions

- Should `Review` allow scoped file edits after plan approval, or should edits always require a separate policy escalation?
- Should build/test commands be allowlisted per workspace or inferred from package type?
- Should provider-specific advanced overrides be stored in SwiftData, provider settings files, or both?
- Should `Autonomous` require an isolated workspace by default?
- Should ASTRA block a run when provider config is broader than ASTRA policy but ASTRA-owned enforcement is not available?
- How should organization-managed provider settings be detected and represented?

## 23. References

- Claude Code settings files: https://code.claude.com/docs/en/settings#settings-files
- Claude Code permissions: https://code.claude.com/docs/en/permissions
- GitHub Copilot CLI command reference: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference
- Existing Copilot runtime plan: ../../coplilot_runtime_plan.md
