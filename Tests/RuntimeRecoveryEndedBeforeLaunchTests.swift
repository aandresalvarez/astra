import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// A task admitted into a reserved workspace by a remembered decision can fail
/// before it launches anything (a missing credential, for example). It then
/// carried inherited uncertainty forever: it reserved the workspace, could not
/// be continued over because it had no completed turn, and "Review workspace"
/// refused. A run with zero launches has nothing of its own to verify.
@Suite("An execution that never launched does not reserve its workspace", .serialized)
@MainActor
struct RuntimeRecoveryEndedBeforeLaunchTests {
    private func receipt(_ task: AgentTask, path: String) throws -> RuntimeExecutionOwnerRecord {
        RuntimeExecutionOwnerRecord(taskID: task.id, taskOwnerID: task.persistentModelID, ownerID: UUID(), executionID: UUID(),
            runID: UUID(), appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
            runtime: "copilot_cli", state: .notStarted,
            limits: .init(tokenCeiling: 1000, turnsRemaining: 3, secondsRemaining: 60, tokensSpent: 0, costSpent: 0),
            inheritedToolUncertainty: true,
            resourceClaims: [.init(taskID: task.id, resourceKey: path, accessMode: .write, runMode: "task")],
            providerLaunchCount: 0, resourcesReleased: false, workspaceContinuationRequestID: UUID(), updatedAt: Date())
    }

    @Test("Only an explicit zero-launch receipt with no history of its own is released",
          arguments: ["valid", "legacyCount", "launched", "process", "proof", "ownHistory", "session", "sshJobs",
                      "settlement", "localWork", "settlementTools", "preparing", "finished"])
    func gates(fault: String) throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .copilotCLI, goal: "Next", model: "test")
        var record = try receipt(task, path: h.workspaceURL.path)
        let live = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        switch fault {
        case "legacyCount": record.providerLaunchCount = nil
        case "launched": record.providerLaunchCount = 1
        case "process": record.providerProcess = live
        case "proof":
            record.stopProof = .init(executionID: record.executionID, process: live, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date())
        case "ownHistory": record.retainedExecutionHead = UUID()
        case "session": record.sessionVerificationPending = true
        case "sshJobs": record.pendingSSHJobSetDigest = "pending"
        case "settlement": record.settlementInProgress = true
        case "localWork": record.settlementLocalWorkStopped = false
        case "settlementTools": record.settlementToolsStopped = false
        case "preparing": record.state = .preparing
        case "finished": record.state = .finished
        default: break
        }
        let released = fault == "valid"
        #expect(record.canReplace == released)
        #expect(RuntimeResourceOwnership.retainsResources(record) == !released)
        // The inherited flag itself is untouched: it still describes the predecessors.
        #expect(record.inheritedToolUncertainty == true && record.hasUnverifiedTools)
    }

    @Test("Retrying an attempt that never launched does not make it reserving history")
    func retryStaysUnreserved() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .copilotCLI, goal: "Needs a credential", model: "test")
        // Two attempts in a row end before any provider starts, as with a missing credential.
        for attempt in 1...2 {
            let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
            let run = TaskRun(task: task)
            h.context.insert(run)
            try owner.bind(run: run) // records the explicit zero launches for this run
            owner.finish()
            let saved = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
            #expect(saved.state == .notStarted && saved.retainedExecutionHead == nil, "attempt \(attempt)")
            #expect(saved.endedBeforeLaunch && saved.canReplace && !RuntimeResourceOwnership.retainsResources(saved), "attempt \(attempt)")
        }
        #expect(try RuntimeResourceOwnership.claims(in: RuntimeExecutionOwner.store(in: h.context), context: h.context).isEmpty)
    }

    @Test("The predecessors keep the workspace reserved; the task that never launched stops adding to it")
    func predecessorsStillHold() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let earlier = h.makeTask(runtime: .copilotCLI, goal: "Earlier", model: "test")
        let failed = h.makeTask(runtime: .copilotCLI, goal: "Failed before launch", model: "test")
        let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let executionID = UUID()
        // An earlier task whose tools are unverified, written before any observation existed.
        let holder = RuntimeExecutionOwnerRecord(taskID: earlier.id, taskOwnerID: earlier.persistentModelID, ownerID: UUID(),
            executionID: executionID, runID: UUID(),
            appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
            providerProcess: dead, runtime: "copilot_cli", state: .finished,
            limits: .init(tokenCeiling: 1000, turnsRemaining: 3, secondsRemaining: 60, tokensSpent: 1, costSpent: 0),
            stopProof: .init(executionID: executionID, process: dead, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date()),
            settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
            resourceClaims: [.init(taskID: earlier.id, resourceKey: h.workspaceURL.path, accessMode: .write, runMode: "task")],
            providerLaunchCount: 1, resourcesReleased: false, updatedAt: Date())
        let store = RuntimeExecutionOwner.store(in: h.context)
        for record in [holder, try receipt(failed, path: h.workspaceURL.path)] {
            let lease = try store.acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
            try lease.save(record)
        }
        let claims = try RuntimeResourceOwnership.claims(in: store, context: h.context)
        #expect(claims.map(\.taskID) == [earlier.id])
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let next = h.makeTask(runtime: .copilotCLI, goal: "Next", model: "test")
        let wanted = queue.resourceLockClaims(for: nil, task: next, runMode: "task")
        // Still reserved, by the task that actually ran; that one can be reviewed and continued.
        #expect(!queue.canAcquireResourceLocks(wanted))
        #expect(TaskExecutionResourceBroker.firstConflict(requested: wanted, active: claims)?.holder.taskID == earlier.id)
    }
}
