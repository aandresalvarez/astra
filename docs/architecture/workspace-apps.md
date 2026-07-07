# Workspace Apps Architecture

Workspace Apps are governed app surfaces generated, imported, or maintained
inside a workspace. Their source of truth is the typed manifest and persisted
app records, not generated HTML or view-local state.

## Owners

- `WorkspaceAppManifest` defines the app contract: views, widgets, actions,
  storage, bindings, permissions, and package metadata.
- `WorkspaceAppService` owns lifecycle persistence for apps, versions, runs, and
  installed packages.
- `WorkspaceAppActionExecutor` owns action execution and translates manifest
  actions into audited effects through `WorkspaceAppActionEffect`.
- `WorkspaceAppContractRegistry` owns native capability contracts exposed to
  app actions.
- `WorkspaceAppWebRendererPolicy` owns the allow-list for Swift-authored web
  renderers used by WebView widgets.

## Invariants

- Manifest validation is the publish gate. Runtime surfaces should consume a
  validated manifest instead of revalidating partial view state.
- App storage and action execution are app-scoped. A widget may request only the
  actions declared by its manifest and allowed by the native contract boundary.
- Generated and imported packages may add app surfaces, but they do not bypass
  capability governance, native permission prompts, or connector read pipelines.
- Studio generation, refinement, verification, and journaling remain service
  owned. SwiftUI views render session state and call services; they do not own
  durable app state.

## Related Files

- `Astra/Services/WorkspaceApps/WorkspaceAppManifest.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppActionEffect.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppContractRegistry.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppWebRendererPolicy.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppStudioSession.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageService.swift`
