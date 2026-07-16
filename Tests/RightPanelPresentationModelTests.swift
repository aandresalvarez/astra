import Foundation
import Testing
@testable import ASTRA

/// Behavioural contract for the single owner of right-panel presentation.
/// These lock in the bug the model was built to kill: `isWorkspaceRightRailVisible`
/// used to be written directly from independent `ContentView` call sites
/// (App Studio start, App Studio preview toggle, the sidebar-reveal handoff,
/// and the remembered-shelf restore) with no single place resolving
/// conflicts — mirroring the uncoordinated-writer bug `SidebarPresentationModel`
/// was built to kill for the sidebar.
@MainActor
@Suite("RightPanelPresentationModel")
struct RightPanelPresentationModelTests {

    private func makeModel(defaultsSuite: String = UUID().uuidString) -> RightPanelPresentationModel {
        let defaults = UserDefaults(suiteName: "rightpanel.test.\(defaultsSuite)")!
        return RightPanelPresentationModel(defaults: defaults)
    }

    // MARK: - Defaults

    @Test("First run with no stored preference defaults the rail to shown")
    func defaultsToShownOnFirstRun() {
        let model = makeModel()
        #expect(model.isRailShown)
        #expect(model.activeCanvasItem == nil)
    }

    @Test("Stored preference is honored on init")
    func honorsStoredPreference() {
        let defaults = UserDefaults(suiteName: "rightpanel.test.\(UUID().uuidString)")!
        defaults.set(false, forKey: "isWorkspaceRightRailVisible")
        let model = RightPanelPresentationModel(defaults: defaults)
        #expect(model.isRailShown == false)
    }

    // MARK: - Rail intent: presentRail / dismissRail / setRailPresented

    @Test("presentRail shows the rail and clears any active canvas item")
    func presentRailClearsCanvasItem() {
        let model = makeModel()
        model.presentCanvas(.plan)
        #expect(model.activeCanvasItem == .plan)

        model.presentRail()

        #expect(model.isRailShown)
        #expect(model.activeCanvasItem == nil)
    }

    @Test("dismissRail hides the rail without touching the active canvas item")
    func dismissRailPreservesCanvasItem() {
        let model = makeModel()
        model.presentCanvas(.browser)

        model.dismissRail()

        #expect(model.isRailShown == false)
        #expect(model.activeCanvasItem == .browser)
    }

    @Test("setRailPresented(true) routes through presentRail; setRailPresented(false) dismisses")
    func setRailPresentedRoutesCorrectly() {
        let model = makeModel()
        model.presentCanvas(.markdown)

        model.setRailPresented(true)
        #expect(model.isRailShown)
        #expect(model.activeCanvasItem == nil)

        model.setRailPresented(false)
        #expect(model.isRailShown == false)
    }

    @Test("Rail visibility persists across model instances sharing defaults")
    func railVisibilityPersists() {
        let suiteName = UUID().uuidString
        let model = makeModel(defaultsSuite: suiteName)
        model.dismissRail()

        let reborn = makeModel(defaultsSuite: suiteName)
        #expect(reborn.isRailShown == false)
    }

    // MARK: - Canvas item intent: presentCanvas / setActiveCanvasItem

    @Test("presentCanvas dismisses the rail and sets the active item")
    func presentCanvasDismissesRail() {
        let model = makeModel()

        model.presentCanvas(.query)

        #expect(model.isRailShown == false)
        #expect(model.activeCanvasItem == .query)
    }

    @Test("setActiveCanvasItem(nil) clears the canvas item without affecting the rail flag")
    func clearingCanvasItemDoesNotTouchRail() {
        let model = makeModel()
        model.presentCanvas(.plan)
        model.presentRail() // rail shown, item cleared
        model.presentCanvas(.plan) // rail hidden again, item set

        model.setActiveCanvasItem(nil)

        #expect(model.activeCanvasItem == nil)
        #expect(model.isRailShown == false) // untouched by the plain clear
    }

    // MARK: - hideRailWithoutClearingCanvasItem (App Studio start/toggle)

    @Test("hideRailWithoutClearingCanvasItem hides the rail and preserves whatever canvas item is already active")
    func hideRailWithoutClearingCanvasItemPreservesItem() {
        let model = makeModel()
        model.presentRail()
        #expect(model.isRailShown)

        model.hideRailWithoutClearingCanvasItem()

        #expect(model.isRailShown == false)
        #expect(model.activeCanvasItem == nil) // was already nil; confirms no implicit set

        model.setActiveCanvasItem(.appPreview)
        model.hideRailWithoutClearingCanvasItem()
        #expect(model.activeCanvasItem == .appPreview)
    }

    // MARK: - hasAnyPanelPresented (feeds SidebarPresentationModel)

    @Test("hasAnyPanelPresented is true when the rail is shown and a workspace is open")
    func hasAnyPanelPresentedTrueForShownRail() {
        let model = makeModel()
        #expect(model.hasAnyPanelPresented(hasWorkspace: true))
        #expect(model.hasAnyPanelPresented(hasWorkspace: false) == false)
    }

    @Test("hasAnyPanelPresented is true when a canvas item is active regardless of workspace")
    func hasAnyPanelPresentedTrueForCanvasItem() {
        let model = makeModel()
        model.presentCanvas(.plan)
        #expect(model.hasAnyPanelPresented(hasWorkspace: false))
    }

    @Test("hasAnyPanelPresented is false when the rail is dismissed and no canvas item is active")
    func hasAnyPanelPresentedFalseWhenFullyDismissed() {
        let model = makeModel()
        model.dismissRail()
        #expect(model.hasAnyPanelPresented(hasWorkspace: true) == false)
    }

    // MARK: - Task-owned remembered item restoration

    @Test("A supplied remembered item restores without creating another durable write")
    func suppliedRememberedItemRestores() {
        let model = makeModel()
        model.hideRailWithoutClearingCanvasItem()

        let restored = model.restoreRememberedItemIfAvailable(
            rememberedItem: .markdown,
            canPresent: { _ in true }
        )

        #expect(restored == .markdown)
        #expect(model.activeCanvasItem == .markdown)
        #expect(model.isRailShown == false)
    }

    @Test("restoreRememberedItemIfAvailable does nothing when a canvas item is already active")
    func restoreDoesNothingWhenAlreadyPresenting() {
        let model = makeModel()
        model.presentCanvas(.browser) // now presenting something else

        let restored = model.restoreRememberedItemIfAvailable(
            rememberedItem: .markdown,
            canPresent: { _ in true }
        )

        #expect(restored == nil)
        #expect(model.activeCanvasItem == .browser)
    }

    @Test("restoreRememberedItemIfAvailable does nothing when the rail is currently shown")
    func restoreDoesNothingWhileRailShown() {
        let model = makeModel()

        let restored = model.restoreRememberedItemIfAvailable(
            rememberedItem: .query,
            canPresent: { _ in true }
        )

        #expect(restored == nil)
    }

    @Test("restoreRememberedItemIfAvailable respects canPresent gating")
    func restoreRespectsCanPresentGate() {
        let model = makeModel()
        model.dismissRail()

        let restored = model.restoreRememberedItemIfAvailable(
            rememberedItem: .query,
            canPresent: { _ in false }
        )

        #expect(restored == nil)
        #expect(model.activeCanvasItem == nil)
    }

}
