import Foundation
import Testing
import ASTRACore
import ASTRAPersistence
@testable import ASTRA

// Opening a task with a 30,000-file folder spent 9 of its 14 s re-asking the
// filesystem, per file, what the directory listing had already said: several
// symlink resolves, a stat and an attribute read each. The walk now settles a
// plain file from the listing and leaves only symlinks to the per-file checks.
// A FileManager other than `.default` still takes the per-file path, which is
// what these tests compare the listing against.
@Suite("Task folder walk")
struct TaskFolderWalkTests {
    private struct Fixture {
        let base: URL
        let root: URL
        let plainFiles: [String]

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// Displayable files at several depths, files the policy hides, a
    /// dependency folder, and symlinks to a file and a folder inside the root
    /// and to a file and a folder outside it.
    private func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-folder-walk-\(UUID().uuidString)")
        let root = base.appendingPathComponent("task")
        let outside = base.appendingPathComponent("outside")
        let plain = ["report.md", "analysis/table.json", "analysis/deep/run.py", "evidence/a/b/c/notes.txt"]
        let hidden = ["current_state.json", "outputs/turn_001.md", "node_modules/pkg/index.js"]
        for relative in plain + hidden {
            let url = root.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try relative.write(to: url, atomically: true, encoding: .utf8)
        }
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link-to-report.md"),
            withDestinationURL: root.appendingPathComponent("report.md"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link-to-analysis"),
            withDestinationURL: root.appendingPathComponent("analysis"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link-out.md"),
            withDestinationURL: outside.appendingPathComponent("secret.md"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link-out"), withDestinationURL: outside)
        return Fixture(base: base, root: root, plainFiles: plain)
    }

    @Test("The listing settles each plain file, and the walk lists what checking every file listed")
    func listingSettlesPlainFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let folder = fixture.root.path

        let entries = try #require(TaskGeneratedFiles.entries(in: folder, fileManager: .default, isCancelled: { false }))
        let resolvedRoot = fixture.root.resolvingSymlinksInPath().standardizedFileURL.path
        let verified = entries.filter(\.isVerified)
        #expect(Set(verified.map(\.path)) == Set(fixture.plainFiles.map { resolvedRoot + "/" + $0 }))
        for entry in verified {
            let date = try FileManager.default.attributesOfItem(atPath: entry.path)[.modificationDate] as? Date
            #expect(entry.modifiedAt == date, "\(entry.path)")
        }
        // The link to a file inside resolves to that file and is checked on its own.
        #expect(entries.filter { !$0.isVerified }.map(\.path) == [resolvedRoot + "/report.md"])

        #expect(TaskGeneratedFiles.files(in: folder) == TaskGeneratedFiles.files(in: folder, fileManager: FileManager()))
        let discovered = TaskOutputDiscovery.files(in: folder)
        #expect(discovered == TaskOutputDiscovery.files(in: folder, fileManager: FileManager()))
        #expect(Set(discovered.map(\.relativePath)) == Set(fixture.plainFiles))
        #expect(discovered.allSatisfy { $0.modifiedAt != nil })
    }

    @Test("A path called standardized is exactly what standardizing it writes")
    func standardizedFormIsTheRoundTrip() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let plain = ["/a", "/Users/x/Documents/task/report.md", "/a/.hidden/b c.txt", "/a/b%20c", "/a/ü/日本.md",
                     "/a/..b/c", "/a/b../c", "/a/.../c", temporary + "/x.json"]
        let unsure = ["/", "a/b", "/a/", "/a//b", "/a/./b", "/a/../b", "/a/.", "/a/..", "~/a", "/a/~b",
                      "/private/tmp/x", "/private", "/private/var/folders/x"]
        for path in plain {
            #expect(FilePathForm.isStandardizedAbsolute(path), "\(path)")
        }
        for path in plain + unsure where FilePathForm.isStandardizedAbsolute(path) {
            #expect(URL(fileURLWithPath: path).standardizedFileURL.path == path, "\(path)")
        }
        for path in unsure {
            #expect(!FilePathForm.isStandardizedAbsolute(path), "\(path)")
        }
    }

    @Test("A folder reached through a symlink walks the same either way, and nothing outside the root is listed")
    func symlinkedFolderAndEscapes() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let alias = fixture.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)

        for folder in [fixture.root.path, alias.path] {
            let listed = TaskGeneratedFiles.files(in: folder)
            #expect(listed == TaskGeneratedFiles.files(in: folder, fileManager: FileManager()), "\(folder)")
            #expect(TaskOutputDiscovery.files(in: folder) == TaskOutputDiscovery.files(in: folder, fileManager: FileManager()))
            #expect(!listed.contains { $0.hasSuffix("secret.md") || $0.contains("/outside/") })
            #expect(!listed.contains { $0.contains("node_modules") || $0.hasSuffix("current_state.json") })
        }
    }
}
