import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// What the host said when a receipt was released after a restart, and what
/// the receipt said before: the journal keeps only a digest of the original.
struct RuntimeHostRestartObservation: Codable, Equatable, Sendable {
    let bootedAt: Date
    let observedAt: Date
    let inheritedToolUncertainty: Bool?
}

/// A folder on this Mac can only be changed by a process on this Mac, and no
/// process outlives a restart. A finished owner whose every execution ran on
/// the host, excluded remote work and ended before this boot has nothing left
/// that could still act, whatever its transcripts could not show.
///
/// The evidence is the one `ProviderSharedStateReadObservation` already
/// accepts for a settings reader; here it releases the owner's reservation.
/// Uncertainty an owner inherited from other tasks stays with those tasks'
/// own receipts, which are judged separately by this same rule.
///
/// Not answered: work handed to a service that restarts by itself (launchd, a
/// container runtime). Containers and SSH routes are excluded by their own
/// evidence; receipts with a remote registration never qualify.
@MainActor
enum RuntimeHostRestartRelease {
    nonisolated static func awaits(_ record: RuntimeExecutionOwnerRecord, bootedAt: Date?) -> Bool {
        guard let bootedAt, record.state == .finished, record.resourcesReleased == false, !record.canReplace,
              let proof = record.stopProof else { return false }
        return proof.remoteWorkExcluded && proof.capturedAt < bootedAt
    }

    static func released(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask, journal: URL,
                         store: RuntimeExecutionOwnerStore, bootedAt: Date?) throws -> RuntimeExecutionOwnerRecord? {
        guard let bootedAt, awaits(saved, bootedAt: bootedAt), saved.taskID == task.id,
              saved.taskOwnerID == task.persistentModelID, saved.resourceClaims != nil,
              saved.cancellationRequested != true, saved.stopProof?.managedSSHOnly != true,
              let proof = saved.stopProof, let runID = saved.runID,
              let latest = task.runs.max(by: { $0.startedAt < $1.startedAt }), latest.id == runID,
              latest.status == .completed, latest.typedStopReason == .completed,
              !task.runs.contains(where: { $0.status == .running }),
              ProviderSharedStateReadObservation.journalPredatesBoot(journal, bootedAt: bootedAt),
              ProviderSharedStateReadObservation.noRemoteRegistrations(for: task.id, store: store) else { return nil }
        let runs = Dictionary(grouping: task.runs, by: \.id)
        var bound = Set<UUID>()
        for execution in try store.retainedExecutions(of: saved) + [saved] {
            guard execution.taskOwnerID == task.persistentModelID, execution.sessionVerificationPending != true,
                  execution.pendingSSHJobSetDigest == nil, execution.resourceClaims != nil,
                  let id = execution.runID, bound.insert(id).inserted,
                  let matches = runs[id], matches.count == 1, let run = matches.first, run.runtimeID == execution.runtime,
                  let ended = run.completedAt, run.status != .running, run.startedAt <= ended, ended < bootedAt,
                  let json = run.executionEnvironmentSnapshotJSON,
                  let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(json.utf8)),
                  environment.isHost else { return nil }
            if execution.state == .notStarted {
                // On an older receipt this label can follow a provider that did
                // launch and whose evidence a fallback cleared. Whatever it
                // started ran before the boot, because its run ended before it,
                // and this task never registered remote work.
                guard execution.providerProcess == nil, execution.stopProof == nil, execution.settlementInProgress != true,
                      execution.settlementLocalWorkStopped != false, execution.settlementToolsStopped != false else { return nil }
            } else if !ProviderSharedStateReadObservation.endedLocally(execution, before: bootedAt) { return nil }
        }
        var result = saved
        result.hostNoToolReconciliationOriginalProof = proof
        result.stopProof = proof.restarted(.init(bootedAt: bootedAt, observedAt: Date(),
            inheritedToolUncertainty: saved.inheritedToolUncertainty))
        result.inheritedToolUncertainty = false
        guard result.canReplace else { return nil }
        result.resourcesReleased = true
        result.providerSharedStateReleased = true
        result.updatedAt = Date()
        return result
    }
}
