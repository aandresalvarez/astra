# Core Native Shelf Development

This guide describes how to add a new full-functionality shelf to ASTRA while
keeping the pack architecture strong. In v1, packs do not ship shelf code. A
new shelf is Core-owned Swift, services, state, and policy. Packs may reference
that shelf only after Core registers it as a trusted, pack-addressable shelf.

Use this path for shelves that add real behavior, such as a repository review
queue, SQL workspace, incident feed, evidence timeline, or domain dashboard.

## First Principles

- Core owns shelf implementations, runtime access, persisted state, and policy.
- Packs own composition data: which trusted shelves should be visible for a
  workspace profile.
- A shelf should have one durable owner for its domain state. UI derives from
  that owner through services, sessions, or presentation models.
- Runtime power must come from Core or capability packages, not from the pack
  that selects the shelf.
- The shelf should be useful without vertical-specific conditionals in Core.

If a requested shelf needs new runtime power, build or approve the capability
package first. Then build the shelf against that governed capability boundary.
Only then should a pack reference it in `shelfDefaults`.

## Build Order

1. Define the shelf responsibility.
2. Define the domain state and service boundary.
3. Add tests for registry, availability, policy, and non-grant behavior.
4. Add the Core shelf ID and descriptor.
5. Add the session or view model.
6. Add the SwiftUI panel.
7. Wire canvas presentation and close/restore behavior.
8. Wire generated-file routing only if this shelf owns a file destination.
9. Mark the shelf pack-addressable only after the behavior is stable.
10. Add or update a pack manifest that references the new shelf.
11. Validate in `ASTRA Dev` through Workspace Settings and the shelf UI.

Keep these as separate commits or PR slices when possible. The registry and
policy work can be reviewed independently from a large UI panel.

## Core Files To Review

Start with these files:

| Concern | File |
| --- | --- |
| Stable shelf IDs | `Astra/Services/Shelves/ShelfID.swift` |
| Shelf metadata | `Astra/Services/Shelves/ShelfDescriptor.swift` |
| Registered Core shelves | `Astra/Services/Shelves/CoreShelfRegistry.swift` |
| Availability rules | `Astra/Services/Shelves/ShelfAvailabilityPolicy.swift` |
| Pack profile resolution | `Astra/Services/Packs/AstraPackProfileResolver.swift` |
| Pack manifest validation | `Astra/Services/Packs/AstraPackManifestValidator.swift` |
| Canvas item mapping | `Astra/Views/WorkspaceCanvasItem.swift` |
| Shelf to canvas mapping | `Astra/Views/WorkspaceCanvasItemShelfAdapter.swift` |
| Canvas rendering switch | `Astra/Views/ContentView.swift` |
| Optional file routing | `Astra/Services/Shelves/ShelfArtifactRouter.swift` |
| Optional generated-file destination | `Astra/Services/Tasks/TaskGeneratedFiles.swift` |

Existing panels are useful references:

- `Astra/Views/ShelfMarkdownPanelView.swift`
- `Astra/Views/ShelfBrowserPanelView.swift`
- `Astra/Views/ShelfQueryPanelView.swift`
- `Astra/Views/ShelfWorkspaceAppPreviewView.swift`

Do not copy a large panel wholesale. Extract services and presentation helpers
early so the new shelf does not become another large owner file.

## Responsibility Boundary

Before adding a `ShelfID`, write down the shelf's single responsibility:

- What user job does it own?
- What persisted or derived state does it need?
- Which existing services or capability packages provide data?
- What actions can mutate durable ASTRA state?
- What actions call external tools, MCP servers, browsers, CLIs, or provider
  runtimes?
- What should happen when the shelf is hidden by a pack profile?

Use those answers to choose owners:

- Domain state belongs in SwiftData models, task state, workspace config, or a
  focused service.
- Long-lived in-memory interaction belongs in an observable session or view
  model.
- Formatting, sorting, and row shaping belongs in small presentation structs.
- SwiftUI views should render and dispatch actions. They should not own
  external access policy or durable state transitions directly.

## Add The Core Registration

Add a new case to `ShelfID` with a stable lowercase raw value:

```swift
enum ShelfID: String, CaseIterable, Hashable {
    case plan
    case files
    case browser
    case query
    case appPreview
    case reviewQueue
}
```

Then add a descriptor to `CoreShelfRegistry`:

```swift
ShelfDescriptor(
    id: .reviewQueue,
    title: "Review Queue",
    systemImage: "checklist",
    minWidth: 420,
    idealWidth: 560,
    maxWidth: 1040,
    closesWhenDraggedBelowMinimum: false,
    isPackAddressable: false,
    generatedFileDestination: nil
)
```

Start with `isPackAddressable: false` for new shelves unless the shelf is
already safe to expose through pack profiles. Flip it to `true` only after:

- availability rules are tested
- policy and capability boundaries are tested
- pack manifest validation accepts the shelf
- pack profile resolution can show and hide it
- the shelf remains safe when selected by a pack without enabling capability
  resources

## Wire Presentation

Add the new `WorkspaceCanvasItem` case and update the `ShelfID` mappings in
`WorkspaceCanvasItemShelfAdapter`.

Add a SwiftUI panel in `Astra/Views`:

```swift
struct ShelfReviewQueuePanelView: View {
    @ObservedObject var session: ShelfReviewQueueSession
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }
}
```

Create focused collaborators instead of growing the view:

- `ShelfReviewQueueSession` for interaction state
- `ReviewQueueService` for data loading or mutation
- `ReviewQueuePresentation` for rows, sections, labels, and empty states
- `ReviewQueuePolicy` for local affordance decisions

Wire the panel in `ContentView.canvasContent(for:)`. The switch should remain a
thin adapter from `WorkspaceCanvasItem` to the dedicated panel.

## Availability And Restore Rules

Update `ShelfAvailabilityPolicy` when the shelf has specific preconditions.
Prefer explicit context fields over hidden reads from global or view state.

Examples:

- Plan requires an open task with plan content.
- Browser requires an open task.
- Query requires an open task and a query affordance.
- App Preview requires App Studio composition.

A new shelf should answer three questions:

- Can the toolbar show the shelf button?
- Can the shelf be presented right now?
- Can a remembered shelf selection be restored?

Add tests in `ShelfAvailabilityPolicyTests`. If the shelf should be hidden by a
pack profile, add or update profile tests that pass `disabledShelfIDs` into the
policy.

## Runtime And Capability Boundaries

If the shelf reads files, calls tools, uses MCP, opens browsers, runs CLIs, or
talks to external services, do not put those calls directly in the view.

Use the existing governed paths:

- capability packages for runtime resources
- `TaskCapabilityResolver` and runtime integrity checks for task launch
- `HostFileAccessBroker` for host file reads
- typed services for state-changing actions
- explicit policy evidence when a pack hides or disables behavior

A pack may reference `capabilityPackageIDs` beside a shelf default, but that is
provenance only. Enabling the pack must not activate those resources. Add a
non-grant regression before exposing the shelf through a pack.

## Generated Files And Artifact Routing

Only add generated-file routing if the shelf is the natural destination for a
file type. Update these together:

- `ShelfArtifactRouter.shelfID(for:)`
- `TaskGeneratedFileShelfDestination`
- `CoreShelfRegistry` `generatedFileDestination`
- `TaskGeneratedFileOpenRouterTests`
- `ShelfArtifactRouterTests`

If the shelf is not a file destination, leave `generatedFileDestination` as
`nil`.

## Pack Exposure

After the shelf is Core-owned and tested, expose it to packs:

1. Set `isPackAddressable: true` in `CoreShelfRegistry`.
2. Add a pack manifest `shelfDefaults` entry:

   ```json
   {
     "id": "reviewQueue",
     "title": "Review Queue",
     "kind": "nativeShelf",
     "capabilityPackageIDs": ["github-workflow"]
   }
   ```

3. Confirm `AstraPackManifestValidator` accepts the shelf.
4. Confirm `AstraPackProfileResolver` makes it visible when the pack is enabled.
5. Confirm `Workspace Settings > Packs` shows the shelf in the pack row.
6. Confirm runtime resources still require explicit capability enablement.

Use stable raw IDs forever once shipped. If the display name changes, update the
descriptor title, not the stable ID.

## Required Tests

At minimum, add or update:

- `ShelfRegistryTests`
  - descriptor exists for every `ShelfID`
  - width, title, icon, `isPackAddressable`, and generated-file metadata are
    intentional
  - stable string IDs resolve
  - `WorkspaceCanvasItem` maps to the shelf ID
- `ShelfAvailabilityPolicyTests`
  - toolbar availability
  - presentability
  - remembered selection restore behavior
  - hidden-shelf behavior
- `TrustedShelfContributionTests`
  - pack can reference the shelf only when it is pack-addressable
  - non-addressable shelves remain blocked
  - packs cannot override shelf implementation
- `AstraPackManifestValidatorTests`
  - unknown or unaddressable shelf IDs fail validation
  - policy restrictions against the shelf use trusted IDs
- `AstraPackProfileTests`
  - enabled pack shows the shelf
  - omitted pack defaults hide pack-addressable shelves
  - workspace/admin overrides behave correctly
- `WorkspacePackSettingsPresentationTests`
  - the new shelf appears in pack inspection summaries
- runtime or capability tests for every external action the shelf can trigger

For UI-heavy shelves, add focused presentation tests before relying on manual
inspection.

## Validation Commands

Start narrow:

```bash
swift test --filter 'ShelfRegistryTests|ShelfAvailabilityPolicyTests|TrustedShelfContributionTests|AstraPackManifestValidatorTests|AstraPackProfileTests|WorkspacePackSettingsPresentationTests'
git diff --check
```

If the shelf changes generated-file routing:

```bash
swift test --filter 'ShelfArtifactRouterTests|TaskGeneratedFileOpenRouterTests'
```

If the shelf touches runtime or capabilities:

```bash
swift test --filter 'TaskCapabilityResolverTests|CapabilityRuntimeIntegrityServiceTests|AstraPackPolicyTests'
```

Before merging a new shelf:

```bash
swift test --filter ArchitectureFitnessTests
./script/precommit.sh
./script/prepush.sh
ASTRA_CHANNEL=dev ./script/build_and_run.sh run
```

Then manually validate in `ASTRA Dev`:

- the shelf appears only when policy says it can
- hiding the shelf through a pack removes the toolbar/presentation affordance
- enabling the pack does not grant capabilities
- generated files route correctly or fall back to the system opener
- the shelf survives workspace switching, task switching, and app relaunch

## Anti-Patterns

Do not:

- load SwiftUI, bundles, plugins, scripts, or modules from a pack manifest
- add customer or vertical checks in Core runtime code
- let a pack enable tools, MCP servers, browser access, credentials, or CLIs
- put file reads, network calls, or external process launches in a SwiftUI body
- make a shelf view the durable owner of domain state
- grow `ContentView` or an existing shelf panel for unrelated behavior
- mark a shelf pack-addressable before its policy and non-grant tests exist
- route generated files to a shelf without a policy fallback

## Example: New Review Queue Shelf

A robust implementation would look like this:

1. Add or reuse `github-workflow` as the capability package for GitHub access.
2. Add `ReviewQueueService` to load PR and CI state through governed runtime
   resources.
3. Add `ShelfReviewQueueSession` for selection, filters, and refresh state.
4. Add `ReviewQueuePresentation` for grouped rows and badges.
5. Add `ShelfReviewQueuePanelView` as the thin SwiftUI surface.
6. Add `ShelfID.reviewQueue`, a `CoreShelfRegistry` descriptor, and canvas
   mapping.
7. Add availability rules for workspace/task context.
8. Add non-grant tests proving that `astra.pack.devops` can show the shelf but
   cannot enable GitHub runtime resources.
9. Set `isPackAddressable: true` only after the tests pass.
10. Reference `reviewQueue` from the vertical pack manifest.

That shape keeps ASTRA Core strong while still letting vertical packs compose
new product experiences.
