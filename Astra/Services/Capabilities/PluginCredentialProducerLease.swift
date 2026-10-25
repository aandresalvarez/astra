import Foundation
import SwiftData
import ASTRAPersistence

/// A process-lifetime resource, not another owner of secret data. Producers,
/// journal writers and collectors share this nonblocking file lock. Keeping
/// the token alive protects the interval before a generation is published.
@MainActor
final class PluginCredentialProducerLease {
    enum Failure: Error, LocalizedError {
        case busy, wrongStore
        var errorDescription: String? {
            switch self {
            case .busy: "Another plugin credential change is in progress. Retry when it finishes."
            case .wrongStore: "The credential preparation belongs to another store. Retry this change."
            }
        }
    }
    let lockURL: URL
    private let held: PersistentStoreLease

    private init(lockURL: URL, held: PersistentStoreLease) { self.lockURL = lockURL; self.held = held }

    static func acquire(modelContext: ModelContext, reusing lease: PluginCredentialProducerLease? = nil) throws -> PluginCredentialProducerLease? {
        guard let outbox = PluginSecretCleanupOutbox(for: modelContext) else {
            guard lease == nil else { throw Failure.wrongStore }
            return nil
        }
        let lockURL = outbox.fileURL.appendingPathExtension("producer-lock").standardizedFileURL.resolvingSymlinksInPath()
        if let lease {
            guard lease.lockURL == lockURL else { throw Failure.wrongStore }
            return lease
        }
        do {
            let held = try PersistentStoreLease.acquire(at: lockURL,
                owner: .init(channel: "plugin-credential-producer", version: "1", build: "1"))
            return PluginCredentialProducerLease(lockURL: lockURL, held: held)
        } catch PersistentStoreLease.AcquisitionError.alreadyOwned { throw Failure.busy }
    }
}
