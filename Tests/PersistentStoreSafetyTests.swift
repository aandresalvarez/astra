import Foundation
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
}
