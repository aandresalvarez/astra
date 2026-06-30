import Testing
@testable import ASTRA

@Suite("Shelf artifact router")
struct ShelfArtifactRouterTests {
    @Test("HTML routes to Browser shelf")
    func htmlRoutesToBrowserShelf() {
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/index.html") == .browser)
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/preview.HTM") == .browser)
    }

    @Test("SQL routes to Query shelf")
    func sqlRoutesToQueryShelf() {
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/report.sql") == .query)
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/report.SQL") == .query)
    }

    @Test("Markdown routes to Files shelf")
    func markdownRoutesToFilesShelf() {
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/report.md") == .files)
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/report.markdown") == .files)
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/report.qmd") == .files)
    }

    @Test("Unknown file has no shelf destination")
    func unknownFileHasNoShelfDestination() {
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/image.png") == nil)
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/archive.zip") == nil)
        #expect(ShelfArtifactRouter.shelfID(for: "/tmp/random-output") == nil)
    }
}
