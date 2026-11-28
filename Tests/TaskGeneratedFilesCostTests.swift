import Foundation
import Testing
@testable import ASTRA

/// A long task's folder listed 31,774 files, and the transcript paid for the
/// whole list on every `TaskMainView` body pass: the files card recounted
/// basenames once per row (~0.8 s a pass, a hang once expanded), and two
/// `.task(id:)` keys joined every path into a ~6 MB string. These pin the
/// per-pass cost to the visible rows and a revision.
@Suite("Task generated files cost")
struct TaskGeneratedFilesCostTests {
    @Test("Duplicate basenames are counted once per listing, as the per-row count did")
    func duplicateBasenamesMatchThePerRowCount() {
        let paths = (0..<240).map { index in
            "/tmp/task/dir\(index % 7)/\(index % 3 == 0 ? "Report" : "report")\(index % 40).md"
        } + ["/tmp/task/notes.md", "/tmp/task/sub/Notes.MD", "/tmp/task/unique.txt"]
        let perRow = Set(Dictionary(grouping: paths.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() },
                                    by: { $0 }).filter { $0.value.count > 1 }.keys)

        let listing = TaskGeneratedFileListing(paths: paths)

        #expect(listing.duplicateBasenames == perRow)
        #expect(listing.duplicateBasenames.contains("notes.md"))
        #expect(!listing.duplicateBasenames.contains("unique.txt"))
        #expect(TaskFileIndex.displayName(for: "/tmp/task/sub/Notes.MD", duplicateBasenames: listing.duplicateBasenames)
            == "sub/Notes.MD")
        #expect(TaskFileIndex.displayName(for: "/tmp/task/unique.txt", duplicateBasenames: listing.duplicateBasenames)
            == "unique.txt")
    }

    @Test("The files card lays out a bounded number of rows however large the folder")
    func filesCardRowsAreBounded() {
        typealias Presentation = AgentGeneratedFilesListPresentation
        func paths(_ count: Int) -> [String] { (0..<count).map { "/tmp/task/file\($0).md" } }

        let huge = paths(31_774)
        for isExpanded in [false, true] {
            let visible = Presentation.visiblePaths(huge, isExpanded: isExpanded)
            #expect(visible.count == Presentation.collapsedRowLimit)
            #expect(Presentation.overflow(pathCount: huge.count, visibleCount: visible.count) == .openFilesIndex)
        }

        let short = paths(20)
        let collapsed = Presentation.visiblePaths(short, isExpanded: false)
        #expect(collapsed.count == Presentation.collapsedRowLimit)
        #expect(Presentation.overflow(pathCount: short.count, visibleCount: collapsed.count) == .expandInline)
        let expanded = Presentation.visiblePaths(short, isExpanded: true)
        #expect(Array(expanded) == short)
        #expect(Presentation.overflow(pathCount: short.count, visibleCount: expanded.count) == .allShown)

        let limit = paths(Presentation.expandedRowLimit)
        #expect(Presentation.visiblePaths(limit, isExpanded: true).count == Presentation.expandedRowLimit)
        let overLimit = paths(Presentation.expandedRowLimit + 1)
        #expect(Presentation.visiblePaths(overLimit, isExpanded: true).count == Presentation.collapsedRowLimit)
        #expect(Presentation.overflow(pathCount: 3, visibleCount: 3) == .allShown)
        #expect(Presentation.filesIndexTitle(pathCount: 51) == "Show all 51 in Files")
    }

    @Test("A refresh advances the revision only when the folder's files change")
    @MainActor
    func refreshAdvancesTheRevisionOnlyOnChange() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent("astra-generated-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a/report.md", "b/Report.md", "notes.md"] {
            try write(to: folder.appendingPathComponent(name))
        }
        let viewModel = TaskThreadViewModel()

        viewModel.refreshGeneratedFiles(folder: folder.path)
        await viewModel.waitForGeneratedFilesForTesting()
        #expect(viewModel.generatedFilePaths.count == 3)
        #expect(viewModel.generatedFileListing.duplicateBasenames == ["report.md"])
        #expect(viewModel.generatedFilePathsRevision == 1)

        viewModel.refreshGeneratedFiles(folder: folder.path)
        await viewModel.waitForGeneratedFilesForTesting()
        #expect(viewModel.generatedFilePathsRevision == 1, "The same files must not rerun the keyed work")

        try write(to: folder.appendingPathComponent("c/summary.md"))
        viewModel.refreshGeneratedFiles(folder: folder.path)
        await viewModel.waitForGeneratedFilesForTesting()
        #expect(viewModel.generatedFilePaths.count == 4)
        #expect(viewModel.generatedFilePathsRevision == 2)

        viewModel.refreshGeneratedFiles(folder: "")
        #expect(viewModel.generatedFilePaths.isEmpty)
        #expect(viewModel.generatedFileListing.duplicateBasenames.isEmpty)
        #expect(viewModel.generatedFilePathsRevision == 3)
    }

    @Test("Body-pass work never walks the whole generated-files list")
    func bodyPassWorkNeverWalksTheWholeList() throws {
        let taskMainView = try sourceFile("Astra/Views/TaskMainView.swift")
        let decisionArtifacts = try sourceFile("Astra/Views/TaskMainViewDecisionArtifacts.swift")
        let card = try sourceFile("Astra/Views/Components/AgentGeneratedFilesListView.swift")

        // Both `.task(id:)` keys hear about the folder's files by revision.
        let keys = [
            try code(in: taskMainView, from: "private var headerFileItemsInputSignature: String {",
                     to: "private func recomputeHeaderFileItems()"),
            try code(in: decisionArtifacts, from: "var decisionArtifactPathsInputSignature: String {",
                     to: "func recomputeDecisionArtifactPaths()")
        ]
        for key in keys {
            #expect(key.range(of: #"generatedFilePaths\b"#, options: .regularExpression) == nil)
            #expect(key.contains("threadViewModel.generatedFilePathsRevision"))
        }

        // The card touches the list only through its count and the bounded
        // visible slice, and takes the duplicate basenames precomputed.
        let view = try code(in: card, from: "struct AgentGeneratedFilesListView: View {", to: nil)
        let unbounded = view
            .replacingOccurrences(of: "listing.paths.count", with: "")
            .replacingOccurrences(of: "visiblePaths(listing.paths, isExpanded:", with: "")
        #expect(!unbounded.contains("listing.paths"))
        #expect(!view.contains("duplicateBasenames(in:"))
        #expect(view.contains("duplicateBasenames: listing.duplicateBasenames"))
        #expect(taskMainView.contains("listing: threadViewModel.generatedFileListing"))
    }

    private func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "content".write(to: url, atomically: true, encoding: .utf8)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The text from `from` up to `to` (or the end), with comment lines dropped
    /// so prose about a forbidden call cannot trip the scan.
    private func code(in source: String, from: String, to: String?) throws -> String {
        let start = try #require(source.range(of: from))
        let rest = source[start.lowerBound...]
        var end = rest.endIndex
        if let to {
            end = try #require(rest.range(of: to)).lowerBound
        }
        return rest[..<end]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
