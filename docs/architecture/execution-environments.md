# Execution Environments Architecture

Execution environments describe where provider reasoning runs, where project
commands run, and which paths or credentials are projected into each boundary.
They are task/run launch inputs, not view-local toggles.

## Owners

- `ExecutionEnvironment` owns the persisted environment contract and launch
  planning for host, Docker, and mixed host-provider/workspace-container modes.
- `ExecutionEnvironmentProviderPlacement` records whether the provider process
  runs on the host or inside the workspace executor.
- `Workspace` owns workspace defaults. `AgentTask` and run launch manifests own
  the effective snapshot used by a specific task.
- `WorkspaceDockerViewModel` owns the UI editing flow for Docker settings and
  writes those settings back through the workspace model.

## Invariants

- Provider placement and workspace command placement are separate decisions.
  A host provider may still route project shell commands through the Docker
  workspace executor.
- Path mappings and mount plans must be computed before provider launch. Runtime
  adapters receive the resolved launch context rather than discovering Docker
  state on their own.
- Credential and host-control access stay on the ASTRA side of the boundary.
  Docker workspace shell commands use explicit MCP tools or connector
  projections instead of inheriting host secrets.
- UI settings are defaults. The launch preflight and runtime manifest are the
  audit trail for what a particular task actually used.

## Related Files

- `Astra/Services/Runtime/ExecutionEnvironment.swift`
- `Astra/Services/Runtime/TaskLaunchResourceResolver.swift`
- `Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift`
- `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`
- `Astra/Models/Workspace.swift`
- `Astra/Models/AgentTask.swift`
- `Astra/Views/WorkspaceDockerViewModel.swift`
