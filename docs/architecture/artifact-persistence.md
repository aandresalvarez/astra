# Artifact Persistence Contract

ASTRA keeps generated outputs visible through both files on disk and SwiftData
metadata. The current reconciliation owner is
`TaskArtifactPersistenceService`.

## Storage Surfaces

- Task output files live in the task folder under the workspace support
  directory: `.astra/tasks/<task-id-prefix>/`.
- `Artifact` rows store durable metadata: task, type, absolute path, optional
  content, version, and creation date.
- `TaskRun.fileChangesJSON` stores JSON-encoded `StoredFileChange` records for
  provider-reported or inferred file changes.
- `current_state.json` and `current_state.md` summarize artifacts and changed
  files for prompt continuity.
- Generated-file shelf presentation discovers displayable files from the task
  folder and excludes ASTRA-owned state files.

## Lifecycle

1. Runtime execution writes or changes files in the task workspace or task
   folder.
2. The runtime run records file changes on `TaskRun` when the provider or
   adapter supplies them.
3. `AgentRuntimeRunPersistence.finalizeAndPersist(...)` calls
   `TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(...)`.
4. Reconciliation discovers task output files, normalizes paths, creates
   missing `Artifact` rows, reports duplicate rows, and separates current from
   stale artifacts.
5. `TaskContextStateManager` also reconciles before deriving `current_state`
   artifact and changed-file references.
6. UI shelves and validation read the reconciled model plus disk discovery
   rather than assuming one surface is always complete.

## Invariants

- Reconciliation must be idempotent for a stable set of files.
- Stored artifact paths are normalized. Relative paths are resolved through
  `TaskWorkspaceAccess`; absolute paths are standardized and symlink-resolved.
- Duplicate detection is path-based after normalization.
- Stale artifacts remain detectable; a missing disk file must not be silently
  treated as a valid deliverable.
- ASTRA-owned task state files, including `current_state.json`,
  `current_state.md`, `session_history.md`, `outputs/`, `turns/`,
  `diagnostics/`, and `.runtime-bin/`, are not user deliverables in generated
  file shelves.
- Deliverable verification decides whether an artifact is sufficient for
  completion; artifact persistence only records and reconciles output metadata.

## Related Files

- `Astra/Services/TaskArtifactPersistenceService.swift`
- `Astra/Services/AgentRuntimeRunPersistence.swift`
- `Astra/Services/TaskContextStateManager.swift`
- `Astra/Services/TaskGeneratedFiles.swift`
- `Astra/Services/TaskOutputDiscovery.swift`
- `Astra/Services/TaskDeliverableVerificationService.swift`
- `Astra/Models/Artifact.swift`
- `Astra/Models/TaskRun.swift`
