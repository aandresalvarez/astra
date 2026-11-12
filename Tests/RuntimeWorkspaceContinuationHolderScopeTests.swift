import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// A finished task can hold more than the next request asks for: a task that
/// worked in its own worktree holds that worktree and the shared repository.
/// The decision to continue covers only what the request names.
@Suite("Workspace continuation covers only what the request names", .serialized)
@MainActor
struct RuntimeWorkspaceContinuationHolderScopeTests {
    private func claim(_ task: AgentTask, _ url: URL, _ access: TaskResourceAccessMode = .write,
                       request: UUID? = nil) -> TaskResourceLockClaim {
        .init(taskID: task.id, resourceKey: url.path, accessMode: access, runMode: "previous", requestID: request)
    }

    /// A completed holder whose tools stayed unverified, with extra claims.
    private func holder(_ h: HeadlessChatHarness, extra: (AgentTask) -> [TaskResourceLockClaim]) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Earlier work", model: "test")
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = .completed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off) + extra(task)
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
        try lease.save(record); try h.context.save()
        return (task, record)
    }

    /// The harness workspace declares all of `rootURL`; a private worktree lives elsewhere.
    private func privateWorktree() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("astra-holder-worktree-\(UUID().uuidString)/earlier")
    }

    private func next(_ h: HeadlessChatHarness, after task: AgentTask) throws -> (AgentTask, TaskTurnRequest) {
        let next = h.makeTask(runtime: .codexCLI, goal: "A new instruction", model: "test")
        next.workspace = task.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        return (next, try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context)))
    }

    @Test("A holder's private worktree does not block continuing, and stays reserved")
    func privateWorktreeStaysReserved() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let worktree = privateWorktree()
        let (old, original) = try holder(h) { [self] in [claim($0, worktree)] }
        let (task, request) = try next(h, after: old)
        let claims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task, runMode: "initial", sandboxEnforcement: .off)
        let store = RuntimeExecutionOwner.store(in: h.context)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request, resourceClaims: claims) == nil)

        let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context)
        #expect(proposal.sources.map(\.receipt) == [original])
        try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context, rememberWorkspace: true)
        do {
            let admission = try #require(try RuntimeWorkspaceContinuation.admission(task: task, request: request, previous: nil, context: h.context))
            #expect(!admission.excludedClaims.isEmpty)
            #expect(!admission.excludedClaims.contains { $0.resourceKey == worktree.path })
        }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60,
            userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == request.id)
        // The holder's receipt is unchanged and its worktree is still held.
        #expect(try RuntimeExecutionOwner.existing(task: old, context: h.context) == original)
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).contains { $0.taskID == old.id && $0.resourceKey == worktree.path })
    }

    @Test("A request that names the holder's private worktree is not covered by a decision that did not", arguments: [true, false])
    func decisionDoesNotReachUnnamedFolder(remembered: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let worktree = privateWorktree()
        let (old, _) = try holder(h) { [self] in [claim($0, worktree)] }
        let (task, request) = try next(h, after: old)
        let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context)
        try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context, rememberWorkspace: remembered)
        let wider = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task, runMode: "initial", sandboxEnforcement: .off)
            + [claim(task, worktree, request: request.id)]
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request, resourceClaims: wider) == nil)
    }

    @Test("A holder claim inside a requested folder is part of the decision; a broader or differently held one refuses",
          arguments: ["inside", "broader", "readInside", "otherKind"])
    func overlappingClaims(shape: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let inner = h.workspaceURL.appendingPathComponent(".git")
        let (old, _) = try holder(h) { [self] task in
            switch shape {
            case "inside": return [claim(task, inner)]
            case "broader": return [claim(task, h.rootURL.deletingLastPathComponent())]
            case "readInside": return [claim(task, inner, .readOnly)]
            default:
                return [.init(taskID: task.id, resourceKey: "shared-browser", accessMode: .write, runMode: "previous", resourceKind: .browserSession)]
            }
        }
        let (task, request) = try next(h, after: old)
        guard shape == "inside" else {
            #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context) }
            return
        }
        let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context)
        try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context, rememberWorkspace: true)
        do {
            let admission = try #require(try RuntimeWorkspaceContinuation.admission(task: task, request: request, previous: nil, context: h.context))
            #expect(admission.excludedClaims.contains { $0.resourceKey == inner.path })
        }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
        owner.finish()
    }

    @Test("Naming a resource means the same one or a folder that contains it, with the same access")
    func naming() {
        let id = UUID()
        func claim(_ key: String, _ access: TaskResourceAccessMode = .write, _ kind: TaskExecutionResourceKind = .workspace) -> TaskResourceLockClaim {
            .init(taskID: id, resourceKey: key, accessMode: access, runMode: "test", resourceKind: kind)
        }
        #expect(TaskExecutionResourceBroker.names(claim("/a/b"), resourceOf: claim("/a/b")))
        #expect(TaskExecutionResourceBroker.names(claim("/a/b"), resourceOf: claim("/a/b/.git")))
        #expect(!TaskExecutionResourceBroker.names(claim("/a/b"), resourceOf: claim("/a")))
        #expect(!TaskExecutionResourceBroker.names(claim("/a/b"), resourceOf: claim("/a/bc")))
        #expect(!TaskExecutionResourceBroker.names(claim("/a/b"), resourceOf: claim("/a/b", .readOnly)))
        #expect(!TaskExecutionResourceBroker.names(claim("/a/b"), resourceOf: claim("/a/b", .write, .gitCommonDirectory)))
        #expect(!TaskExecutionResourceBroker.names(claim("s", .write, .nativeSession), resourceOf: claim("s/x", .write, .nativeSession)))
    }
}
