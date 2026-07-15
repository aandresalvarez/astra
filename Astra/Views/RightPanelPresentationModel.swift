import SwiftUI

/// The single owner of right-panel presentation.
///
/// Before this model, `isWorkspaceRightRailVisible` was a plain `ContentView`
/// persisted flag written directly from four independent call sites
/// (`startWorkspaceAppStudio`, `toggleAppPreviewCanvas`, `handleSidebarToggle`,
/// `restoreRememberedWorkspaceCanvasItemIfAvailable`) in addition to the three
/// call sites that already funneled through helpers — the same "uncoordinated
/// writers" shape `SidebarPresentationModel` was built to kill for the sidebar.
/// This model consolidates all of them: the durable "rail wanted" intent
/// (`isRailShown`, persisted) and the transient active canvas item
/// (`activeCanvasItem`) both live here, and every presentation mutation funnels
/// through one of the methods below. Task-owned remembered canvas state is
/// handled separately by `WorkspaceCanvasItemPreferenceService`. `ContentView` only reads
/// the two published properties (via read-only forwarding computed
/// properties) and calls these methods — it never writes either property
/// directly.
///
/// The rendered `WorkspaceRightPanel` mode (`.canvas` takes priority over
/// `.context`, the workspace inspector rail) is still derived where it is
/// consumed, in `ContentDetailAreaView.activeRightPanel` — that view only
/// receives plain bindings, not this model, so its derivation reads the same
/// two properties this model owns.
@MainActor
final class RightPanelPresentationModel: ObservableObject {
    /// Durable "the user wants the workspace context rail visible" intent.
    /// Persisted directly via `UserDefaults` — mirrors
    /// `SidebarPresentationModel.isSidebarShown` — defaulting to visible.
    @Published private(set) var isRailShown: Bool

    /// The transient active shelf item (plan / markdown / browser / query /
    /// app preview). It is never persisted by this presentation owner.
    @Published private(set) var activeCanvasItem: WorkspaceCanvasItem?

    private let defaults: UserDefaults
    private static let railShownDefaultsKey = "isWorkspaceRightRailVisible"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isRailShown = (defaults.object(forKey: Self.railShownDefaultsKey) as? Bool) ?? true
    }

    // MARK: - Derived presentation

    /// Whether any right-side panel is presented — the signal
    /// `SidebarPresentationModel` needs to decide whether it can dock
    /// alongside this panel or must present as an overlay drawer.
    func hasAnyPanelPresented(hasWorkspace: Bool) -> Bool {
        activeCanvasItem != nil || (hasWorkspace && isRailShown)
    }

    // MARK: - Rail intent

    /// Show the workspace context rail, clearing any transient canvas item.
    func presentRail() {
        setActiveCanvasItem(nil)
        isRailShown = true
        persistRailShown()
    }

    /// Hide the rail without touching the active canvas item.
    func dismissRail() {
        isRailShown = false
        persistRailShown()
    }

    /// Binding-style setter mirroring the former `setRightRailPresented`: show
    /// routes through `presentRail`, hide just clears the rail flag.
    func setRailPresented(_ isPresented: Bool) {
        if isPresented {
            presentRail()
        } else {
            dismissRail()
        }
    }

    // MARK: - Canvas item intent

    /// Present a transient shelf item, dismissing the rail.
    func presentCanvas(_ item: WorkspaceCanvasItem) {
        isRailShown = false
        persistRailShown()
        setActiveCanvasItem(item)
    }

    /// The single place transient `activeCanvasItem` is written.
    func setActiveCanvasItem(_ item: WorkspaceCanvasItem?) {
        activeCanvasItem = item
    }

    /// Hide the rail without touching the active canvas item or the
    /// remembered per-conversation item — used by callers that are about to
    /// set `activeCanvasItem` themselves (App Studio start/toggle), where the
    /// rail-dismiss and canvas-item-set are two separate, sequential steps
    /// rather than the atomic swap `presentCanvas` performs. Mirrors the
    /// former direct writes in `startWorkspaceAppStudio` and
    /// `toggleAppPreviewCanvas`.
    func hideRailWithoutClearingCanvasItem() {
        isRailShown = false
        persistRailShown()
    }

    /// If the task-owned remembered item can be shown and nothing is currently
    /// presented, restore it without writing durable state.
    func restoreRememberedItemIfAvailable(
        rememberedItem: WorkspaceCanvasItem?,
        canPresent: (WorkspaceCanvasItem) -> Bool
    ) -> WorkspaceCanvasItem? {
        guard WorkspaceCanvasItemPreference.shouldRestoreRememberedItem(
            activeItem: activeCanvasItem,
            isRightRailVisible: isRailShown,
            rememberedItem: rememberedItem,
            canPresentRememberedItem: rememberedItem.map(canPresent) ?? false
        ), let item = rememberedItem else {
            return nil
        }

        isRailShown = false
        persistRailShown()
        setActiveCanvasItem(item)
        return item
    }

    private func persistRailShown() {
        defaults.set(isRailShown, forKey: Self.railShownDefaultsKey)
    }
}
