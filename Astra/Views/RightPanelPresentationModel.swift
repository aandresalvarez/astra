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
/// (`activeCanvasItem`, remembered per-conversation) both live here, and every
/// mutation funnels through one of the methods below. `ContentView` only reads
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
    /// app preview). Not persisted directly; the per-conversation remembered
    /// item is tracked separately in `rememberedItemsRawValue` and only
    /// consulted by `restoreRememberedItemIfAvailable`.
    @Published private(set) var activeCanvasItem: WorkspaceCanvasItem?

    /// Per-conversation remembered shelf item storage, round-tripped through
    /// `WorkspaceCanvasItemPreference`'s encoding. Kept here (rather than as a
    /// second independent `ContentView` `@State`) so the remember/restore
    /// lifecycle is entirely owned by this model.
    private(set) var rememberedItemsRawValue: String

    private let defaults: UserDefaults
    private static let railShownDefaultsKey = "isWorkspaceRightRailVisible"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isRailShown = (defaults.object(forKey: Self.railShownDefaultsKey) as? Bool) ?? true
        let loadedItems = WorkspaceCanvasItemPreferenceStore.load(defaults: defaults)
        let normalizedItems = WorkspaceCanvasItemPreference.normalizedStorageRawValue(loadedItems)
        self.rememberedItemsRawValue = normalizedItems
        WorkspaceCanvasItemPreferenceStore.saveIfChanged(
            currentRawValue: loadedItems,
            updatedRawValue: normalizedItems,
            defaults: defaults
        )
    }

    // MARK: - Derived presentation

    /// Whether any right-side panel is presented — the signal
    /// `SidebarPresentationModel` needs to decide whether it can dock
    /// alongside this panel or must present as an overlay drawer.
    func hasAnyPanelPresented(hasWorkspace: Bool) -> Bool {
        activeCanvasItem != nil || (hasWorkspace && isRailShown)
    }

    // MARK: - Rail intent

    /// Show the workspace context rail, clearing any active canvas item.
    /// `rememberShelfState` controls whether the cleared canvas item is kept
    /// as the per-conversation remembered item (so it can be restored later).
    /// `conversationID` must be threaded through for that remembering to
    /// actually happen — `setActiveCanvasItem` is a no-op without one.
    func presentRail(rememberShelfState: Bool = true, conversationID: String? = nil) {
        setActiveCanvasItem(nil, remember: rememberShelfState, conversationID: conversationID)
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
    func setRailPresented(_ isPresented: Bool, conversationID: String? = nil) {
        if isPresented {
            presentRail(conversationID: conversationID)
        } else {
            dismissRail()
        }
    }

    // MARK: - Canvas item intent

    /// Present a shelf item, dismissing the rail (mirrors the former
    /// `presentCanvas`). `conversationID` must be threaded through so the
    /// item is remembered per-conversation, exactly as the pre-model call
    /// site did via `selectedWorkspaceCanvasConversationID`.
    func presentCanvas(_ item: WorkspaceCanvasItem, conversationID: String? = nil) {
        isRailShown = false
        persistRailShown()
        setActiveCanvasItem(item, remember: true, conversationID: conversationID)
    }

    /// The single place `activeCanvasItem` (and its per-conversation memory)
    /// is written. All call sites — including this model's own `presentRail`
    /// / `presentCanvas` — route through here.
    func setActiveCanvasItem(_ item: WorkspaceCanvasItem?, remember: Bool, conversationID: String? = nil) {
        activeCanvasItem = item
        guard let conversationID else { return }
        let updated = WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: rememberedItemsRawValue,
            conversationID: conversationID,
            item: item,
            remember: remember
        )
        guard updated != rememberedItemsRawValue else { return }
        let previousRawValue = rememberedItemsRawValue
        rememberedItemsRawValue = updated
        WorkspaceCanvasItemPreferenceStore.saveIfChanged(
            currentRawValue: previousRawValue,
            updatedRawValue: updated,
            defaults: defaults
        )
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

    /// If a remembered shelf item exists for `conversationID` and nothing is
    /// currently presented, restore it and hide the rail. Mirrors the former
    /// `restoreRememberedWorkspaceCanvasItemIfAvailable`.
    func restoreRememberedItemIfAvailable(
        conversationID: String?,
        canPresent: (WorkspaceCanvasItem) -> Bool
    ) -> WorkspaceCanvasItem? {
        let remembered = WorkspaceCanvasItemPreference.item(in: rememberedItemsRawValue, for: conversationID)
        guard WorkspaceCanvasItemPreference.shouldRestoreRememberedItem(
            activeItem: activeCanvasItem,
            isRightRailVisible: isRailShown,
            rememberedItem: remembered,
            canPresentRememberedItem: remembered.map(canPresent) ?? false
        ), let item = remembered else {
            return nil
        }

        isRailShown = false
        persistRailShown()
        touchRememberedItem(conversationID: conversationID)
        setActiveCanvasItem(item, remember: false, conversationID: conversationID)
        return item
    }

    private func touchRememberedItem(conversationID: String?) {
        let updated = WorkspaceCanvasItemPreference.touchingStorageRawValue(
            rememberedItemsRawValue,
            conversationID: conversationID
        )
        guard updated != rememberedItemsRawValue else { return }
        let previousRawValue = rememberedItemsRawValue
        rememberedItemsRawValue = updated
        WorkspaceCanvasItemPreferenceStore.saveIfChanged(
            currentRawValue: previousRawValue,
            updatedRawValue: updated,
            defaults: defaults
        )
    }

    private func persistRailShown() {
        defaults.set(isRailShown, forKey: Self.railShownDefaultsKey)
    }
}
