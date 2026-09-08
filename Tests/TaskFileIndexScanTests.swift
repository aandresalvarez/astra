import Foundation
import Testing
@testable import ASTRA

/// This scan runs on the main actor over the task folder, which in production
/// reached 13,295 artifacts, and it used to resolve symlinks on every child it
/// had already been handed pre-filtered. These tests pin the two properties the
/// removed work was there for — nothing outside the root is listed, and a root
/// reached through a symlink still enumerates — so the cheap version cannot
/// quietly become the wrong version.
@Suite("Task folder scan")
struct TaskFileIndexScanTests {

    @Test("Files inside the task folder are listed")
    func listsFilesInsideTheFolder() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try "deliverable".write(to: fixture.root.appendingPathComponent("report.md"),
                                atomically: true, encoding: .utf8)
        let nested = fixture.root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "nested".write(to: nested.appendingPathComponent("deep.txt"),
                           atomically: true, encoding: .utf8)

        let names = Set(TaskFileIndex.scanTaskFolder(fixture.root.path).map(\.name))

        #expect(names == ["report.md", "deep.txt"])
    }

    /// The containment check that used to live in this loop is still enforced,
    /// one layer down, by the filtering enumerator — which resolves symlinks on
    /// both the child and the root to do it. A link out of the task folder must
    /// not put a file the user never produced into their Files shelf.
    @Test("A symlink pointing out of the folder is not listed")
    func symlinksLeavingTheFolderAreExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try "deliverable".write(to: fixture.root.appendingPathComponent("report.md"),
                                atomically: true, encoding: .utf8)
        let outsideFile = fixture.outside.appendingPathComponent("elsewhere.txt")
        try "outside the task folder".write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("escape.txt"),
            withDestinationURL: outsideFile
        )

        let files = TaskFileIndex.scanTaskFolder(fixture.root.path)

        #expect(files.map(\.name) == ["report.md"])
        #expect(!files.contains { $0.path.contains("elsewhere.txt") })
    }

    /// The loop no longer resolves each child, so the `rootPath` prefix guard
    /// only holds because the *root* is resolved before enumeration begins. A
    /// symlinked root is the case that would break if that ever stopped being
    /// true — and it is not hypothetical: `/var` and `/tmp` are both symlinks.
    @Test("A task folder reached through a symlink still enumerates")
    func symlinkedRootStillEnumerates() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try "deliverable".write(to: fixture.root.appendingPathComponent("report.md"),
                                atomically: true, encoding: .utf8)
        let alias = fixture.container.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)

        #expect(TaskFileIndex.scanTaskFolder(alias.path).map(\.name) == ["report.md"])
    }

    private struct Fixture {
        let container: URL
        let root: URL
        let outside: URL

        init() throws {
            container = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("astra-task-file-index-\(UUID().uuidString)")
            root = container.appendingPathComponent("task")
            outside = container.appendingPathComponent("outside")
            for directory in [root, outside] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: container)
        }
    }
}
