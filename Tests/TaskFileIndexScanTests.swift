import Foundation
import Testing
@testable import ASTRA

/// This scan runs on the main actor over the task folder, which in production
/// reached 13,295 artifacts, and it used to resolve symlinks on every child it
/// had already been handed pre-filtered. These tests pin the properties the
/// removed work was there for — nothing outside the root is listed, a root
/// reached through a symlink still enumerates, and a link *inside* the folder
/// is still an artifact — so the cheap version cannot quietly become the wrong
/// version. That last one is not hypothetical: it was wrong.
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

    /// The other half of that rule, and the one the cheap version got wrong. A
    /// link that stays inside the folder is an ordinary artifact — an agent that
    /// leaves `latest.md -> report.md` has produced something the user should
    /// see. Classifying off the unresolved entry drops it, because
    /// `isRegularFile` is false for a symlink however ordinary its target, and
    /// only symlinks are affected: nothing else in the folder needs resolving to
    /// be classified.
    @Test("A symlink to a file inside the folder is listed")
    func inRootSymlinksAreListed() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try "deliverable".write(to: fixture.root.appendingPathComponent("report.md"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("latest.md"),
            withDestinationURL: fixture.root.appendingPathComponent("report.md")
        )

        let files = TaskFileIndex.scanTaskFolder(fixture.root.path)

        // Listed as the target, which is what makes the link and the file it
        // points at one shelf entry rather than two: the caller dedupes on
        // `path`, and a link keyed on its own path would collide with nothing.
        #expect(Set(files.map(\.name)) == ["report.md"])
        #expect(files.count == 2)
    }

    /// `TaskGeneratedFiles.files` is the other list built from the same folder,
    /// and it never stopped resolving. Two answers to "what did this task
    /// produce" is the actual defect; this is the assertion that would have
    /// caught it.
    @Test("The shelf scan and TaskGeneratedFiles agree about a symlinked artifact")
    func scanAgreesWithTaskGeneratedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try "deliverable".write(to: fixture.root.appendingPathComponent("report.md"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("latest.md"),
            withDestinationURL: fixture.root.appendingPathComponent("report.md")
        )

        let scanned = Set(TaskFileIndex.scanTaskFolder(fixture.root.path).map(\.path))
        let generated = Set(TaskGeneratedFiles.files(in: fixture.root.path))

        #expect(scanned == generated)
        #expect(!scanned.isEmpty)
    }

    /// A broken link resolves to a path that is not a regular file, so it is
    /// dropped at the same guard an ordinary missing file is. Worth pinning:
    /// resolving before classifying is what makes that true, and a resolve that
    /// silently returned the link path would put a dead entry on the shelf.
    @Test("A symlink with no target is not listed")
    func danglingSymlinksAreExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try "deliverable".write(to: fixture.root.appendingPathComponent("report.md"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("gone.md"),
            withDestinationURL: fixture.root.appendingPathComponent("never-written.md")
        )

        #expect(TaskFileIndex.scanTaskFolder(fixture.root.path).map(\.name) == ["report.md"])
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
