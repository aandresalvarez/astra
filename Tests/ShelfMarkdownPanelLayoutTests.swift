import Testing
@testable import ASTRA

@Suite("Shelf Markdown Panel Layout")
struct ShelfMarkdownPanelLayoutTests {
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
