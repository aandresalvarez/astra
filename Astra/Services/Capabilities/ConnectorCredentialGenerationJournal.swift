import Foundation
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
        case unreadable, wrongStore, tooLarge, busy
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The account credential recovery record could not be read."
            case .wrongStore: return "The account credential recovery record belongs to a different store. Recover it before retrying."
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
    private struct Contents: Codable {
        var version = 1
        let storeIdentity: String
        var candidates: [ConnectorKeychainCleanup]
    }
    let fileURL: URL
    private let storeIdentity: String
    private static let maximumBytes = 1_048_576

    init?(modelContext: ModelContext) throws {
        guard let store = ConnectorCredentialCleanupStore(for: modelContext) else { return nil }
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw Failure.wrongStore }
        fileURL = store.directory.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialGenerations.json")
        storeIdentity = identity
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
              PersistentStoreIdentity.current(for: modelContext) == storeIdentity,
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

    private func read() throws -> Contents {
        do {
            guard try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType == .typeRegular
            else { throw Failure.unreadable }
            let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            guard contents.version == 1, contents.storeIdentity == storeIdentity else { throw Failure.wrongStore }
            return contents
        } catch where WorkspaceFileLayout.isMissingFile(error) {
            return Contents(storeIdentity: storeIdentity, candidates: [])
        }
    }

    private func write(_ contents: Contents) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contents)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func audit(_ reason: String) {
        AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
            "scope": "account_credential_generation", "reason": reason
        ], level: .warning)
    }
}
