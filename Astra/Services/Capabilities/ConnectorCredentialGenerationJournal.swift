import Foundation
import CryptoKit
import Darwin
import os
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Immutable cleanup candidates, never credential values or editable account
/// state. Saved account references, queued policies and mirrors decide when a
/// candidate is owned or can be collected. Call recovery under mutation scope.
@MainActor
struct ConnectorCredentialGenerationJournal {
    enum Failure: Error, LocalizedError {
        case unreadable, wrongStore, unsupportedVersion, tooLarge, busy
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The account credential recovery record could not be read."
            case .wrongStore: return "ASTRA couldn't verify the account credential recovery record for this store. Recover credential editing before retrying."
            case .unsupportedVersion: return "This account credential recovery record requires a newer ASTRA. Update ASTRA before retrying."
            case .tooLarge: return "Finish account credential recovery before making more changes."
            case .busy: return "Another account credential change is in progress. Retry."
            }
        }
    }
    nonisolated fileprivate static let activeLeases = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    @MainActor
    final class Lease {
        fileprivate let descriptor: Int32
        fileprivate let fileURL: URL
        fileprivate let storeIdentity: String
        fileprivate init(descriptor: Int32, fileURL: URL, storeIdentity: String) {
            self.descriptor = descriptor; self.fileURL = fileURL; self.storeIdentity = storeIdentity
        }
        deinit {
            flock(descriptor, LOCK_UN); close(descriptor)
            ConnectorCredentialGenerationJournal.activeLeases.withLock { _ = $0.remove(fileURL.path) }
        }
    }
    struct RecoveryReceipt: Codable, Equatable {
        let archivedDigest: String
        let recoveredAt: Date
        let previousVersion: Int
        /// Exact pre-cutover bytes, when archivedDigest names a compacted
        /// retention snapshot. The snapshot is the new immutable owner of
        /// all holds; original archives remain available for investigation.
        var sourceDigest: String? = nil
        /// Derived integrity inventory, owned by this receipt. A restored
        /// older receipt cannot silently omit newer preserved archives.
        var preservedArchives: [String]? = nil
    }
    private struct Contents: Codable {
        var version = 2
        let storeIdentity: String
        var candidates: [ConnectorKeychainCleanup]
        var recovery: RecoveryReceipt?
    }
    let fileURL: URL
    private let storeIdentity: String
    private let legacyStoreIdentity: String
    private let storeURL: URL
    nonisolated private static let maximumBytes = 1_048_576
    private struct HistoryBudget {
        let archives: Int
        let bytes: Int
        static let collection = Self(archives: 32, bytes: 4 * maximumBytes)
        // Explicit recovery may compact a previously published over-budget
        // chain. This larger read is bounded and never runs in background scans.
        static let recovery = Self(archives: 256, bytes: 32 * maximumBytes)
    }

    private var archiveDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialRecovery", isDirectory: true)
    }
    private var barrierDirectories: [URL] {
        ["ConnectorCredentialCleanup", "WorkspaceDeletionCleanup"].map {
            fileURL.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true)
        }
    }
    private func installRetentionBarriers() throws {
        for directory in barrierDirectories { try CredentialRecoveryRetentionBarrier.install(in: directory) }
    }

    init?(modelContext: ModelContext) throws {
        guard let store = ConnectorCredentialCleanupStore(for: modelContext) else { return nil }
        guard let identity = PersistentStoreIdentity.credentialJournal(for: modelContext),
              let legacy = PersistentStoreIdentity.current(for: modelContext),
              let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly })
        else { throw Failure.wrongStore }
        fileURL = store.directory.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialGenerations.json")
        storeIdentity = identity
        legacyStoreIdentity = legacy
        storeURL = configuration.url
    }

    /// A retained or unreadable record requires the normal startup mirror
    /// scan before any collector can establish that a generation is unowned.
    static func requiresRecoveryScan(modelContext: ModelContext) -> Bool {
        do {
            guard let journal = try Self(modelContext: modelContext) else { return false }
            return try !(try journal.pending()).isEmpty
        } catch { return true }
    }

    /// Called after file/operation recovery and the trusted ownership scan.
    /// A malformed record remains actionable debt; it never grants deletion.
    static func resumeAfterWorkspaceRecovery(modelContext: ModelContext) {
        do {
            if let journal = try Self(modelContext: modelContext) { journal.resumePending(modelContext: modelContext) }
        } catch {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "account_credential_generation", "reason": "recovery_record_unreadable"
            ], level: .warning)
        }
    }

    /// Startup must not hydrate every task's history on the UI actor. Retain
    /// the producer lock across background mirror writes, then re-read saved
    /// ownership and pending records before the synchronous collection boundary.
    static func resumeAfterWorkspaceRecoveryAsync(modelContext: ModelContext) async {
        do {
            guard WorkspaceRecoveryTrust.allowsCleanup,
                  let journal = try Self(modelContext: modelContext), !(try journal.pending()).isEmpty,
                  let lease = try? journal.acquireLease(),
                  let saved = await CredentialCleanupStartupMirrors.rewrite(modelContext: modelContext) else { return }
            journal.resumePending(modelContext: saved, rewriteMirror: { _, _ in true }, producerLease: lease)
            withExtendedLifetime(lease) {}
        } catch { auditStartupFailure() }
    }

    private static func auditStartupFailure() {
        AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
            "scope": "account_credential_generation", "reason": "recovery_record_unreadable"
        ], level: .warning)
    }

    /// The producer holds this OS lock across prepare, write and domain
    /// cutover. Collection takes the same lock, so it cannot reclaim a
    /// private generation while another process is about to publish it.
    func acquireLease(reusing lease: Lease? = nil) throws -> Lease {
        try requireCurrentStore()
        if let lease {
            guard lease.fileURL == fileURL, lease.storeIdentity == storeIdentity else { throw Failure.wrongStore }
            return lease
        }
        guard Self.activeLeases.withLock({ $0.insert(fileURL.path).inserted }) else { throw Failure.busy }
        var descriptor: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            descriptor = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
            return Lease(descriptor: descriptor, fileURL: fileURL, storeIdentity: storeIdentity)
        } catch {
            if descriptor >= 0 { close(descriptor) }
            Self.activeLeases.withLock { _ = $0.remove(fileURL.path) }
            throw error
        }
    }

    func pending() throws -> [ConnectorKeychainCleanup] { try read().candidates }

    func record(_ candidates: [ConnectorKeychainCleanup], lease: Lease) throws {
        _ = try acquireLease(reusing: lease)
        var contents = try read()
        for candidate in candidates where !contents.candidates.contains(candidate) { contents.candidates.append(candidate) }
        try write(contents)
    }

    @discardableResult
    func forget(_ candidates: [ConnectorKeychainCleanup], lease: Lease) -> Bool {
        do {
            _ = try acquireLease(reusing: lease)
            var contents = try read()
            contents.candidates.removeAll { candidates.contains($0) }
            try write(contents)
            return true
        } catch { audit("intent_retained"); return false }
    }

    /// Idempotent recovery. No domain changes, no compensation, and no
    /// deletion while any saved launch or recovery mirror can read a slot.
    @discardableResult
    func resumePending(
        modelContext: ModelContext, extraMirrors: [String]? = nil,
        rewriteMirror: ((Workspace, ModelContext) -> Bool)? = nil,
        producerLease: Lease? = nil
    ) -> Int {
        guard WorkspaceRecoveryTrust.allowsCleanup,
              PersistentStoreIdentity.credentialJournal(for: modelContext) == storeIdentity,
              let seen = try? pending(), !seen.isEmpty,
              let lease = try? acquireLease(reusing: producerLease),
              PluginOperationRecovery.permitsCredentialCleanup(modelContext: modelContext),
              let candidates = try? pending() else { return 0 }
        let saved = ModelContext(modelContext.container)
        let rewrite = rewriteMirror ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: $1) }
        guard let workspaces = try? saved.fetch(FetchDescriptor<Workspace>()),
              workspaces.reduce(true, { rewrite($1, saved) && $0 }),
              let ownership = ConnectorCredentialCleanup.capturedOwnership(modelContext: saved, extraMirrors: extraMirrors),
              let requests = PendingTaskCredentialReferences.capture(modelContext: saved),
              let mirrored = PluginCredentialMirrorReferences.capture(modelContext: saved, extraMirrors: extraMirrors) else { return 0 }
        var settled: [ConnectorKeychainCleanup] = []
        for candidate in candidates {
            guard let owned = KeychainSecretStore.ownedConnectorEntityIDs(for: candidate.secretFacts) else { continue }
            let namespaces = Set(owned)
            if let current = ownership.currentNamespaces[candidate.connectorID], namespaces.isSubset(of: current) {
                settled.append(candidate) // Current owner, whose next edit will journal retirement again.
                continue
            }
            guard namespaces.isDisjoint(with: ownership.namespaces),
                  !requests.holdsAccount(candidate), !mirrored.holdsAccount(candidate) else { continue }
            // A generation is not deletion of a logical Outlook account.
            if candidate.run(sparing: ownership.namespaces, keepRegistryEntry: true) { settled.append(candidate) }
        }
        guard !settled.isEmpty, forget(settled, lease: lease) else { return 0 }
        return settled.count
    }

    /// Only an explicit editor action may retire an unverifiable journal.
    /// Its bytes and cleanup candidates remain immutable recovery debt; they
    /// never become deletion authority for the currently selected store.
    func canRecoverEditing() -> Bool {
        do {
            try requireCurrentStore()
            guard let stored = try stored(), [1, 2].contains(stored.contents.version) else { return false }
            if !matches(stored.contents) { return true }
            do {
                _ = try retainedHistory(stored.contents, budget: .collection)
                if stored.contents.recovery != nil {
                    for directory in barrierDirectories {
                        let fence = directory.appendingPathComponent(CredentialRecoveryRetentionBarrier.filename)
                        do { _ = try FileManager.default.attributesOfItem(atPath: fence.path) }
                        catch where WorkspaceFileLayout.isMissingFile(error) { return true }
                    }
                }
                return false
            }
            catch Failure.tooLarge {
                _ = try retainedHistory(stored.contents, budget: .recovery)
                return true
            }
        } catch { return false }
    }

    /// Archived candidates are conservative holds, never deletion requests.
    /// All account collectors consult them, including ordinary account and
    /// workspace deletion. Missing/corrupt history fails closed for cleanup.
    static func retainedRecoveryCandidates(modelContext: ModelContext) -> [ConnectorKeychainCleanup]? {
        do {
            guard let journal = try Self(modelContext: modelContext) else { return [] }
            let current = try journal.stored()
            try journal.requireArchiveReceipt(current?.contents)
            guard let current else { return [] }
            try journal.requireSupportedVersion(current.contents)
            if current.contents.recovery != nil {
                for directory in journal.barrierDirectories {
                    try CredentialRecoveryRetentionBarrier.validate(at: directory
                        .appendingPathComponent(CredentialRecoveryRetentionBarrier.filename))
                }
            }
            return (journal.matches(current.contents) ? [] : current.contents.candidates)
                + (try journal.retainedHistory(current.contents, budget: .collection))
        } catch { return nil }
    }

    /// Absence of the active record is not absence of recovery debt. Never
    /// recreate a receipt-free owner while immutable archives still exist.
    /// Temporary interrupted copies are not published archives.
    private func publishedArchives() throws -> Set<String> {
        let entries: [URL]
        do {
            guard try FileManager.default.attributesOfItem(atPath: archiveDirectory.path)[.type] as? FileAttributeType == .typeDirectory
            else { throw Failure.unreadable }
            entries = try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)
        } catch where WorkspaceFileLayout.isMissingFile(error) { return [] }
        var digests = Set<String>()
        for entry in entries {
            if entry.lastPathComponent.hasPrefix("."), entry.pathExtension == "tmp" { continue }
            let digest = entry.deletingPathExtension().lastPathComponent
            guard entry.pathExtension == "json", Self.validDigest(digest),
                  try FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType == .typeRegular
            else { throw Failure.unreadable }
            digests.insert(digest)
        }
        return digests
    }

    nonisolated private static func validDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }

    /// Older receipts lack an inventory. Validate their complete graph once
    /// under the explicit-repair budget before a writer upgrades the receipt.
    private func legacyArchiveGraph(_ receipt: RecoveryReceipt) throws -> Set<String> {
        var queue = [receipt.archivedDigest] + [receipt.sourceDigest].compactMap { $0 }
        var seen = Set<String>()
        var bytes = 0
        while let digest = queue.popLast() {
            guard Self.validDigest(digest) else { throw Failure.unreadable }
            if !seen.insert(digest).inserted { continue }
            guard seen.count <= HistoryBudget.recovery.archives else { throw Failure.tooLarge }
            let data = try Self.readData(at: archiveDirectory.appendingPathComponent(digest + ".json"))
            bytes += data.count
            guard bytes <= HistoryBudget.recovery.bytes else { throw Failure.tooLarge }
            guard Self.digest(data) == digest else { throw Failure.unreadable }
            let archived = try JSONDecoder().decode(Contents.self, from: data)
            try requireSupportedVersion(archived)
            if let next = archived.recovery {
                queue.append(next.archivedDigest)
                if let source = next.sourceDigest { queue.append(source) }
            }
        }
        return seen
    }

    @discardableResult
    private func requireArchiveReceipt(_ contents: Contents?, allowing: Set<String> = []) throws -> Set<String> {
        let actual = try publishedArchives()
        let accounted: Set<String>
        if let receipt = contents?.recovery {
            if let inventory = receipt.preservedArchives {
                accounted = Set(inventory)
                guard accounted.count == inventory.count, accounted.allSatisfy(Self.validDigest),
                      accounted.contains(receipt.archivedDigest),
                      receipt.sourceDigest.map({ accounted.contains($0) }) ?? true
                else { throw Failure.unreadable }
            } else { accounted = try legacyArchiveGraph(receipt) }
        } else { accounted = [] }
        guard accounted.isSubset(of: actual), actual.isSubset(of: accounted.union(allowing))
        else { throw Failure.unreadable }
        return actual
    }

    private func retainedHistory(_ contents: Contents, budget: HistoryBudget) throws -> [ConnectorKeychainCleanup] {
        var recovery = contents.recovery
        var seen = Set<String>()
        var totalBytes = 0
        var retained: [ConnectorKeychainCleanup] = []
        func verified(_ digest: String) throws -> Data {
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }), seen.insert(digest).inserted
            else { throw Failure.unreadable }
            guard seen.count <= budget.archives else { throw Failure.tooLarge }
            let data = try Self.readData(at: archiveDirectory.appendingPathComponent(digest + ".json"))
            totalBytes += data.count
            guard totalBytes <= budget.bytes else { throw Failure.tooLarge }
            guard Self.digest(data) == digest else { throw Failure.unreadable }
            return data
        }
        while let receipt = recovery {
            if let source = receipt.sourceDigest, source != receipt.archivedDigest {
                // Verify the exact source too, without traversing its retired
                // chain: its holds have transferred into the snapshot.
                _ = try verified(source)
            }
            let archived = try JSONDecoder().decode(Contents.self, from: verified(receipt.archivedDigest))
            try requireSupportedVersion(archived)
            retained += archived.candidates
            recovery = archived.recovery
        }
        return retained
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ contents: Contents) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contents)
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return data
    }

    @discardableResult
    func recoverEditing(lease: Lease,
                        publish: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                        synchronizeArchive: (URL) throws -> Void = { try Self.synchronizeArchive(at: $0) }) throws -> RecoveryReceipt? {
        _ = try acquireLease(reusing: lease)
        guard let stored = try stored() else { return nil }
        try requireSupportedVersion(stored.contents)
        if matches(stored.contents) {
            do {
                _ = try retainedHistory(stored.contents, budget: .collection)
                try requireArchiveReceipt(stored.contents)
                if stored.contents.recovery != nil { try installRetentionBarriers() }
                return nil
            }
            catch Failure.tooLarge { /* Explicit repair of an older over-budget receipt chain. */ }
        }
        let historical = try retainedHistory(stored.contents, budget: .recovery)
        // Transfer every distinct hold to a bounded immutable snapshot. This
        // removes history depth and repeated bytes from collection's budget;
        // it never drops a reference or deletes any original archive.
        var candidates: [ConnectorKeychainCleanup] = []
        var seen = Set<Data>()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for candidate in stored.contents.candidates + historical {
            if seen.insert(try encoder.encode(candidate)).inserted { candidates.append(candidate) }
        }
        let snapshot = try stored.contents.recovery == nil ? stored.data
            : Self.encode(Contents(storeIdentity: stored.contents.storeIdentity, candidates: candidates))
        let sourceDigest = Self.digest(stored.data)
        let snapshotDigest = Self.digest(snapshot)
        // Only deterministic products of this exact attempt may be left by
        // an interrupted publication. Other unaccounted history blocks it.
        try requireArchiveReceipt(stored.contents, allowing: [sourceDigest, snapshotDigest])
        let directory = archiveDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw Failure.unreadable }
        // Preserve the exact original before the derived retention snapshot.
        for data in sourceDigest == snapshotDigest ? [stored.data] : [stored.data, snapshot] {
            let archive = directory.appendingPathComponent(Self.digest(data) + ".json")
            if FileManager.default.fileExists(atPath: archive.path) {
                guard try Self.readData(at: archive) == data else { throw Failure.unreadable }
            } else { try Self.preserve(data, at: archive) }
            // Retry sync even when a previous attempt left a complete archive.
            try synchronizeArchive(archive)
        }
        let receipt = RecoveryReceipt(archivedDigest: snapshotDigest, recoveredAt: Date(),
            previousVersion: stored.contents.version, sourceDigest: sourceDigest == snapshotDigest ? nil : sourceDigest,
            preservedArchives: try publishedArchives().sorted())
        // The archive must be durable before the atomic active-record cutover.
        // A failed publication leaves the original journal and archive intact;
        // retry uses the same digest, rather than adding duplicate archives.
        try requireCurrentStore()
        try write(Contents(storeIdentity: storeIdentity, candidates: [], recovery: receipt), publish: publish)
        AppLogger.audit(.credentialJournalRecovered, category: "Keychain", fields: [
            "scope": "account_credential_generation", "result": "editing_recovered",
            "retained_candidates": String(stored.contents.candidates.count), "previous_version": String(stored.contents.version)
        ])
        return receipt
    }

    private func requireCurrentStore() throws {
        guard PersistentStoreIdentity.credentialJournal(forStoreAt: storeURL) == storeIdentity else { throw Failure.wrongStore }
    }

    private func matches(_ contents: Contents) -> Bool {
        contents.storeIdentity == (contents.version == 1 ? legacyStoreIdentity : storeIdentity)
    }

    private func requireSupportedVersion(_ contents: Contents) throws {
        guard [1, 2].contains(contents.version) else { throw Failure.unsupportedVersion }
    }

    private func read() throws -> Contents {
        try requireCurrentStore()
        let stored = try stored()
        try requireArchiveReceipt(stored?.contents)
        guard let stored else { return Contents(storeIdentity: storeIdentity, candidates: []) }
        try requireSupportedVersion(stored.contents)
        guard matches(stored.contents) else { throw Failure.wrongStore }
        return stored.contents
    }

    private func stored() throws -> (data: Data, contents: Contents)? {
        do {
            let data = try Self.readData(at: fileURL)
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            return (data, contents)
        } catch where WorkspaceFileLayout.isMissingFile(error) {
            return nil
        }
    }

    private static func readData(at url: URL) throws -> Data {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular
        else { throw Failure.unreadable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return data
    }

    /// Publish only a complete, synchronized archive. A process interrupted
    /// mid-copy can leave a temporary file, never a partial digest-named record
    /// that would permanently block the next recovery attempt.
    private static func preserve(_ data: Data, at archive: URL) throws {
        let directory = archive.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if link(temporary.path, archive.path) != 0 {
            guard errno == EEXIST, try readData(at: archive) == data else { throw Failure.unreadable }
        }
    }

    nonisolated private static func synchronizeArchive(at archive: URL) throws {
        let descriptor = open(archive.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              fsync(descriptor) == 0 else { throw Failure.unreadable }
        let directoryDescriptor = open(archive.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw Failure.unreadable }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw Failure.unreadable }
    }

    private func write(_ contents: Contents,
                       publish: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        var upgraded = Contents(storeIdentity: storeIdentity, candidates: contents.candidates, recovery: contents.recovery)
        let inventory = try requireArchiveReceipt(contents)
        if upgraded.recovery != nil { upgraded.recovery?.preservedArchives = inventory.sorted() }
        let data = try Self.encode(upgraded)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try requireCurrentStore()
        if contents.recovery != nil {
            _ = try retainedHistory(contents, budget: .collection)
            try installRetentionBarriers()
        }
        try publish(data, fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func audit(_ reason: String) {
        AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
            "scope": "account_credential_generation", "reason": reason
        ], level: .warning)
    }
}
