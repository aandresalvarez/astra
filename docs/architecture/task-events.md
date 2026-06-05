# Task Event Contract

Task events are ASTRA's durable task history. They are persisted as SwiftData
`TaskEvent` rows while newer code uses `TaskEventType` and `TaskEventTypes` as a
typed namespace around the stored strings.

## Storage Schema

`Astra/Models/TaskEvent.swift` stores:

- `id`: event UUID.
- `task`: owning `AgentTask`.
- `run`: optional `TaskRun` that produced the event.
- `type`: persisted event type string, such as `task.completed` or
  `validation.contract.failed`.
- `payload`: event payload string. Some payloads are plain text; newer
  structured events encode JSON.
- `timestamp`: event creation time.
- `agentName`, `agentId`, `teamName`: optional team identity fields.
- `category`: persisted category string derived from the event type.

`TaskEventTypes.swift` defines typed constants and category mapping. The stored
`type` string remains the compatibility boundary for SwiftData migrations,
historic rows, and UI code that still filters by raw value.

## Event Families

Current event namespaces include:

- Task lifecycle: `task.started`, `task.completed`, `task.cancelled`,
  `task.dismissed`, checkpoints, stats, and chaining.
- Conversation: user messages, agent responses, thinking, and plan-mode
  messages.
- Tool and permission activity: tool use, tool results, permission denials, and
  permission grant requests.
- Plans: plan creation, approval, cancellation, execution, and step progress.
- Validation: contracts, assertions, behavior checks, and evidence events.
- Deliverables: deterministic artifact verification pass, review-needed, and
  failure events.
- Verifier, handoff, corrective work, resource locks, mission events, role
  profile changes, team events, and system events.

## Payload Rules

- Plain-text payloads are valid for legacy and human-readable events.
- JSON payloads should be decoded through `TaskEvent.decodePayload(...)` when
  callers need typed data and explicit decode failures.
- New structured events should add a `TaskEventTypes` constant and a Codable
  payload type near the service that owns the behavior.
- Event category is derived from `TaskEventTypes.category(forRawValue:)`; do
  not hand-maintain a separate category mapping in views.

## Invariants

- Do not rename persisted event strings without a migration and compatibility
  reader.
- Do not treat failed JSON decoding as absence when the caller needs
  diagnostics; use the typed decode result.
- Events are append-only history for task behavior. Derived state, such as
  prompt context and mission presentation, should reconstruct from events rather
  than mutate prior events.
- Run-scoped behavior should set `run` when an event is produced by a specific
  `TaskRun`.

## Related Files

- `Astra/Models/TaskEvent.swift`
- `Astra/Models/TaskEventTypes.swift`
- `Astra/Services/AgentEventRecorder.swift`
- `Astra/Views/TaskThreadSnapshot.swift`
- `Astra/Views/RunActivityPresentation.swift`
- `Astra/Services/TaskPlanService.swift`
- `Astra/Services/ValidationService.swift`
