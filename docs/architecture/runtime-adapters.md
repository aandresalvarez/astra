# Runtime Adapter Contract

This note documents the current provider boundary in
`Astra/Services/Runtime/AgentRuntimeAdapter.swift`. Runtime adapters are the
provider-specific layer under `AgentRuntimeWorker`; they translate ASTRA's task
contract into CLI-specific readiness checks, launch plans, stream parsing, event
recording, and utility prompts.

## Owners

- `AgentRuntimeAdapter` defines the provider contract.
- `AgentRuntimeAdapterCatalog` and `AgentRuntimeAdapterRegistry` register
  runtime IDs and descriptors.
- Built-in providers are `ClaudeCodeRuntimeAdapterProvider`,
  `CopilotCLIRuntimeAdapterProvider`, `AntigravityCLIRuntimeAdapterProvider`,
  `CodexCLIRuntimeAdapterProvider`, `CursorCLIRuntimeAdapterProvider`, and
  `OpenCodeCLIRuntimeAdapterProvider`.
- `AgentRuntimeWorker` selects the registered adapter for a task, builds the
  prompt, launches the process, records stream events, and applies completion
  policy.

## Registered Providers

| Runtime ID | Provider | Adapter | Executable | Native Continuation |
| --- | --- | --- | --- | --- |
| `claude_code` | `ClaudeCodeRuntimeAdapterProvider` | `ClaudeCodeRuntimeAdapter` | `claude` | yes |
| `copilot_cli` | `CopilotCLIRuntimeAdapterProvider` | `CopilotCLIRuntimeAdapter` | `copilot` | no |
| `antigravity_cli` | `AntigravityCLIRuntimeAdapterProvider` | `AntigravityCLIRuntimeAdapter` | `agy` | no |
| `codex_cli` | `CodexCLIRuntimeAdapterProvider` | `CodexCLIRuntimeAdapter` | `codex` | yes |
| `cursor_cli` | `CursorCLIRuntimeAdapterProvider` | `CursorCLIRuntimeAdapter` | `cursor-agent` | no |
| `opencode_cli` | `OpenCodeCLIRuntimeAdapterProvider` | `OpenCodeCLIRuntimeAdapter` | `opencode` | no |

Runtime IDs live in `AgentRuntimeID`. Install and auth prerequisites live in
`CLIPrerequisite`. The registry is the only composition point for built-in
adapter lookup.

## Adapter Responsibilities

An adapter owns:

- Runtime identity and metadata: `id`, `descriptor`, default model data,
  readiness check IDs, model-availability authority, and budget profile.
- Readiness and install guidance: `readinessReport`, `modelAvailabilityCheck`,
  executable checks, and optional `installPlan`.
- Policy rendering: provider config ownership, existing provider config
  summaries, runtime policy capabilities, and launch-time permission text.
- Launch planning: executable path, home directory, arguments, current
  directory, environment, browser shim directory, provider version, JSON-lines
  parsing mode, directories to create, and planned-command audit fields.
- Runtime stream interpretation: process events, blocking permission requests,
  worker stream batches, callback events, stream flushing, telemetry, and debug
  capture.
- Provider event persistence: recording parsed worker stream events into
  `TaskEvent` rows for initial and follow-up runs.
- Utility prompts: verifier, recap, validation, and other non-primary provider
  calls through `runUtilityPrompt`.
- Post-run provider diagnostics and follow-up event recording.

## Invariants

- A runtime must be registered before use. Unknown runtime strings are resolved
  through `AgentRuntimeAdapterRegistry.registeredRuntime(...)` or fail at
  `adapter(for:)`.
- Runtime-specific behavior belongs in an adapter; orchestration, task state
  transitions, validation gates, and workspace persistence stay in
  `AgentRuntimeWorker` and related services.
- Adapter launch plans are auditable data. The worker logs provider-detected and
  command-planned fields instead of reconstructing provider commands elsewhere.
- Stream parsers may emit provider-native events or ASTRA parsed events, but
  persisted task history must go through adapter recording methods.
- Provider-native continuation is an optimization exposed by the runtime
  descriptor. Prompt assembly remains ASTRA-owned and state-backed.
- Readiness and model availability are per-runtime concerns, but the runtime
  registry remains the single composition point for provider lookup.
- Policy vocabulary is typed at the boundary. `RunPhase` and
  `ProviderPermissionMode` are serialized as strings only at provider or audit
  edges.

## Related Files

- `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`
- `Astra/Services/Runtime/RuntimeReadinessService.swift`
- `Astra/Services/Runtime/CodexCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/CursorCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/OpenCodeCLIRuntimeAdapter.swift`
- `Astra/Services/Runtime/CodexCLIRuntime.swift`
- `Astra/Services/Runtime/CursorCLIRuntime.swift`
- `Astra/Services/Runtime/OpenCodeCLIRuntime.swift`
- `Astra/Services/Runtime/ProviderPolicyModeResolver.swift`
- `Astra/Services/Runtime/ClaudeModelAvailabilityService.swift`
- `Astra/Services/Runtime/CopilotModelAvailabilityService.swift`
- `ASTRACore/AgentRuntimeTypes.swift`
- `ASTRACore/CLIPrerequisite.swift`
