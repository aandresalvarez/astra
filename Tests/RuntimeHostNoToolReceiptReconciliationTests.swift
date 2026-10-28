import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Configured SSH no-tool receipt recovery", .serialized)
@MainActor
struct RuntimeHostNoToolReceiptReconciliationTests {
    private func fixture(_ h: HeadlessChatHarness) throws -> (AgentTask, TaskRun, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Preserve", model: "claude-sonnet-4-6")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        run.setOutput("Keep this answer"); run.tokensUsed = 42
        h.context.insert(run); try h.context.save()
        let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let executionID = UUID()
        let record = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: UUID(), executionID: executionID,
            runID: run.id, appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
            providerProcess: dead, runtime: "claude_code", state: .finished,
            limits: .init(tokenCeiling: 1000, turnsRemaining: 3, secondsRemaining: 60, tokensSpent: 42, costSpent: 0.1),
            stopProof: .init(executionID: executionID, process: dead, reaped: true, processGroupEmpty: true,
                toolsStopped: true, remoteWorkExcluded: false, capturedAt: Date()),
            settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
            resourceClaims: [.init(taskID: task.id, resourceKey: h.workspaceURL.path, accessMode: .write, runMode: "continue")],
            resourcesReleased: false, updatedAt: Date())
        return (task, run, record)
    }

    @Test("Only the configured-route false negative qualifies", arguments: ["valid", "tools", "reaped", "group", "execution", "process", "live",
        "inherited", "settlement", "local", "settlementTools", "cancelled", "unfinished", "missingRun", "failedRun", "container", "missingSnapshot", "badSnapshot"])
    func proofGates(fault: String) throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, run, initial) = try fixture(h); var record = initial
        let p = try #require(record.stopProof)
        switch fault {
        case "tools", "reaped", "group":
            record.stopProof = .init(executionID: p.executionID, process: p.process, reaped: fault != "reaped",
                processGroupEmpty: fault != "group", toolsStopped: fault != "tools", remoteWorkExcluded: false, capturedAt: p.capturedAt)
        case "execution": record.executionID = UUID()
        case "process": record.providerProcess = nil
        case "live":
            let live = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
            record.providerProcess = live
            record.stopProof = .init(executionID: p.executionID, process: live, reaped: true, processGroupEmpty: true,
                toolsStopped: true, remoteWorkExcluded: false, capturedAt: p.capturedAt)
        case "inherited": record.inheritedToolUncertainty = true
        case "settlement": record.settlementInProgress = true
        case "local": record.settlementLocalWorkStopped = false
        case "settlementTools": record.settlementToolsStopped = false
        case "cancelled": record.cancellationRequested = true
        case "unfinished": record.state = .unverified
        case "missingRun": record.runID = UUID()
        case "failedRun": run.status = .failed
        case "container":
            var environment = WorkspaceExecutionEnvironment.host; environment.kind = .dockerImage
            run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        case "missingSnapshot": run.executionEnvironmentSnapshotJSON = nil
        case "badSnapshot": run.executionEnvironmentSnapshotJSON = "broken"
        default: break
        }
        let repaired = RuntimeHostNoToolReceiptReconciliation.reconciled(record, task: task)
        if fault == "valid" {
            let repaired = try #require(repaired)
            #expect(repaired.canReplace && repaired.resourcesReleased == true)
            #expect(repaired.hostNoToolReconciliationOriginalProof == p)
            #expect(repaired.limits == record.limits && repaired.executionID == record.executionID)
        } else { #expect(repaired == nil) }
        #expect(run.output == "Keep this answer" && run.tokensUsed == 42)
    }

    @Test("Admission repairs once, preserves the request and original proof, and honors a live lease", arguments: [false, true])
    func admissionRecovery(cancelled: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, run, record) = try fixture(h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var lease: RuntimeExecutionOwnerStore.Lease? = try store.acquire(taskID: task.id)
        try lease?.save(record)
        guard case .success(let submitted) = ExecutionRequestSubmissionService.submitFollowUp(message: "Saved follow-up", for: task, into: h.context) else {
            Issue.record("Submission failed"); return
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
        _ = TaskTurnRequestStateMachine.transition(request, to: cancelled ? .cancelled : .waitingForResource, terminalReason: cancelled ? "cancelled_by_user" : nil)
        try h.context.save()
        try RuntimeHostNoToolReceiptReconciliation.reconcile(in: store, context: h.context)
        #expect(try store.read(taskID: task.id) == record)
        lease = nil
        let recovery = TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: h.context, autoExportWorkspaces: false)
        #expect(recovery.returnedToWaiting == (cancelled ? 0 : 1) && recovery.terminalized == 0)
        let repaired = try #require(try store.read(taskID: task.id))
        #expect(repaired.canReplace && repaired.hostNoToolReconciliationOriginalProof == record.stopProof)
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).isEmpty)
        let eventCount = task.events.count
        try RuntimeHostNoToolReceiptReconciliation.reconcile(in: store, context: h.context)
        #expect(task.events.count == eventCount)
        #expect(request.id == submitted.requestID && request.state == (cancelled ? .cancelled : .waitingForWorker))
        #expect(task.runs.count == 1 && run.output == "Keep this answer" && run.tokensUsed == 42)
    }
}
