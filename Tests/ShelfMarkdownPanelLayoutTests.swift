import Testing
import CoreGraphics
import Foundation
@testable import ASTRA

@Suite("Shelf Markdown Panel Layout")
struct ShelfMarkdownPanelLayoutTests {
    @Test("document reader hides the file navigator by default")
    func documentReaderHidesFileNavigatorByDefault() {
        let layout = ShelfFileNavigatorLayout.resolve(
            isPresented: false,
            isPinned: false,
            availableWidth: 620
        )

        #expect(layout == .hidden)
    }

    @Test("unpinned file browsing floats over the document")
    func unpinnedFileBrowsingFloatsOverDocument() {
        let layout = ShelfFileNavigatorLayout.resolve(
            isPresented: true,
            isPinned: false,
            availableWidth: 620
        )

        #expect(layout == .floating)
    }

    @Test("pinned file browsing docks when both panes fit")
    func pinnedFileBrowsingDocksWhenBothPanesFit() {
        let layout = ShelfFileNavigatorLayout.resolve(
            isPresented: true,
            isPinned: true,
            availableWidth: ShelfWidthMetrics.filesMinReadableWidth
        )

        #expect(layout == .docked)
    }

    @Test("pinned preference falls back to floating in narrow space")
    func pinnedPreferenceFallsBackToFloatingInNarrowSpace() {
        let layout = ShelfFileNavigatorLayout.resolve(
            isPresented: true,
            isPinned: true,
            availableWidth: ShelfWidthMetrics.filesMinReadableWidth - 1
        )

        #expect(layout == .floating)
    }

    @Test("temporary browser closes after selection while pinned browser remains")
    func selectionRespectsPinnedBrowserIntent() {
        #expect(ShelfFileNavigatorSelectionPolicy.isPresentedAfterSelectingFile(isPinned: false) == false)
        #expect(ShelfFileNavigatorSelectionPolicy.isPresentedAfterSelectingFile(isPinned: true) == true)
    }

    @Test("first Files shelf visit reveals browsing even with a selected document")
    func firstVisitRevealsBrowsing() {
        #expect(ShelfFileNavigatorInitialPresentationPolicy.shouldPresent(
            isPinned: false,
            hasSelectedFile: true,
            hasDiscoveredBrowser: false
        ))
    }

    @Test("empty Files shelf always reveals browsing")
    func emptyShelfRevealsBrowsing() {
        #expect(ShelfFileNavigatorInitialPresentationPolicy.shouldPresent(
            isPinned: false,
            hasSelectedFile: false,
            hasDiscoveredBrowser: true
        ))
    }

    @Test("returning reader stays document-first after discovery")
    func returningReaderStaysDocumentFirst() {
        #expect(!ShelfFileNavigatorInitialPresentationPolicy.shouldPresent(
            isPinned: false,
            hasSelectedFile: true,
            hasDiscoveredBrowser: true
        ))
    }

    @Test("pinned browser remains visible after discovery")
    func pinnedBrowserRemainsVisible() {
        #expect(ShelfFileNavigatorInitialPresentationPolicy.shouldPresent(
            isPinned: true,
            hasSelectedFile: true,
            hasDiscoveredBrowser: true
        ))
    }

    @Test("Files shelf discovery store persists the one-time reveal")
    func discoveryStorePersistsReveal() throws {
        let suiteName = "ShelfFileNavigatorDiscoveryStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!ShelfFileNavigatorDiscoveryStore.hasDiscovered(defaults: defaults))
        ShelfFileNavigatorDiscoveryStore.markDiscovered(defaults: defaults)
        #expect(ShelfFileNavigatorDiscoveryStore.hasDiscovered(defaults: defaults))
    }

    @Test("empty workspace file scope stays on the navigator list surface")
    func emptyWorkspaceFileScopeStaysOnNavigatorListSurface() {
        let presentation = ShelfFileNavigatorContentPresentation.resolve(
            hasFileRoots: true,
            hasVisibleFileRoots: false,
            isSearchingFiles: false,
            isScanningFiles: false
        )

        #expect(presentation == .emptyScope)
        #expect(presentation.usesListSurface)
    }

    @Test("scanning file scope does not present as empty before nodes load")
    func scanningFileScopeDoesNotPresentAsEmptyBeforeNodesLoad() {
        let presentation = ShelfFileNavigatorContentPresentation.resolve(
            hasFileRoots: true,
            hasVisibleFileRoots: false,
            isSearchingFiles: false,
            isScanningFiles: true
        )

        #expect(presentation == .scanning)
        #expect(presentation.usesListSurface)
    }

    @Test("empty search results keep the populated list surface")
    func emptySearchResultsKeepPopulatedListSurface() {
        let presentation = ShelfFileNavigatorContentPresentation.resolve(
            hasFileRoots: true,
            hasVisibleFileRoots: false,
            isSearchingFiles: true,
            isScanningFiles: false
        )

        #expect(presentation == .populatedList)
        #expect(presentation.usesListSurface)
    }

    @Test("missing workspace paths use the same navigator list surface")
    func missingWorkspacePathsUseSameNavigatorListSurface() {
        let presentation = ShelfFileNavigatorContentPresentation.resolve(
            hasFileRoots: false,
            hasVisibleFileRoots: false,
            isSearchingFiles: false,
            isScanningFiles: false
        )

        #expect(presentation == .noWorkspacePaths)
        #expect(presentation.usesListSurface)
    }

    @Test("a lone open file still shows its tab so it keeps a per-file close button")
    func loneOpenFileShowsTabStrip() {
        #expect(ShelfTabStripPolicy.showsTabStrip(openDocumentCount: 1))
    }

    @Test("the empty shelf shows no tab strip")
    func emptyShelfShowsNoTabStrip() {
        #expect(!ShelfTabStripPolicy.showsTabStrip(openDocumentCount: 0))
    }

    @Test("multiple open files keep the tab strip")
    func multipleOpenFilesKeepTabStrip() {
        #expect(ShelfTabStripPolicy.showsTabStrip(openDocumentCount: 2))
    }

    @Test("top-right toolbar stays visible for shelf controls without a workspace")
    func topRightToolbarStaysVisibleForShelfControlsWithoutWorkspace() {
        // The shelf pill is the Files shelf's only dismiss control, so the
        // toolbar must not disappear while a shelf is open in a
        // workspace-less task context.
        #expect(topRightActions(hasWorkspace: false, canShowTextShelf: true).showsToolbar)
        #expect(topRightActions(hasWorkspace: true, canShowTextShelf: false).showsToolbar)
        #expect(!topRightActions(hasWorkspace: false, canShowTextShelf: false).showsToolbar)
    }

    private func topRightActions(hasWorkspace: Bool, canShowTextShelf: Bool) -> WorkspaceTopRightActions {
        WorkspaceTopRightActions(
            hasWorkspace: hasWorkspace,
            canShowPlanShelf: false,
            canShowTextShelf: canShowTextShelf,
            canShowBrowserShelf: false,
            canShowQueryShelf: false,
            canShowAppPreviewShelf: false,
            activeCanvasItem: canShowTextShelf ? .markdown : nil,
            browserEngine: .embedded,
            isRightRailVisible: false
        )
    }
}
