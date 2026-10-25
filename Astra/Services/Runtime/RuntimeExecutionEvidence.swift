import Darwin
import Foundation
import ASTRAModels

/// OS identities, not bare PIDs or a model's judgment, fence recovered work.
struct RuntimeProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func read(_ pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return .init(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    enum Presence { case present, absent, unknown }
    var presence: Presence {
        if let current = Self.read(pid) { return current == self ? .present : .absent }
        return kill(pid, 0) == -1 && errno == ESRCH ? .absent : .unknown
    }
}

struct RuntimeExecutionStopProof: Codable, Equatable, Sendable {
    let executionID: UUID
    let process: RuntimeProcessIdentity
    let reaped: Bool
    let processGroupEmpty: Bool
    let toolsStopped: Bool
    let remoteWorkExcluded: Bool
    let capturedAt: Date
    var permitsReplacement: Bool { reaped && processGroupEmpty && toolsStopped && remoteWorkExcluded }
}

struct RuntimeRecoveryLimits: Codable, Equatable, Sendable {
    var tokenCeiling: Int
    var turnsRemaining: Int
    var secondsRemaining: TimeInterval
    var tokensSpent: Int
    var costSpent: Double
    var tokensRemaining: Int { tokenCeiling == Int.max ? Int.max : max(0, tokenCeiling - tokensSpent) }
}

struct RuntimeExecutionOwnerRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case notStarted, preparing, launching, working, waitingForInput, finished, stopped, unverified
    }
    let taskID: UUID
    let ownerID: UUID
    var executionID: UUID
    var runID: UUID?
    let appProcess: RuntimeProcessIdentity
    var providerProcess: RuntimeProcessIdentity?
    var runtime: String
    var sessionID: String?
    var state: State
    var limits: RuntimeRecoveryLimits
    var stopProof: RuntimeExecutionStopProof?
    var inheritedToolUncertainty: Bool? = nil
    var settlementInProgress: Bool? = nil
    var settlementLocalWorkStopped: Bool? = nil
    var settlementToolsStopped: Bool? = nil
    var resourceClaims: [TaskResourceLockClaim]? = nil
    var providerSharedStateKey: String? = nil
    var providerSharedStateReleased: Bool? = nil
    var resourcesReleased: Bool? = nil
    var cancellationRequested: Bool? = nil
    var automaticRestarts = 0
    var updatedAt: Date

    /// A new user instruction is distinct from replaying unfinished work. It
    /// still cannot compete with the old provider or its local process group.
    var hasUnverifiedTools: Bool {
        inheritedToolUncertainty == true || stopProof?.toolsStopped == false
            || stopProof?.remoteWorkExcluded == false || settlementToolsStopped == false
    }

    // A new instruction cannot bypass cleanup required of an automatic retry.
    var canAcceptUserTurn: Bool { canReplace }

    var canRecoverPreparation: Bool {
        state == .preparing && providerProcess == nil && !hasUnverifiedTools && appProcess.presence == .absent
            && settlementInProgress != true && settlementLocalWorkStopped != false
    }

    var canBeginNewTurn: Bool { state == .finished && canAcceptUserTurn }

    var canReplace: Bool {
        guard settlementInProgress != true, settlementLocalWorkStopped != false,
              !hasUnverifiedTools else { return false }
        if state == .notStarted { return true }
        guard state == .stopped || state == .finished,
              let proof = stopProof, proof.executionID == executionID,
              proof.process == providerProcess, proof.permitsReplacement else { return false }
        return proof.process.presence == .absent
    }
}

struct RuntimeSessionInspection: Equatable {
    enum State: String { case working, waitingForInput, finished, stopped, unknown }
    let state: State
    let canReconnect: Bool
    let canReplace: Bool
    let message: String

    static func inspect(_ record: RuntimeExecutionOwnerRecord, ownedHere: Bool) -> Self {
        if ownedHere && (record.state == .preparing || record.state == .launching) {
            return .init(state: .working, canReconnect: true, canReplace: false,
                message: "The existing execution owner is starting this task. ASTRA kept that attempt and did not launch another.")
        }
        if let process = record.providerProcess, process.presence == .present {
            let waiting = record.state == .waitingForInput
            return .init(state: waiting ? .waitingForInput : .working, canReconnect: ownedHere, canReplace: false,
                message: waiting ? (ownedHere ? "The existing session is waiting for input. Continue in this task; no replacement was started."
                    : "The previous session is waiting for input, but its connection could not be restored. ASTRA kept it and blocked a competing attempt.")
                    : (ownedHere ? "ASTRA reconnected to the existing running session. No new attempt was started."
                        : "The previous provider is still running. ASTRA cannot reconnect to its output channel; recovery is blocked to prevent competing attempts."))
        }
        if record.canReplace || record.canBeginNewTurn {
            return .init(state: record.state == .finished ? .finished : .stopped,
                canReconnect: record.sessionID?.isEmpty == false, canReplace: record.canReplace,
                message: record.state == .finished ? "The existing session has finished. Its result and context are preserved."
                    : "The previous execution and its relevant tools are confirmed stopped. The saved session can continue within its remaining limits.")
        }
        return .init(state: .unknown, canReconnect: false, canReplace: false,
            message: "ASTRA cannot confirm that the previous execution and all relevant tools stopped. Recovery is blocked; the task context and remaining limits are preserved.")
    }
}
