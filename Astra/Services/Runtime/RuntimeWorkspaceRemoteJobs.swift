import Foundation
import CryptoKit
import SwiftData
import ASTRAModels
import WorkspaceToolSupport

/// Stored only on a request-scoped, protected workspace handoff. It is a
/// user's decision about this job, not a release of the predecessor's owner.
struct ReviewedWorkspaceSSHJob: Codable, Equatable {
    let jobID: String
    let executionID: String
    let nonce: String
    let legacy: Bool
    let status: RemoteWorkspaceJobStatus
    let sealed: Bool
    let reachable: Bool

    func identifies(_ other: Self) -> Bool {
        jobID == other.jobID && executionID == other.executionID && nonce == other.nonce && legacy == other.legacy
    }
}

enum WorkspaceSSHWait: LocalizedError {
    case pending([String])
    static let summaryPrefix = "Waiting for confirmation of "

    var errorDescription: String? {
        switch self {
        case .pending(let ids): Self.summary(ids)
        }
    }

    static func summary(_ ids: [String]) -> String {
        let list = ids.sorted().prefix(4).map { String($0.prefix(8)) }.joined(separator: ", ")
        let noun = ids.count == 1 ? "job" : "jobs"
        return "\(summaryPrefix)\(ids.count) SSH \(noun) (\(list)\(ids.count > 4 ? ", …" : ""))."
    }
}

@MainActor
enum RuntimeWorkspaceRemoteJobs {
    private static func records(task: AgentTask, owner: RuntimeExecutionOwnerRecord, context: ModelContext) throws -> [(ReviewedWorkspaceSSHJob, RemoteWorkspaceJobRecord)] {
        var jobs: [(ReviewedWorkspaceSSHJob, RemoteWorkspaceJobRecord)] = []
        for config in try RemoteWorkspaceJobRegistration.loadAll(task: task, owner: owner, context: context) {
            for job in try RemoteWorkspaceJobStore(rootPath: config.recordRootPath).records() {
                guard let binding = config.ownerBinding, job.executionID == binding.executionID,
                      job.ownerID == binding.ownerID, job.taskID == config.taskID, job.runID == config.runID,
                      let nonce = job.launchNonce, UUID(uuidString: nonce) != nil else {
                    throw WorkspaceSSHWait.pending([job.jobID])
                }
                let reachable = job.lastObservation?.outcome == .reachable
                // A previous session's process scan cannot approve a legacy
                // handoff after restart. Allow a probe timeout plus two polls.
                let age = job.lastObservation.map { -$0.at.timeIntervalSinceNow } ?? .infinity
                let reviewed = ReviewedWorkspaceSSHJob(jobID: job.jobID, executionID: binding.executionID, nonce: nonce,
                    legacy: job.schemaVersion == 2, status: job.status,
                    sealed: job.schemaVersion == 2 && job.status == .unverified && job.launch == nil &&
                        job.cancellationRequestedAt != nil && job.launchFence == .legacySealed && reachable && (0...90).contains(age),
                    reachable: reachable)
                jobs.append((reviewed, job))
            }
        }
        return jobs
    }

    static func inventory(task: AgentTask, owner: RuntimeExecutionOwnerRecord, context: ModelContext) throws -> [ReviewedWorkspaceSSHJob] {
        try records(task: task, owner: owner, context: context).map(\.0).sorted { ($0.executionID, $0.jobID) < ($1.executionID, $1.jobID) }
    }

    /// Keep the exact identities in the owner's decision even if a registration
    /// later disappears. Only a v3 receipt proving the command never started
    /// can supplement independently clean provider and settlement evidence.
    static func releaseEvidence(task: AgentTask, owner: RuntimeExecutionOwnerRecord, context: ModelContext) throws -> (identity: String?, safe: Bool) {
        let jobs = try records(task: task, owner: owner, context: context)
        guard !jobs.isEmpty else { return (nil, true) }
        let identities = jobs.map { identity, _ in [identity.executionID, identity.jobID, identity.nonce] }.sorted { $0.lexicographicallyPrecedes($1) }
        let digest = SHA256.hash(data: try JSONEncoder().encode(identities)).map { String(format: "%02x", $0) }.joined()
        let safe = jobs.allSatisfy { identity, record in
            record.schemaVersion == 3 && record.launchFence == .cancelledBeforeStart &&
                identity.status == .cancelled && record.cancellationRequestedAt != nil && record.launch == nil && identity.reachable
        }
        return (digest, safe)
    }

    static func check(_ jobs: [ReviewedWorkspaceSSHJob], reviewed: [ReviewedWorkspaceSSHJob],
                      savingDecision: Bool) throws {
        // Missing or replaced protected records cannot satisfy a saved decision.
        let missing = reviewed.filter { original in !jobs.contains(where: { original.identifies($0) }) }
        let blocking = jobs.filter { job in
            if job.status.isTerminal { return !job.reachable && reviewed.contains(where: { $0.identifies(job) }) }
            return !(reviewed.contains(where: { $0.identifies(job) }) && (savingDecision || job.sealed))
        }
        let ids = Set((missing + blocking).map(\.jobID))
        if !ids.isEmpty { throw WorkspaceSSHWait.pending(Array(ids)) }
    }
}
