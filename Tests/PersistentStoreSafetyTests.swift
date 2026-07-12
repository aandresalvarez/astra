import Foundation
import SQLite3
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Persistent Store Safety")
struct PersistentStoreSafetyTests {
    @Test("Current store generation is isolated from legacy channel binaries")
    func currentStoreGenerationIsIsolated() {
        #expect(WorkspaceRecoveryService.storeGeneration == "g2")
        #expect(WorkspaceRecoveryService.storeURL.path.contains("/Stores/g2/"))
        #expect(WorkspaceRecoveryService.storeURL != WorkspaceRecoveryService.channelLegacyStoreURL)
        #expect(WorkspaceRecoveryService.storeLeaseURL.deletingLastPathComponent() == WorkspaceRecoveryService.storeGenerationDirectory)
    }

    @Test("Unknown model version fails closed instead of entering recovery")
    func unknownModelVersionFailsClosed() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 134_504,
            userInfo: [NSLocalizedDescriptionKey: "Cannot use staged migration with an unknown model version."]
        )

        #expect(PersistentStoreOpenFailurePolicy.decision(for: error) == .incompatibleNewerSchema)
    }

    @Test("Only verified SQLite corruption enters recovery")
    func onlyVerifiedCorruptionEntersRecovery() {
        let corrupt = NSError(domain: "NSSQLiteErrorDomain", code: 11)
        let unknown = NSError(domain: NSCocoaErrorDomain, code: 134_999)

        #expect(PersistentStoreOpenFailurePolicy.decision(for: corrupt) == .verifiedCorruption)
        #expect(PersistentStoreOpenFailurePolicy.decision(for: unknown) == .blockedUnknown)
    }

    @Test("Store open diagnostics contain codes but not localized descriptions")
    func storeOpenDiagnosticsArePrivacySafe() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 134_504,
            userInfo: [NSLocalizedDescriptionKey: "/Users/private/store contents"]
        )
        let fields = PersistentStoreOpenFailurePolicy.diagnosticFields(for: error)
        #expect(fields["error_domains"] == NSCocoaErrorDomain)
        #expect(fields["error_codes"] == "134504")
        #expect(!fields.values.joined().contains("/Users/private"))
    }

    @Test("Legacy migration recovery preserves every store not proven corrupt")
    func legacyMigrationRecoveryFailsClosed() {
        #expect(PersistentStoreOpenFailurePolicy.permitsFreshStoreForLegacyMigration(.verifiedCorruption))
        #expect(!PersistentStoreOpenFailurePolicy.permitsFreshStoreForLegacyMigration(.incompatibleNewerSchema))
        #expect(!PersistentStoreOpenFailurePolicy.permitsFreshStoreForLegacyMigration(.transientContention))
        #expect(!PersistentStoreOpenFailurePolicy.permitsFreshStoreForLegacyMigration(.blockedUnknown))
    }

    @Test("Store lease excludes a second owner and releases deterministically")
    func storeLeaseExcludesSecondOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-store-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("store.lock")
        let owner = PersistentStoreLease.OwnerMetadata(channel: "test", version: "1", build: "1")

        let first = try PersistentStoreLease.acquire(at: lockURL, owner: owner)
        defer { first.release() }
        #expect(PersistentStoreLease.recordedOwner(at: lockURL) == owner)

        do {
            _ = try PersistentStoreLease.acquire(at: lockURL, owner: owner)
            Issue.record("A second lease acquisition unexpectedly succeeded")
        } catch let error as PersistentStoreLease.AcquisitionError {
            #expect(error == .alreadyOwned)
        }

        first.release()
        let replacement = try PersistentStoreLease.acquire(at: lockURL, owner: owner)
        replacement.release()
    }

    @Test("Snapshot review policy does not require a live TaskRun")
    func snapshotReviewPolicyUsesOnlyValueInput() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let run = PendingTaskReviewRunSnapshot(
            id: UUID(),
            status: .failed,
            startedAt: startedAt,
            completedAt: nil,
            stopReason: "policy_violation"
        )
        let input = PendingTaskReviewSnapshotInput(
            taskStatus: .pendingUser,
            isTaskDone: false,
            requiresDeliverableArtifact: false,
            latestRun: run,
            runs: [run],
            events: [],
            latestRunHasScopedArtifact: false
        )

        #expect(PendingTaskReviewPolicy.reviewState(for: input) == PendingTaskReviewState(
            isDismissed: false,
            dismissalReason: .policyBlocked
        ))
    }

    @Test("Corrupt active-store pointers fail closed instead of falling back")
    func corruptActiveStorePointerFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-pointer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pointerURL = root.appendingPathComponent("active-store.json")
        let fallbackURL = root.appendingPathComponent("default.store")
        try Data("{not-json".utf8).write(to: pointerURL)
        try Data().write(to: fallbackURL)

        #expect(WorkspaceRecoveryService.activeStorePointerState(
            pointerURL: pointerURL,
            storeRoot: root
        ) == .invalid)
        #expect(WorkspaceRecoveryService.existingPersistentStoreURL(
            pointerURL: pointerURL,
            storeRoot: root,
            fallbackStoreURL: fallbackURL
        ) == nil)
    }

    @Test("Active-store pointers reject symlink escapes from the generation root")
    func activeStorePointerRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-pointer-root-" + UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-pointer-outside-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let outsideStoreURL = outside.appendingPathComponent("outside.store")
        try Data().write(to: outsideStoreURL)
        let linkedDirectoryURL = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectoryURL, withDestinationURL: outside)
        let pointerURL = root.appendingPathComponent("active-store.json")
        try Data(#"{"relativePath":"linked/outside.store"}"#.utf8).write(to: pointerURL)

        #expect(WorkspaceRecoveryService.activeStorePointerState(
            pointerURL: pointerURL,
            storeRoot: root
        ) == .invalid)
    }

    @Test("SQLite store migration uses a consistent backup and atomic destination")
    func storeSnapshotIsConsistentAndAtomic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-snapshot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("destination.store")
        try executeSQLite("PRAGMA journal_mode=WAL; CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT); INSERT INTO items(value) VALUES ('live');", at: sourceURL)

        try WorkspaceRecoveryService.copyStoreSnapshot(from: sourceURL, to: destinationURL)

        #expect(WorkspaceRecoveryService.sqliteIntegrityIsValid(at: destinationURL))
        #expect(try scalarInt("SELECT COUNT(*) FROM items WHERE value = 'live'", at: destinationURL) == 1)
    }

    @Test("Failed store migration leaves no partial destination")
    func failedStoreMigrationLeavesNoPartialDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-migration-failure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("destination.store")
        try Data("not a sqlite database".utf8).write(to: sourceURL)

        do {
            try WorkspaceRecoveryService.copyStoreSnapshot(from: sourceURL, to: destinationURL)
            Issue.record("A malformed SQLite source unexpectedly migrated")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        }
    }
}

private func executeSQLite(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_close(database) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(errorMessage)
        throw NSError(domain: "PersistentStoreSafetyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func scalarInt(_ sql: String, at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return Int(sqlite3_column_int(statement, 0))
}
