import Foundation
import Darwin
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Immutable retirement candidates for authored skill generations. This is
/// separate from legacy plugin cleanup: only this journal knows unpublished
/// generations, and its producer/collector lease protects that interval.
@MainActor
struct SkillCredentialGenerationJournal {
    enum Failure: Error, LocalizedError {
        case wrongStore, unreadable, tooLarge, busy
        var errorDescription: String? {
            switch self {
            case .wrongStore: "The skill credential recovery record belongs to another store. Recover it before retrying."
            case .unreadable: "ASTRA couldn't read or prepare the skill credential recovery record. Its existing secrets were kept."
            case .tooLarge: "Finish skill credential recovery before making more changes."
            case .busy: "Another skill credential change is in progress. Retry when it finishes."
            }
        }
    }
    private struct Contents: Codable {
        var version = 1
        let storeIdentity: String
        var namespaces: Set<UUID>
    }
    let fileURL: URL
    private let storeIdentity: String
    private static let maximumBytes = 1_048_576

    init?(modelContext: ModelContext) throws {
        guard let outbox = PluginSecretCleanupOutbox(for: modelContext) else { return nil }
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw Failure.wrongStore }
        fileURL = outbox.fileURL.deletingLastPathComponent().appendingPathComponent("SkillCredentialGenerations.json")
        storeIdentity = identity
    }

    func acquireLease() throws -> PersistentStoreLease {
        do {
            return try PersistentStoreLease.acquire(at: fileURL.appendingPathExtension("lock"),
                owner: .init(channel: "skill-credential-generation", version: "1", build: "1"))
        } catch PersistentStoreLease.AcquisitionError.alreadyOwned { throw Failure.busy }
    }

    func pending() throws -> Set<UUID> { try read().namespaces }

    func record(_ namespaces: Set<UUID>, lease: PersistentStoreLease) throws {
        guard lease.lockURL == fileURL.appendingPathExtension("lock") else { throw Failure.wrongStore }
        var contents = try read()
        contents.namespaces.formUnion(namespaces)
        try write(contents)
    }

    func forget(_ namespaces: Set<UUID>, lease: PersistentStoreLease) {
        do {
            guard lease.lockURL == fileURL.appendingPathExtension("lock") else { throw Failure.wrongStore }
            var contents = try read()
            contents.namespaces.subtract(namespaces)
            try write(contents)
        } catch { audit("intent_retained") }
    }

    static func requiresRecoveryScan(modelContext: ModelContext) -> Bool {
        do { return try Self(modelContext: modelContext).map { try !$0.pending().isEmpty } ?? false }
        catch { return true }
    }

    static func resumeAfterWorkspaceRecovery(modelContext: ModelContext) {
        do { try Self(modelContext: modelContext)?.resumePending(modelContext: modelContext) }
        catch { audit("recovery_record_unreadable") }
    }

    /// Never infer liveness from unsaved editor state, nor collect before the
    /// recovery ownership scan, durable receipts, requests and all mirrors agree.
    func resumePending(modelContext: ModelContext) throws {
        guard WorkspaceRecoveryTrust.allowsCleanup,
              PersistentStoreIdentity.current(for: modelContext) == storeIdentity,
              !((try pending()).isEmpty), let lease = try? acquireLease(),
              PluginOperationRecovery.permitsCredentialCleanup(modelContext: modelContext) else { return }
        let saved = ModelContext(modelContext.container)
        guard let workspaces = try? saved.fetch(FetchDescriptor<Workspace>()),
              workspaces.reduce(true, { WorkspaceConfigManager.exportMirrorNow(workspace: $1, modelContext: saved) && $0 }),
              let live = PluginSecretCleanupOutbox.liveSkillIDs(modelContext: saved),
              let requests = PendingTaskCredentialReferences.capture(modelContext: saved),
              let mirrors = PluginCredentialMirrorReferences.capture(modelContext: saved) else { return }
        var settled = Set<UUID>()
        for namespace in try pending() {
            if live.contains(namespace) { settled.insert(namespace); continue }
            guard !requests.holdsSkill(namespace), !mirrors.holdsSkill(namespace) else { continue }
            if SkillSecretSeam.required.deleteAllSecretsReportingResult(skillID: namespace) { settled.insert(namespace) }
        }
        forget(settled, lease: lease)
    }

    private func read() throws -> Contents {
        // Bound reads before decoding; a corrupt/foreign record never grants cleanup.
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
            return Contents(storeIdentity: storeIdentity, namespaces: [])
        }
    }

    private func write(_ contents: Contents) throws {
        let data = try JSONEncoder().encode(contents)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func audit(_ reason: String) {
        AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
            "scope": "skill_credential_generation", "reason": reason
        ], level: .warning)
    }
    private func audit(_ reason: String) { Self.audit(reason) }
}
