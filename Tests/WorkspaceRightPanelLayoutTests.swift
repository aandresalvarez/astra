import CoreGraphics
import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace right panel layout")
struct WorkspaceRightPanelLayoutTests {
    private static let shelves: [WorkspaceCanvasItem] = [.markdown, .browser, .plan, .query, .appPreview]
    private static let otherSurfaces: [ContentDetailPresentation] = [
        .newTaskComposer, .draftTask, .workspaceHome, .workspaceAppStudio, .workspaceApp, .noWorkspace
    ]
    // The first pair reproduces the Dev window where Files hid New Task's Run
    // button. Smaller windows and a shelf wider than the detail exercise bounds.
    private let widths: [(available: CGFloat, shelf: CGFloat)] = [(1_152, 612), (900, 420), (480, 620)]

    @Test("Shelves leave the whole composer and other detail surfaces unobscured",
          arguments: otherSurfaces, shelves)
    func shelvesReserveSpace(surface: ContentDetailPresentation, shelf: WorkspaceCanvasItem) {
        let mode = WorkspaceRightPanelLayoutMode.resolve(
            panel: .canvas(shelf), usesInspectorOverlay: false, detailPresentation: surface
        )
        for (available, panel) in widths {
            let remaining = max(0, available - panel)
            #expect(mode.detailProposalWidth(availableWidth: available, panelWidth: panel) == remaining)
            #expect(mode.detailUnobscuredWidth(availableWidth: available, panelWidth: panel) == remaining)
        }
    }

    @Test("Existing task transcripts retain their stable proposal beside every shelf", arguments: shelves)
    func existingTaskPreservesProposal(shelf: WorkspaceCanvasItem) {
        let mode = WorkspaceRightPanelLayoutMode.resolve(
            panel: .canvas(shelf), usesInspectorOverlay: false, detailPresentation: .existingTask
        )
        for (available, panel) in widths {
            #expect(mode.detailProposalWidth(availableWidth: available, panelWidth: panel) == available)
            #expect(mode.detailUnobscuredWidth(availableWidth: available, panelWidth: panel) == max(0, available - panel))
        }
    }

    @Test("Closing a shelf and opening Workspace Context preserve each surface's layout",
          arguments: otherSurfaces + [.existingTask])
    func detailAndContextPlacement(surface: ContentDetailPresentation) {
        let closed = WorkspaceRightPanelLayoutMode.resolve(
            panel: nil, usesInspectorOverlay: false, detailPresentation: surface
        )
        let context = WorkspaceRightPanel.context(UUID())
        let docked = WorkspaceRightPanelLayoutMode.resolve(
            panel: context, usesInspectorOverlay: false, detailPresentation: surface
        )
        let overlay = WorkspaceRightPanelLayoutMode.resolve(
            panel: context, usesInspectorOverlay: true, detailPresentation: surface
        )
        for (available, panel) in widths {
            #expect(closed.detailProposalWidth(availableWidth: available, panelWidth: 0) == available)
            #expect(closed.detailUnobscuredWidth(availableWidth: available, panelWidth: 0) == available)
            #expect(docked.detailProposalWidth(availableWidth: available, panelWidth: panel) == max(0, available - panel))
            #expect(docked.detailUnobscuredWidth(availableWidth: available, panelWidth: panel) == max(0, available - panel))
            #expect(overlay.detailProposalWidth(availableWidth: available, panelWidth: panel) == available)
            #expect(overlay.detailUnobscuredWidth(availableWidth: available, panelWidth: panel) == available)
        }
    }
}
