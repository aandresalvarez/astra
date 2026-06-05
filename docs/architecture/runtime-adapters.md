# Runtime Adapter Contract

This note documents the current provider boundary in
`Astra/Services/AgentRuntimeAdapter.swift`. Runtime adapters are the
provider-specific layer under `AgentRuntimeWorker`; they translate ASTRA's task
contract into CLI-specific readiness checks, launch plans, stream parsing, event
recording, and utility prompts.

## Owners

- `AgentRuntimeAdapter` defines the provider contract.
- `AgentRuntimeAdapterCatalog` and `AgentRuntimeAdapterRegistry` register
  runtime IDs and descriptors.
- Built-in providers are `ClaudeCodeRuntimeAdapterProvider`,
  `CopilotCLIRuntimeAdapterProvider`, and `AntigravityCLIRuntimeAdapterProvider`.
- `AgentRuntimeWorker` selects the registered adapter for a task, builds the
  prompt, launches the process, records stream events, and applies completion
  policy.

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

## Related Files

- `Astra/Services/AgentRuntimeAdapter.swift`
- `Astra/Services/AgentRuntimeWorker.swift`
- `Astra/Services/AgentRuntimeProcessRunner.swift`
- `Astra/Services/RuntimeReadinessService.swift`
- `Astra/Services/ClaudeModelAvailabilityService.swift`
- `Astra/Services/CopilotModelAvailabilityService.swift`
