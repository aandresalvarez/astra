import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Screen transition context")
@MainActor
struct ScreenTransitionContextTests {
    @Test("Restoring Files or Browser captures an opening before presentation mutates", arguments: [WorkspaceCanvasItem.markdown, .browser])
    func restoreCapturesBeforeMutation(item: WorkspaceCanvasItem) throws {
        let defaults = InMemoryDefaults()
        let model = RightPanelPresentationModel(defaults: defaults)
        model.dismissRail()
        var captured: ScreenTransitionPanelChange?
        let restored = model.restoreRememberedItemIfAvailable(rememberedItem: item, canPresent: { _ in true }, willRestore: { destination in
            #expect(model.activeCanvasItem == nil)
            captured = .init(previous: ScreenTransitionPanelChange.panelName(canvas: model.activeCanvasItem,
                railShown: model.isRailShown, hasWorkspace: true), next: "shelf_\(destination.rawValue)")
        })
        #expect(restored == item)
        #expect(model.activeCanvasItem == item)
        #expect(captured?.fields == ["direction": "open", "panel_before": "none", "panel_after": "shelf_\(item.rawValue)"])
    }

    @Test("Opening Preview and policy-blocked Studio capture Context before dismissing it", arguments: [WorkspaceCanvasItem.appPreview, nil])
    func previewCapturesContext(item: WorkspaceCanvasItem?) throws {
        let defaults = InMemoryDefaults()
        let model = RightPanelPresentationModel(defaults: defaults)
        model.presentRail()
        let transition = ScreenTransitionPanelChange.beforeCanvasChange(current: model.activeCanvasItem, railShown: model.isRailShown, next: item,
            hidesRail: true, hasWorkspace: true)
        #expect(model.isRailShown)
        model.hideRailWithoutClearingCanvasItem()
        model.setActiveCanvasItem(item)
        #expect(transition.fields["panel_before"] == "context_rail")
        #expect(transition.next == ScreenTransitionPanelChange.panelName(canvas: model.activeCanvasItem,
            railShown: model.isRailShown, hasWorkspace: true))
        #expect(transition.fields["direction"] == (item == nil ? "close" : "switch"))
    }

    @Test("Unavailable restoration never begins a transition")
    func unavailableRestore() throws {
        let defaults = InMemoryDefaults()
        let model = RightPanelPresentationModel(defaults: defaults)
        model.dismissRail()
        var began = false
        #expect(model.restoreRememberedItemIfAvailable(rememberedItem: .browser,
            canPresent: { _ in false }, willRestore: { _ in began = true }) == nil)
        #expect(!began)
    }

    @Test("Clearing task selection while Context stays visible is not a panel close")
    func unchangedContext() {
        let panel = ScreenTransitionPanelChange.panelName(canvas: nil, railShown: true, hasWorkspace: true)
        let transition = ScreenTransitionPanelChange(previous: panel, next: panel)
        #expect(transition.fields["direction"] == "none")
        #expect(transition.fields["panel_after"] == "context_rail")
    }

    @Test("Transition sizes count only the selected persistent owner")
    func ownerScopedCounts() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let original = AgentTask(title: "Original", goal: "Original")
        let copy = AgentTask(title: "Imported", goal: "Imported")
        copy.id = original.id
        context.insert(original); context.insert(copy)
        for _ in 0..<2 { context.insert(TaskRun(task: original)) }
        for _ in 0..<7 { context.insert(TaskRun(task: copy)) }
        try context.save()
        #expect(ScreenTransitionTaskFacts.fields(task: original, in: context)["run_count"] == "2")
        #expect(ScreenTransitionTaskFacts.fields(task: copy, in: context)["run_count"] == "7")
        #expect(ScreenTransitionTaskFacts.fields(task: nil, in: context).isEmpty)
    }
}
