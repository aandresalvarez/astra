import Testing
import CoreGraphics
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
}
