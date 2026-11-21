import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Repairs configured-SSH fences from protected process and job evidence.
/// Native helper frames remain uncertain until their exact broker-accounted job
/// inventory proves permission was withdrawn before dispatch. Unrelated tools
/// and unknown execution are never promoted by a model statement or host scan.
///
/// These upgrade a stop proof, which is what Retry reads. Whether a
/// reservation has ended is decided by `RuntimeReservationRelease`, which
/// calls them only after it has.
@MainActor
enum RuntimeHostNoToolReceiptReconciliation {
    static func reconciled(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask, managedSSHJobsVerified: Bool = false) -> RuntimeExecutionOwnerRecord? {
        guard saved.taskID == task.id, saved.state == .finished,
              saved.resourcesReleased == false, saved.cancellationRequested != true,
              saved.inheritedToolUncertainty != true, saved.settlementInProgress == false,
              saved.settlementLocalWorkStopped == true, saved.settlementToolsStopped == true,
              let proof = saved.stopProof, !proof.remoteWorkExcluded || !proof.toolsStopped,
              proof.toolsStopped || (managedSSHJobsVerified && proof.managedSSHOnly == true),
              proof.reaped, proof.processGroupEmpty, proof.executionID == saved.executionID,
              proof.process == saved.providerProcess, proof.process.presence == .absent,
              let runID = saved.runID, let run = task.runs.first(where: { $0.id == runID }),
              task.runs.max(by: { $0.startedAt < $1.startedAt })?.id == runID,
              !task.runs.contains(where: { $0.status == .running }),
              run.status == .completed, run.typedStopReason == .completed, run.completedAt != nil,
              let snapshot = run.executionEnvironmentSnapshotJSON,
              let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(snapshot.utf8)),
              environment.isHost else { return nil }
        var result = saved
        result.hostNoToolReconciliationOriginalProof = proof
        result.stopProof = .init(executionID: proof.executionID, process: proof.process,
            reaped: proof.reaped, processGroupEmpty: proof.processGroupEmpty,
            toolsStopped: true, remoteWorkExcluded: true, capturedAt: proof.capturedAt, managedSSHOnly: proof.managedSSHOnly)
        guard result.canReplace else { return nil }
        result.resourcesReleased = true
        result.providerSharedStateReleased = true
        result.updatedAt = Date()
        return result
    }

    /// A receipt that recorded live local survivors is asked again once those
    /// processes are gone. The process table answers; no statement or decision does.
    static func reobserved(_ saved: RuntimeExecutionOwnerRecord,
                           observe: (RuntimeLocalSurvivorObservation.Launch) -> RuntimeLocalSurvivorObservation = { RuntimeExecutionLocalSurvivors.observe($0) }) -> RuntimeExecutionOwnerRecord? {
        guard awaitsLocalSurvivors(saved), saved.cancellationRequested != true, saved.inheritedToolUncertainty != true,
              saved.settlementInProgress == false, saved.settlementLocalWorkStopped == true, saved.settlementToolsStopped == true,
              let proof = saved.stopProof, let earlier = proof.localSurvivors, proof.remoteWorkExcluded,
              proof.executionID == saved.executionID, proof.process == saved.providerProcess, proof.process.presence == .absent,
              earlier.launch.provider == proof.process,
              earlier.survivors.allSatisfy({ $0.process.presence == .absent }) else { return nil }
        let current = observe(earlier.launch)
        guard current.clean else { return nil }
        var result = saved
        result.hostNoToolReconciliationOriginalProof = proof
        result.stopProof = proof.observing(current)
        guard result.canReplace else { return nil }
        result.resourcesReleased = true
        result.providerSharedStateReleased = true
        result.updatedAt = Date()
        return result
    }

    nonisolated static func awaitsLocalSurvivors(_ record: RuntimeExecutionOwnerRecord) -> Bool {
        record.state == .finished && record.resourcesReleased == false && record.stopProof?.toolsStopped == false
            && record.stopProof?.localSurvivors?.survivors.isEmpty == false
    }
}
