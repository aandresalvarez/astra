import Foundation
import Testing
@testable import ASTRA

@Suite("Task generated file open router")
struct TaskGeneratedFileOpenRouterTests {
    @Test("shelf capable generated files use shelf route when handler exists")
    func shelfCapableGeneratedFilesUseShelfRouteWhenHandlerExists() {
        #expect(TaskGeneratedFileOpenRouter.route(
            path: " /tmp/index.html ",
            destination: .browser,
            canOpenInShelf: true
        ) == .shelf(path: "/tmp/index.html"))

        #expect(TaskGeneratedFileOpenRouter.route(
            path: "/tmp/query.sql",
            destination: .query,
            canOpenInShelf: true
        ) == .shelf(path: "/tmp/query.sql"))

        #expect(TaskGeneratedFileOpenRouter.route(
            path: "/tmp/notes.md",
            destination: .files,
            canOpenInShelf: true
        ) == .shelf(path: "/tmp/notes.md"))
    }

    @Test("files fall back to system route without shelf handler or destination")
    func filesFallBackToSystemRouteWithoutShelfHandlerOrDestination() {
        #expect(TaskGeneratedFileOpenRouter.route(
            path: "/tmp/index.html",
            destination: .browser,
            canOpenInShelf: false
        ) == .system(path: "/tmp/index.html"))

        #expect(TaskGeneratedFileOpenRouter.route(
            path: "/tmp/image.png",
            destination: nil,
            canOpenInShelf: true
        ) == .system(path: "/tmp/image.png"))
    }

    @Test("open URL interception only handles shelf capable file URLs")
    func openURLInterceptionOnlyHandlesShelfCapableFileURLs() {
        #expect(TaskGeneratedFileOpenRouter.route(
            fileURL: URL(fileURLWithPath: "/tmp/report.md"),
            canOpenInShelf: true
        ) == .shelf(path: "/tmp/report.md"))

        #expect(TaskGeneratedFileOpenRouter.route(
            fileURL: URL(fileURLWithPath: "/tmp/image.png"),
            canOpenInShelf: true
        ) == nil)

        #expect(TaskGeneratedFileOpenRouter.route(
            fileURL: URL(string: "https://example.com/report.md")!,
            canOpenInShelf: true
        ) == nil)

        #expect(TaskGeneratedFileOpenRouter.route(
            fileURL: URL(fileURLWithPath: "/tmp/report.md"),
            canOpenInShelf: false
        ) == nil)
    }

    @Test("text shelf affordance includes only files destination items")
    func textShelfAffordanceIncludesOnlyFilesDestinationItems() {
        let items = [
            TaskFileItem(path: "/tmp/index.html", source: "output", destination: .browser),
            TaskFileItem(path: "/tmp/report.md", source: "output", destination: .files),
            TaskFileItem(path: "/tmp/data.json", source: "output", destination: .files),
            TaskFileItem(path: "/tmp/image.png", source: "output", destination: nil)
        ]

        #expect(TaskGeneratedFileOpenRouter.textShelfItems(items).map(\.path) == [
            "/tmp/report.md",
            "/tmp/data.json"
        ])
        #expect(TaskGeneratedFileOpenRouter.canOpenTextShelfItems(items, canOpenInShelf: true))
        #expect(!TaskGeneratedFileOpenRouter.canOpenTextShelfItems(items, canOpenInShelf: false))
    }
}
