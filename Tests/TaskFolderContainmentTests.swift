import Foundation
import Testing
@testable import HostControlToolSupport

/// The containment rules answer a question about a *pathname*, and a pathname is
/// re-resolved by every `open` that follows it. These cover the gap that leaves:
/// an agent that wins the race between the check and the write gets the file
/// written wherever it likes, and the checks all passed.
@Suite("Task folder containment")
struct TaskFolderContainmentTests {
    private struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-containment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Resolved because `/var` is a link to `/private/var` on macOS, and a
        // root that is itself a link would make every comparison here trivially
        // interesting for the wrong reason.
        return url.resolvingSymlinksInPath()
    }

    /// The regression. The directory is validated, then renamed out of the way
    /// and replaced with a symlink pointing outside the task folder — exactly
    /// what an agent with write access to the task folder can do — and the write
    /// that follows must still land inside.
    ///
    /// A path-based writer fails this: it re-resolves `root/exports` and follows
    /// the new link. A descriptor-based one cannot, because the descriptor names
    /// the inode that was checked and renaming a directory entry does not move
    /// the inode.
    @Test("A directory swapped for a symlink after validation cannot redirect the write")
    func swappingTheDirectoryAfterValidationCannotRedirectTheWrite() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let handle = try TaskFolderContainment.openDirectory(
            named: "exports",
            beneath: root,
            refusal: "write subject data",
            makeError: { FixtureError(message: $0) }
        )

        // The swap, after every check has passed.
        let validated = root.appendingPathComponent("exports")
        try FileManager.default.moveItem(at: validated, to: root.appendingPathComponent("exports-moved"))
        try FileManager.default.createSymbolicLink(
            atPath: validated.path,
            withDestinationPath: outside.path
        )

        try handle.writeExclusively(Data("subject data".utf8), named: "export-1.json")

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("exports-moved").path
        ) == ["export-1.json"])
    }

    /// The name check still has to come first: a link that is already there when
    /// the broker arrives is refused rather than opened, so the descriptor is
    /// never created against something outside the folder in the first place.
    @Test("A pre-existing symlink is refused before a descriptor is opened")
    func preExistingSymlinkIsRefused() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("exports").path,
            withDestinationPath: outside.path
        )

        #expect(throws: FixtureError.self) {
            _ = try TaskFolderContainment.openDirectory(
                named: "exports",
                beneath: root,
                refusal: "write subject data",
                makeError: { FixtureError(message: $0) }
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    /// `O_EXCL`, so a name the agent has already planted is a failure and not a
    /// target. Without it a symlink left under the name the broker is about to
    /// use is followed by the create itself.
    @Test("Writing to a name that is already taken fails instead of following it")
    func takenNameIsNotOverwritten() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let handle = try TaskFolderContainment.openDirectory(
            named: "exports",
            beneath: root,
            refusal: "write subject data",
            makeError: { FixtureError(message: $0) }
        )
        let decoy = outside.appendingPathComponent("stolen.json")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("exports/export-1.json").path,
            withDestinationPath: decoy.path
        )

        #expect(throws: (any Error).self) {
            try handle.writeExclusively(Data("subject data".utf8), named: "export-1.json")
        }
        #expect(!FileManager.default.fileExists(atPath: decoy.path))
    }

    /// A receipt has to name the file the way the rest of the app names it.
    /// `F_GETPATH` answers with the kernel's canonical path — `/private/var/…`
    /// on macOS — where `resolvingSymlinksInPath()` answers `/var/…`. A proposal
    /// recorded under one form is not recognised by a directory scan that
    /// produces the other, so the same staged file becomes two pending reviews
    /// and neither one retires the other.
    @Test("The handle reports the directory by the same name the app uses")
    func handlePathMatchesTheResolvedDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let handle = try TaskFolderContainment.openDirectory(
            named: "exports",
            beneath: root,
            refusal: "write subject data",
            makeError: { FixtureError(message: $0) }
        )
        let written = try handle.writeExclusively(Data(#"{"staged":true}"#.utf8), named: "proposal.json")

        let expected = root.appendingPathComponent("exports", isDirectory: true).resolvingSymlinksInPath()
        #expect(handle.path == expected.path)
        #expect(written == expected.appendingPathComponent("proposal.json").path)
    }

    /// Containment is component-wise. A string prefix says `/tmp/task` contains
    /// `/tmp/task-other`, and it does not.
    @Test("A sibling directory sharing a name prefix is not contained")
    func siblingPrefixIsNotContained() {
        let root = URL(fileURLWithPath: "/tmp/task", isDirectory: true)
        #expect(TaskFolderContainment.contains(URL(fileURLWithPath: "/tmp/task/a/b"), root: root))
        #expect(!TaskFolderContainment.contains(URL(fileURLWithPath: "/tmp/task-other/a"), root: root))
        #expect(!TaskFolderContainment.contains(URL(fileURLWithPath: "/tmp"), root: root))
    }
}
