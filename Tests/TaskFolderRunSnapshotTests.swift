import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
import ASTRACore
@testable import ASTRA

@Suite("Task folder run snapshot")
@MainActor
struct TaskFolderRunSnapshotTests {
    @Test("A before/after comparison reports created, modified, and removed files")
    func reportsCreatedModifiedAndRemoved() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("kept", to: folder, "README.md")
        try write("v1", to: folder, "plan.md")
        try write("old", to: folder, "reports/old.md")

        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        try write("version two", to: folder, "plan.md")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("reports/old.md"))
        try write("new", to: folder, "reports/new.md")
        let after = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))

        let changes = after.changes(since: before)
        #expect(changes.map(\.relativePath) == ["plan.md", "reports/new.md", "reports/old.md"])
        #expect(changes.map(\.kind) == [.modified, .created, .removed])
    }

    @Test("Bookkeeping, hidden files, and dependency trees are not the run's work")
    func ignoresFilesTheShelfHides() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))

        for path in [
            "outputs/turn_001.md",
            "session_history.md",
            "current_state.json",
            "inputs/astra_paste_1.txt",
            "diagnostics/run_resource_manifest_1.json",
            ".DS_Store",
            "node_modules/pkg/index.js",
            ".venv/bin/python"
        ] {
            try write("x", to: folder, path)
        }
        try write("deliverable", to: folder, "answer.md")
        let after = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))

        #expect(after.changes(since: before).map(\.relativePath) == ["answer.md"])
    }

    @Test("A task folder the run creates starts from an empty snapshot")
    func missingFolderIsAnEmptyBaseline() throws {
        let parent = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("not-yet", isDirectory: true)

        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        #expect(before.entries.isEmpty)
        try write("first", to: folder, "notes.md")
        let after = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))

        #expect(after.changes(since: before).map(\.kind) == [.created])
    }

    @Test("A folder past the walk limit is not snapshotted rather than half-compared")
    func folderPastTheLimitIsSkipped() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<5 {
            try write("\(index)", to: folder, "data/\(index).csv")
        }

        #expect(TaskFolderRunSnapshot.scan(taskFolder: folder.path, entryLimit: 4) == nil)
        #expect(TaskFolderRunSnapshot.scan(taskFolder: folder.path, entryLimit: 6)?.entries.count == 5)
    }

    @Test("Paths a tool already recorded keep that record, under either spelling of the root")
    func toolRecordedPathsAreNotRepeated() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        // A task folder reached through a symlink, as `/var` → `/private/var` is.
        let link = fixture.folder.appendingPathComponent("linked-task-folder")
        let target = fixture.folder.appendingPathComponent("real-task-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(link.path)
        #expect(root.standardized != root.resolved)
        fixture.run.appendFileChange(StoredFileChange(
            path: root.resolved + "/written.md",
            changeType: StoredFileChangeKind.write.rawValue,
            content: "tool content"
        ))

        let stored = TaskFolderRunSnapshot.append(
            [
                .init(relativePath: "written.md", kind: .created, modifiedAt: nil),
                .init(relativePath: "script-output.csv", kind: .created, modifiedAt: nil)
            ],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date()
        )

        #expect(stored.map(\.path) == [root.standardized + "/script-output.csv"])
        #expect(fixture.run.allFileChanges.map(\.kind) == [.write, .discovered])
        #expect(fixture.run.allFileChanges.first?.content == "tool content")
    }

    @Test("A same-length rewrite whose modified time was put back still reads as an edit")
    func sameLengthRewriteWithPreservedModifiedTimeIsAnEdit() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = folder.appendingPathComponent("plan.md")
        // Whole seconds, as a coarse-timestamp filesystem would store them.
        let modifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
        try write("aaaa", to: folder, "plan.md")
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: plan.path)
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))

        // In place, so the file keeps its identifier: only the kernel's
        // status-change time can tell.
        try "bbbb".write(to: plan, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: plan.path)
        let after = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))

        #expect(after.entries["plan.md"]?.fileIdentifier == before.entries["plan.md"]?.fileIdentifier)
        #expect(after.entries["plan.md"]?.size == before.entries["plan.md"]?.size)
        #expect(after.entries["plan.md"]?.modifiedAt == modifiedAt)
        #expect(after.changes(since: before).map(\.kind) == [.modified])
    }

    @Test("A visible file whose metadata cannot be read voids the snapshot; a hidden one does not")
    func unreadableMetadataVoidsTheSnapshot() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("plan", to: folder, "plan.md")
        try write("{}", to: folder, "current_state.json")
        struct Unreadable: Error {}
        func failing(on name: String) -> (URL, Set<URLResourceKey>) throws -> URLResourceValues {
            { url, keys in
                if url.lastPathComponent == name { throw Unreadable() }
                return try url.resourceValues(forKeys: keys)
            }
        }

        #expect(TaskFolderRunSnapshot.scan(taskFolder: folder.path, readValues: failing(on: "plan.md")) == nil)
        let snapshot = TaskFolderRunSnapshot.scan(taskFolder: folder.path, readValues: failing(on: "current_state.json"))
        #expect(snapshot?.entries.keys.sorted() == ["plan.md"])
    }

    @Test("Small files carry a content fingerprint, and it only counts when both walks took one")
    func contentFingerprintSeparatesSameLengthRewrites() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("aaaa", to: folder, "small.md")
        try write(String(repeating: "x", count: 64), to: folder, "large.md")

        let snapshot = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path, fingerprintFileLimit: 16))
        #expect(snapshot.entries["small.md"]?.contentFingerprint != nil)
        #expect(snapshot.entries["large.md"]?.contentFingerprint == nil)
        let unbudgeted = TaskFolderRunSnapshot.scan(taskFolder: folder.path, fingerprintByteBudget: 0)
        #expect(unbudgeted?.entries.values.allSatisfy { $0.contentFingerprint == nil } == true)

        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        func entry(_ fingerprint: UInt64?) -> TaskFolderRunSnapshot.Entry {
            .init(size: 4, modifiedAt: stamp, statusChangedAt: stamp, fileIdentifier: 7, contentFingerprint: fingerprint)
        }
        #expect(entry(1).differs(from: entry(2)))
        #expect(!entry(1).differs(from: entry(1)))
        #expect(!entry(1).differs(from: entry(nil)))
    }

    @Test("One observation too long for the byte budget leaves room for shorter ones")
    func oversizedObservationDoesNotBlockShorterOnes() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)
        fixture.run.appendFileChange(StoredFileChange(
            path: root.standardized + "/big.md",
            changeType: "Write",
            content: String(repeating: "x", count: TaskRun.displayedFileChangesJSONByteLimit - 1_500)
        ))
        let longName = "a-" + String(repeating: "long", count: 500) + ".md"

        let stored = TaskFolderRunSnapshot.append(
            [
                .init(relativePath: longName, kind: .created, modifiedAt: nil),
                .init(relativePath: "b.csv", kind: .created, modifiedAt: nil)
            ],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date()
        )

        #expect(stored.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["b.csv"])
        #expect(fixture.run.fileChangesJSON.utf8.count <= TaskRun.displayedFileChangesJSONByteLimit)
    }

    @Test("A file the run's tools wrote and a shell command deleted is recorded as removed")
    func writtenThenDeletedFileIsRecordedAsRemoved() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        // Written and deleted inside the run, so neither walk sees either file.
        try write("draft", to: folder, "notes/draft.md")
        try write("rows", to: folder, "scratch.csv")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("notes/draft.md"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("scratch.csv"))
        // A tool's change is recorded once its result succeeds, so it proves
        // the file existed; one path is relative to the working directory.
        let recordedJSON = TaskEvent.payloadString([
            StoredFileChange(path: folder.path + "/notes/draft.md", changeType: "Write"),
            StoredFileChange(path: "scratch.csv", changeType: "Edit")
        ])
        let runEndedAt = Date()

        let observation = try TaskFolderRunSnapshot.observe(
            since: before,
            recordedJSON: recordedJSON,
            executionPath: folder.path,
            runStartedAt: runEndedAt.addingTimeInterval(-5),
            runEndedAt: runEndedAt
        ).get()

        #expect(observation.records.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["draft.md", "scratch.csv"])
        #expect(observation.records.map(\.kind) == [.removed, .removed])
        #expect(observation.records.map(\.timestamp) == [runEndedAt, runEndedAt])
        #expect(observation.inferredRemovalCount == 2)
    }

    @Test("A written file that is still there is not read as removed, even where the walk cannot see it")
    func writtenFileStillOnDiskIsUntouched() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try makeFolder()
        defer { try? FileManager.default.removeItem(at: target) }
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        try write("kept", to: folder, "kept.md")
        // The walk skips a symlink, so only the path itself says it is there.
        try write("real", to: target, "real.md")
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.md"),
            withDestinationURL: target.appendingPathComponent("real.md")
        )
        let recordedJSON = TaskEvent.payloadString([
            StoredFileChange(path: folder.path + "/kept.md", changeType: "Write"),
            StoredFileChange(path: folder.path + "/linked.md", changeType: "Write")
        ])

        let observation = try TaskFolderRunSnapshot.observe(
            since: before,
            recordedJSON: recordedJSON,
            executionPath: folder.path,
            runStartedAt: Date().addingTimeInterval(-5),
            runEndedAt: Date()
        ).get()

        #expect(observation.records.isEmpty)
        #expect(observation.inferredRemovalCount == 0)
    }

    @Test("A written path outside the task folder, or one the walk never lists, is not read as removed")
    func writesTheWalkCannotSeeAreIgnored() throws {
        let workspace = try makeFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folder = workspace.appendingPathComponent("task", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        // Nothing is on disk at any of these paths.
        let recordedJSON = TaskEvent.payloadString([
            StoredFileChange(path: workspace.path + "/README.md", changeType: "Write"),
            StoredFileChange(path: "/tmp/astra-elsewhere-\(UUID().uuidString).md", changeType: "Write"),
            StoredFileChange(path: folder.path + "/outputs/turn_001.md", changeType: "Write"),
            StoredFileChange(path: folder.path + "/.cache/state.json", changeType: "Write")
        ])

        let observation = try TaskFolderRunSnapshot.observe(
            since: before,
            recordedJSON: recordedJSON,
            executionPath: workspace.path,
            runStartedAt: Date().addingTimeInterval(-5),
            runEndedAt: Date()
        ).get()

        #expect(observation.records.isEmpty)
        #expect(observation.inferredRemovalCount == 0)
    }

    @Test("A change record that cannot be decoded is left alone, not replaced by observations")
    func undecodableRecordIsLeftAlone() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        try write("rows", to: folder, "report.csv")

        let outcome = TaskFolderRunSnapshot.observe(
            since: before,
            recordedJSON: "{not json",
            executionPath: folder.path,
            runStartedAt: Date().addingTimeInterval(-5),
            runEndedAt: Date()
        )
        #expect(throws: TaskFolderRunSnapshot.ObservationSkip.undecodableRecord) { try outcome.get() }

        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        fixture.run.fileChangesJSON = "{not json"
        fixture.run.appendHostFileChanges([StoredFileChange(path: "/tmp/a.md", changeType: "discovered")])
        #expect(fixture.run.fileChangesJSON == "{not json")
    }

    @Test("A fingerprint never reads past its limit, even if the file grew after its size was read")
    func fingerprintReadIsBounded() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(String(repeating: "x", count: 100), to: folder, "grown.md")
        let url = folder.appendingPathComponent("grown.md")
        let intent = HostFileAccessIntent.astraManagedStorage(root: folder)

        let tooBig = TaskFolderRunSnapshot.contentFingerprint(of: url, maxBytes: 50, intent: intent)
        #expect(tooBig.fingerprint == nil)
        #expect(tooBig.bytesRead == 51)

        let fits = TaskFolderRunSnapshot.contentFingerprint(of: url, maxBytes: 200, intent: intent)
        #expect(fits.fingerprint != nil)
        #expect(fits.bytesRead == 100)
    }

    @Test("The record count limit counts records kept, not records skipped for size")
    func countLimitAppliesAfterSizeFiltering() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)
        fixture.run.appendFileChange(StoredFileChange(
            path: root.standardized + "/big.md",
            changeType: "Write",
            content: String(repeating: "x", count: TaskRun.displayedFileChangesJSONByteLimit - 1_500)
        ))
        let long = String(repeating: "long", count: 500)

        let stored = TaskFolderRunSnapshot.append(
            [
                .init(relativePath: "a1-\(long).md", kind: .created, modifiedAt: nil),
                .init(relativePath: "a2-\(long).md", kind: .created, modifiedAt: nil),
                .init(relativePath: "b.csv", kind: .created, modifiedAt: nil),
                .init(relativePath: "c.csv", kind: .created, modifiedAt: nil)
            ],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date(),
            limit: 2
        )

        #expect(stored.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["b.csv", "c.csv"])
    }

    @Test("A record already past the decode limit grows by a bounded allowance, not without limit")
    func overLimitRecordGrowsByABoundedAllowance() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)
        fixture.run.appendFileChange(StoredFileChange(
            path: root.standardized + "/big.md",
            changeType: "Write",
            content: String(repeating: "x", count: TaskRun.displayedFileChangesJSONByteLimit + 10_000)
        ))
        let usedBytes = fixture.run.fileChangesJSON.utf8.count
        let folderName = String(repeating: "f", count: 300)

        let stored = TaskFolderRunSnapshot.append(
            (0..<250).map { .init(relativePath: "\(folderName)/\($0).csv", kind: .created, modifiedAt: nil) },
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date()
        )

        #expect(!stored.isEmpty)
        #expect(stored.count < 250)
        #expect(fixture.run.fileChangesJSON.utf8.count - usedBytes <= TaskFolderRunSnapshot.overLimitByteAllowance)
    }

    @Test("Observations the bounds leave out are counted, for the audit line")
    func omittedObservationsAreCounted() {
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot("/ws/task")
        let bounded = TaskFolderRunSnapshot.records(
            for: [
                .init(relativePath: "a.md", kind: .created, modifiedAt: nil),
                .init(relativePath: "b.md", kind: .modified, modifiedAt: nil),
                .init(relativePath: "c.md", kind: .removed, modifiedAt: nil)
            ],
            under: root,
            recorded: [StoredFileChange(path: "/ws/task/b.md", changeType: "Edit")],
            usedBytes: 2,
            executionPath: "/ws",
            runStartedAt: Date(),
            runEndedAt: Date(),
            limit: 1
        )

        // b.md is already recorded by its tool edit, so it is neither kept
        // nor omitted; of a.md and c.md the limit keeps one.
        #expect(bounded.records.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["a.md"])
        #expect(bounded.omitted == 1)
    }

    @Test("The after-run comparison and bounding run off the main actor")
    func observationRunsOffTheMainActor() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(TaskFolderRunSnapshot.scan(taskFolder: folder.path))
        try write("rows", to: folder, "report.csv")
        let started = Date().addingTimeInterval(-5)

        let observation = await Task.detached {
            try? TaskFolderRunSnapshot.observe(
                since: before,
                recordedJSON: "[]",
                executionPath: folder.path,
                runStartedAt: started,
                runEndedAt: Date()
            ).get()
        }.value

        #expect(observation?.changeCount == 1)
        #expect(observation?.records.map(\.kind) == [.discovered])
    }

    @Test("A directory the walk cannot read voids the snapshot instead of reading as removals")
    func unreadableDirectoryVoidsTheSnapshot() throws {
        let folder = try makeFolder()
        let locked = folder.appendingPathComponent("reports", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try write("q3", to: folder, "reports/q3.md")
        #expect(TaskFolderRunSnapshot.scan(taskFolder: folder.path)?.entries.count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        #expect(TaskFolderRunSnapshot.scan(taskFolder: folder.path) == nil)
    }

    @Test("A path a tool recorded relative to its working directory is not recorded twice")
    func relativeToolPathsAreNotRepeated() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.appendingPathComponent("task").path)
        fixture.run.appendFileChange(StoredFileChange(path: "task/written.md", changeType: "Write", content: "x"))

        let stored = TaskFolderRunSnapshot.append(
            [.init(relativePath: "written.md", kind: .created, modifiedAt: nil)],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date()
        )

        #expect(stored.isEmpty)
    }

    @Test("A file a tool edited and a shell command then deleted keeps its removal")
    func removalAfterAToolEditIsKept() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)
        fixture.run.appendFileChange(StoredFileChange(path: root.standardized + "/plan.md", changeType: "Edit"))

        let stored = TaskFolderRunSnapshot.append(
            [.init(relativePath: "plan.md", kind: .removed, modifiedAt: nil)],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date()
        )

        #expect(stored.map(\.kind) == [.removed])
        #expect(fixture.run.allFileChanges.map(\.kind) == [.edit, .removed])
    }

    @Test("Observed changes stop short of the thread's decode limit, so tool changes stay visible")
    func observedChangesFitUnderTheDecodeLimit() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)
        let limit = TaskRun.displayedFileChangesJSONByteLimit
        fixture.run.appendFileChange(StoredFileChange(
            path: root.standardized + "/big.md",
            changeType: "Write",
            content: String(repeating: "x", count: limit - 2_000)
        ))

        let stored = TaskFolderRunSnapshot.append(
            (0..<50).map { .init(relativePath: "rows/\($0).csv", kind: .created, modifiedAt: nil) },
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date()
        )

        #expect(!stored.isEmpty)
        #expect(stored.count < 50)
        #expect(fixture.run.fileChangesJSON.utf8.count <= limit)
        let threadRun = TaskRunSnapshot(input: TaskRunSnapshotInput(run: fixture.run))
        #expect(!threadRun.hasOmittedFileChanges)
        #expect(threadRun.fileChanges.map(\.kind) == [.write])
    }

    @Test("Observed changes are stamped inside the run's window with their kind")
    func observedChangesAreStampedInsideTheRunWindow() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = Date(timeIntervalSinceReferenceDate: 2_000)

        TaskFolderRunSnapshot.append(
            [
                .init(relativePath: "a.md", kind: .created, modifiedAt: Date(timeIntervalSinceReferenceDate: 1_500)),
                .init(relativePath: "b.md", kind: .modified, modifiedAt: Date(timeIntervalSinceReferenceDate: 9_000)),
                .init(relativePath: "c.md", kind: .removed, modifiedAt: nil)
            ],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: start,
            runEndedAt: end
        )

        let changes = fixture.run.allFileChanges
        #expect(changes.map(\.kind) == [.discovered, .modified, .removed])
        #expect(changes.map(\.timestamp) == [Date(timeIntervalSinceReferenceDate: 1_500), end, end])
        #expect(changes.allSatisfy { $0.content == nil })
    }

    @Test("A run records what happened in its task folder, however it was written")
    func recordChangesAppendsToTheRun() async throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let folder = URL(fileURLWithPath: TaskWorkspaceAccess(task: fixture.task).taskFolder, isDirectory: true)
        try write("old", to: folder, "stale.md")
        try write("v1", to: folder, "plan.md")

        let before = await TaskFolderRunSnapshot.capture(for: fixture.task)
        try write("version two", to: folder, "plan.md")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("stale.md"))
        try write("bq output", to: folder, "results/rows.csv")
        try write("turn log", to: folder, "outputs/turn_001.md")
        let stored = await TaskFolderRunSnapshot.recordChanges(
            since: before,
            task: fixture.task,
            run: fixture.run,
            runStartedAt: Date().addingTimeInterval(-5),
            executionPath: fixture.folder.path
        ).records

        let byName = Dictionary(uniqueKeysWithValues: stored.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.kind) })
        #expect(byName == ["plan.md": .modified, "rows.csv": .discovered, "stale.md": .removed])
        #expect(fixture.run.allFileChanges.count == 3)
    }

    @Test("Observed kinds decode by name, and an unrecognized kind reads as unknown")
    func observedKindsRoundTrip() {
        #expect(StoredFileChangeKind(changeType: "modified") == .modified)
        #expect(StoredFileChangeKind(changeType: "removed") == .removed)
        #expect(StoredFileChangeKind.modified.sourceLabel == "edited")
        #expect(StoredFileChangeKind.removed.sourceLabel == "removed")
        #expect(StoredFileChangeKind(changeType: "renamed") == .unknown)
    }

    @Test("A batch append keeps earlier changes and writes the paths as given")
    func batchAppendKeepsEarlierChanges() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        fixture.run.appendFileChange(StoredFileChange(path: "/tmp/one.md", changeType: "Edit"))
        fixture.run.appendHostFileChanges([
            StoredFileChange(path: "/tmp/two.md", changeType: "discovered"),
            StoredFileChange(path: "/tmp/three.md", changeType: "removed")
        ])

        #expect(fixture.run.allFileChanges.map(\.path) == ["/tmp/one.md", "/tmp/two.md", "/tmp/three.md"])
    }

    @Test("Existing readers see only tool evidence, so gates and counts do not move")
    func existingReadersSeeOnlyToolEvidence() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        fixture.run.appendHostFileChanges([
            StoredFileChange(path: "/tmp/new.csv", changeType: "discovered"),
            StoredFileChange(path: "/tmp/plan.md", changeType: "modified"),
            StoredFileChange(path: "/tmp/gone.md", changeType: "removed")
        ])
        // A tool change arriving later must not drop the observed ones.
        fixture.run.appendFileChange(StoredFileChange(path: "/tmp/tool.md", changeType: "Write"))

        #expect(fixture.run.fileChanges.map(\.path) == ["/tmp/tool.md"])
        #expect(fixture.run.allFileChanges.count == 4)
        let threadRun = TaskRunSnapshot(input: TaskRunSnapshotInput(run: fixture.run))
        #expect(threadRun.fileChanges.map(\.path) == ["/tmp/tool.md"])
    }

    @Test("A bulk run records a bounded list, new and edited files first")
    func bulkRunIsCappedWithRemovalsLast() throws {
        let fixture = try makeRun()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(fixture.folder.path)

        let stored = TaskFolderRunSnapshot.append(
            [
                .init(relativePath: "a-removed.md", kind: .removed, modifiedAt: nil),
                .init(relativePath: "b-edited.md", kind: .modified, modifiedAt: nil),
                .init(relativePath: "c-new.md", kind: .created, modifiedAt: nil)
            ],
            under: root,
            to: fixture.run,
            executionPath: fixture.folder.path,
            runStartedAt: Date(),
            runEndedAt: Date(),
            limit: 2
        )

        #expect(stored.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["c-new.md", "b-edited.md"])
    }

    // MARK: - Fixtures

    private struct RunFixture {
        let container: ModelContainer
        let folder: URL
        let task: AgentTask
        let run: TaskRun
    }

    private func makeRun() throws -> RunFixture {
        let folder = try makeFolder()
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspace = Workspace(name: "Snapshot", primaryPath: folder.path)
        let task = AgentTask(title: "Produce files", goal: "Write outputs", workspace: workspace)
        let run = TaskRun(task: task)
        container.mainContext.insert(workspace)
        container.mainContext.insert(task)
        container.mainContext.insert(run)
        return RunFixture(container: container, folder: folder, task: task, run: run)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-task-folder-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to folder: URL, _ relativePath: String) throws {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
