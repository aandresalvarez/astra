import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Explicit workspace continuation", .serialized)
@MainActor
struct RuntimeWorkspaceContinuationTests {
    private func completed(_ h: HeadlessChatHarness, source: AgentTask? = nil,
                           capturedClaims: [TaskResourceLockClaim]? = nil) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = source ?? h.makeTask(runtime: .claudeCode, goal: "Keep previous work", model: "test")
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.setOutput("Preserved answer")
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = .completed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished; record.inheritedToolUncertainty = true
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = capturedClaims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        if capturedClaims != nil { record.sessionID = "reported-session" }
        try save(record, h); try h.context.save()
        return (task, record)
    }

    @Test("Authorizing a workspace never authorizes taking its predecessor's native session")
    func workspaceGrantDoesNotGrantSession() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let source = h.makeTask(runtime: .claudeCode, goal: "Keep previous work", model: "test")
        let prior = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        try prior.prepareLaunch(sessionID: "requested-session")
        try await prior.session("reported-session")
        prior.stopped(proof: nil, turns: 1, tokens: 0, seconds: 0)
        prior.finish()
        let (_, original) = try completed(h, source: source, capturedClaims: prior.record.resourceClaims)
        let next = h.makeTask(runtime: .claudeCode, goal: "New independent session", model: "test")
        next.workspace = source.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        try approve(h, task: next, request: request)
        do {
            let admission = try #require(try RuntimeWorkspaceContinuation.admission(task: next, request: request,
                previous: nil, context: h.context))
            #expect(admission.excludedClaims.allSatisfy { $0.resourceKind == .workspace || $0.resourceKind == .gitCommonDirectory })
        }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: next, context: h.context,
            maxRunSeconds: 60, userRequest: request))
        defer { owner.finish() }
        for session in ["requested-session", "reported-session"] {
            #expect(throws: (any Error).self) { try owner.prepareLaunch(sessionID: session) }
        }
        try owner.prepareLaunch(sessionID: "independent-session")
        #expect(try RuntimeExecutionOwner.existing(task: source, context: h.context) == original)
    }
    private func save(_ record: RuntimeExecutionOwnerRecord, _ h: HeadlessChatHarness) throws {
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }
    private func next(_ h: HeadlessChatHarness, after task: AgentTask) throws -> (AgentTask, TaskTurnRequest) {
        let next = h.makeTask(runtime: .codexCLI, goal: "Saved initial instruction", model: "test")
        next.workspace = task.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: h.context).get()
        return (next, try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context)))
    }
    private func approve(_ h: HeadlessChatHarness, task: AgentTask, request: TaskTurnRequest) throws {
        let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context)
        try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context)
    }

    @Test("Only the explicitly authorized successor can start; old evidence, requests and results stay intact")
    func exclusiveSuccessor() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try completed(h)
        let (b, request) = try next(h, after: a)
        let (c, thirdRequest) = try next(h, after: a)
        let before = request.snapshot
        let store = RuntimeExecutionOwner.store(in: h.context)
        let originalURL = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID).recordURL
        let bytes = try Data(contentsOf: originalURL)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: b, runMode: "initial", sandboxEnforcement: .off)
        #expect(!queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        try approve(h, task: b, request: request)
        #expect(request.snapshot == before)
        queue.refreshResourceOwnership(in: h.context)
        #expect(queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context,
            maxRunSeconds: 60, userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == request.id)
        #expect(owner.record.inheritedToolUncertainty == true && owner.record.resourcesReleased == false)
        let follow = try ExecutionRequestSubmissionService.submitFollowUp(message: "Competing old turn", for: a, into: h.context).get()
        let oldRequest = try #require(try TaskTurnRequestRepository.request(id: follow.requestID, in: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: a, context: h.context, maxRunSeconds: 60, userRequest: oldRequest) == nil)
        #expect(RuntimeExecutionOwner.acquire(task: c, context: h.context, maxRunSeconds: 60, userRequest: thirdRequest) == nil)
        #expect(try Data(contentsOf: originalURL) == bytes)
        #expect(try store.read(taskID: a.id, taskOwnerID: a.persistentModelID) == original)
        #expect(a.runs.first?.output == "Preserved answer")
    }

    @Test("Cancelled, replayed, automatic and imported requests cannot use a workspace grant", arguments: ["cancel", "retry", "scheduled", "started", "sourceRun", "imported", "changedScope"])
    func requestFences(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try completed(h)
        let (b, request) = try next(h, after: a)
        try approve(h, task: b, request: request)
        switch fault {
        case "cancel": _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled)
        case "retry": request.kind = .retry
        case "scheduled": request.kind = .scheduled
        case "started": request.startedAt = Date()
        case "sourceRun": TaskHistoryRead.event(id: request.sourceEventID, in: b)?.run = a.runs.first
        case "imported":
            let other = h.makeTask(runtime: .codexCLI, goal: "Copy", model: "test")
            other.id = b.id; try h.context.save()
            #expect(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
            return
        default:
            let unrelated = [TaskResourceLockClaim(taskID: b.id, resourceKey: h.rootURL.appendingPathComponent("unrelated").path,
                accessMode: .write, runMode: "moved", requestID: request.id)]
            #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request, resourceClaims: unrelated) == nil)
            return
        }
        try h.context.save()
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    @Test("Changed, live, cancelled and unfinished predecessors invalidate approval", arguments: ["changed", "liveLease", "cancelled", "settlement", "running", "missingReceipt"])
    func sourceFences(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, initial) = try completed(h)
        let (b, request) = try next(h, after: a)
        let proposal = try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var live: RuntimeExecutionOwnerStore.Lease?
        defer { withExtendedLifetime(live) {} }
        var changed = initial
        switch fault {
        case "changed": changed.limits.tokensSpent += 1
        case "liveLease": live = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
        case "cancelled": changed.cancellationRequested = true
        case "settlement": changed.settlementInProgress = true
        case "running": a.runs.first?.status = .running
        default:
            let lease = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        if fault != "liveLease" && fault != "missingReceipt" { try save(changed, h) }
        try h.context.save()
        #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: request, context: h.context) }
        #expect(try store.workspaceContinuation(requestID: request.id) == nil)
    }

    @Test("A restart before launch reuses the same authorization and spent limits; launch intent never replays", arguments: [false, true])
    func interruptedPreparation(launched: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try completed(h)
        let (b, request) = try next(h, after: a)
        try approve(h, task: b, request: request)
        let first = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 20, userRequest: request))
        var saved = first.record; first.finish()
        saved.limits.secondsRemaining = 9; saved.limits.tokensSpent = 7
        saved.state = launched ? .launching : .notStarted
        try save(saved, h)
        let again = RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 900, userRequest: request)
        if launched { #expect(again == nil); return }
        let owner = try #require(again); defer { owner.finish() }
        #expect(owner.record.limits == saved.limits)
        #expect(owner.record.ownerID == saved.ownerID)
        #expect(owner.record.workspaceContinuationRequestID == request.id)
    }

    @Test("Unlaunched preparation cannot hide unsettled tools or an unbound started request", arguments: ["tools", "binding"])
    func unsafePreparation(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try completed(h)
        let (b, request) = try next(h, after: a)
        try approve(h, task: b, request: request)
        let first = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 20, userRequest: request))
        var saved = first.record; first.finish()
        saved.state = .notStarted; saved.settlementLocalWorkStopped = true
        if fault == "tools" { saved.settlementToolsStopped = false }
        else { saved.runID = UUID(); request.startedAt = Date(); request.runID = nil }
        try save(saved, h); try h.context.save()
        #expect(!RuntimeWorkspaceContinuation.resumesPreparation(saved, task: b, request: request, context: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    @Test("Persisted authorization survives reopening the disk container")
    func diskReopen() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try completed(h)
        let (b, request) = try next(h, after: a)
        try approve(h, task: b, request: request)
        let id = b.id; let requestID = request.id
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: Array(h.container.configurations))
        let context = reopened.mainContext
        let restored = try #require(try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        let pending = try #require(try TaskTurnRequestRepository.request(id: requestID, in: context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: restored, context: context,
            maxRunSeconds: 60, userRequest: pending))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == requestID)
        #expect(owner.record.inheritedToolUncertainty == true)
    }

    @Test("Two approved successors still have one exclusive owner and respect the admission lease")
    func competingApprovals() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try completed(h)
        let (b, br) = try next(h, after: a)
        let (c, cr) = try next(h, after: a)
        try approve(h, task: b, request: br); try approve(h, task: c, request: cr)
        do {
            let held = try RuntimeExecutionOwner.store(in: h.context).acquireAdmission()
            defer { withExtendedLifetime(held) {} }
            #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: br) == nil)
        }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: br))
        defer { owner.finish() }
        #expect(RuntimeExecutionOwner.acquire(task: c, context: h.context, maxRunSeconds: 60, userRequest: cr) == nil)
        let queue = TaskQueue(poolSize: 0); queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: cr, task: c, runMode: "initial", sandboxEnforcement: .off)
        #expect(!queue.canAcquireResourceLocks(claims, task: c, context: h.context))
    }

    @Test("A different source event or automatic source cannot inherit an interrupted preparation", arguments: [false, true])
    func changedPreparedSource(automatic: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, _) = try completed(h)
        let (b, request) = try next(h, after: a)
        try approve(h, task: b, request: request)
        let first = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 20, userRequest: request))
        var saved = first.record; first.finish(); saved.state = .notStarted
        let source = try #require(TaskHistoryRead.event(id: request.sourceEventID, in: b))
        if automatic {
            source.payload = TaskEvent.payloadString(TaskExecutionSourcePayloadV1(launchMode: .initial, scheduleID: UUID()))
        } else {
            let replacement = TaskEvent(task: b, type: source.type, payload: source.payload)
            h.context.insert(replacement); request.messageEventID = replacement.id
        }
        try save(saved, h); try h.context.save()
        #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    private func sshStore(_ h: HeadlessChatHarness, task a: AgentTask,
                          owner old: RuntimeExecutionOwnerRecord) throws -> RemoteWorkspaceJobStore {
        let store = RuntimeExecutionOwner.store(in: h.context)
        let root = RemoteWorkspaceJobRegistration.directory(taskID: a.id, executionID: old.executionID, context: h.context)
        let receiptURL = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID).recordURL
        var config = RemoteWorkspaceJobConfiguration(recordRootPath: root.appendingPathComponent("jobs").path,
            sshExecutable: "/usr/bin/ssh", connections: [], taskID: a.id.uuidString, runID: old.runID?.uuidString,
            ownerBinding: .init(receiptPath: receiptURL.path, taskID: a.id.uuidString, runID: try #require(old.runID).uuidString,
                ownerID: old.ownerID.uuidString, executionID: old.executionID.uuidString))
        config.observationSSHOptions = RemoteWorkspaceJobRegistration.observationOptions(task: a)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RemoteWorkspaceJobProtectedFile.write(JSONEncoder().encode(config), to: root.appendingPathComponent("configuration.json"))
        return RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
    }

    private func sshJob(task: AgentTask, owner: RuntimeExecutionOwnerRecord) -> RemoteWorkspaceJobRecord {
        var job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: task.id.uuidString,
            runID: owner.runID?.uuidString, connection: .init(id: "fixture", name: "Fixture", target: "fixture", arguments: ["fixture"]),
            command: "true", createdAt: Date())
        job.ownerID = owner.ownerID.uuidString
        job.executionID = owner.executionID.uuidString
        job.status = .running
        return job
    }

    @Test("Known nonterminal SSH jobs block continuation even in retained lineage", arguments: [false, true])
    func knownRemoteJobs(retained: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, old) = try completed(h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let jobs = try sshStore(h, task: a, owner: old)
        if retained {
            try store.retain(old)
            var current = old; current.executionID = UUID(); current.retainedExecutionHead = old.executionID
            let proof = try #require(old.stopProof)
            current.stopProof = .init(executionID: current.executionID, process: proof.process, reaped: true,
                processGroupEmpty: true, toolsStopped: false, remoteWorkExcluded: false, capturedAt: Date())
            try save(current, h)
        }
        let (b, request) = try next(h, after: a)
        // The same registration with no jobs is admissible before a late job appears.
        let proposal = try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context)
        try jobs.create(sshJob(task: a, owner: old))
        #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: request, context: h.context) }
        #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context) }
        #expect(try store.workspaceContinuation(requestID: request.id) == nil)
    }

    @Test("A reviewed legacy cancellation admits only the saved request with matching host evidence",
          arguments: ["sealed", "oldV3", "unreachable", "stale", "running", "newJob", "changedNonce", "missing"])
    func scopedSSHDecision(condition: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try completed(h)
        let jobs = try sshStore(h, task: a, owner: original)
        var job = sshJob(task: a, owner: original)
        job.schemaVersion = condition == "oldV3" ? 3 : 2
        job.status = condition == "oldV3" ? .cancelled : .unverified
        job.cancellationRequestedAt = Date()
        if condition == "oldV3" { job.launchFence = .cancelledBeforeStart }
        try jobs.create(job)
        let (b, request) = try next(h, after: a)
        let proposal = try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context, reviewSSHJobs: true)
        #expect(proposal.sources.flatMap { $0.reviewedSSHJobs ?? [] }.map(\.jobID) == [job.jobID])
        #expect(throws: (any Error).self) {
            try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: request, context: h.context, rememberWorkspace: true)
        }
        try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: request, context: h.context)
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: b, runMode: "fixture", sandboxEnforcement: .off)
        #expect(!queue.canAcquireResourceLocks(claims, task: b, context: h.context))
        try jobs.update(jobID: job.jobID) {
            $0.launchFence = condition == "oldV3" ? .cancelledBeforeStart : .legacySealed
            $0.lastObservation = .init(at: condition == "stale" ? .distantPast : Date(), outcome: condition == "unreachable" ? .unreachable : .reachable)
            if condition == "changedNonce" { $0.launchNonce = UUID().uuidString.lowercased() }
            if condition == "running" { $0.status = .running }
        }
        if condition == "newJob" { try jobs.create(sshJob(task: a, owner: original)) }
        if condition == "missing" { try FileManager.default.removeItem(at: jobs.recordURL(jobID: job.jobID)) }
        #expect(queue.canAcquireResourceLocks(claims, task: b, context: h.context) == ["sealed", "oldV3"].contains(condition))
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == original)
        let (c, other) = try next(h, after: a)
        let otherClaims = queue.resourceLockClaims(for: other, task: c, runMode: "fixture", sandboxEnforcement: .off)
        #expect(!queue.canAcquireResourceLocks(otherClaims, task: c, context: h.context))
    }

    @Test("An SSH observation cannot release missing jobs or inherited tool effects",
          arguments: ["missing", "newIdentity", "unreachable", "executed", "inherited", "v3", "missingPermit", "issuedPermit"])
    func incompleteSSHRelease(condition: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, initial) = try completed(h)
        let jobs = try sshStore(h, task: a, owner: initial)
        var job = sshJob(task: a, owner: initial); job.launchPermit = .pending
        if condition == "v3" { job.schemaVersion = 3 }
        try jobs.create(job)
        var owner = initial
        let proof = try #require(initial.stopProof)
        owner.stopProof = .init(executionID: owner.executionID, process: proof.process, reaped: true,
            processGroupEmpty: true, toolsStopped: true, remoteWorkExcluded: true, capturedAt: proof.capturedAt)
        owner.resourcesReleased = false
        owner.inheritedToolUncertainty = condition == "inherited"
        owner.pendingSSHJobSetDigest = try RuntimeWorkspaceRemoteJobs.releaseEvidence(task: a, owner: owner, context: h.context).identity
        try save(owner, h)
        try jobs.update(jobID: job.jobID) {
            $0.status = condition == "executed" ? .succeeded : .cancelled
            $0.launchPermit = condition == "missingPermit" ? nil : condition == "issuedPermit" ? .issued : .withdrawn
            $0.cancellationRequestedAt = Date()
            $0.launchFence = condition == "executed" ? nil : .cancelledBeforeStart
            $0.lastObservation = .init(at: Date(), outcome: condition == "unreachable" ? .unreachable : .reachable)
            if condition == "newIdentity" { $0.launchNonce = UUID().uuidString.lowercased() }
        }
        if condition == "missing" { try FileManager.default.removeItem(at: jobs.recordURL(jobID: job.jobID)) }
        try RuntimeHostNoToolReceiptReconciliation.reconcile(in: RuntimeExecutionOwner.store(in: h.context), context: h.context)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == owner)
    }

    @Test("An SSH confirmation wakes and runs the queued instruction once with no manual start",
          arguments: ["automatic", "copilot", "reviewed", "legacyReviewed"])
    func verifiedSSHReleaseDispatches(mode: String) async throws {
        // The in-memory container disables live SSH monitoring. The injected
        // observation below uses the same durable outbox and queue as the app.
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let a = h.makeTask(runtime: .claudeCode, goal: "Finish first", model: "claude-opus-5")
        let first = try #require(RuntimeExecutionOwner.acquire(task: a, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: a)
        h.context.insert(run)
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        try first.bind(run: run)
        try first.prepareLaunch()
        let child = AgentExecutionScopedProcess(executablePath: "/bin/sleep", arguments: ["0.1"],
            currentDirectory: h.workspaceURL.path, environment: ProcessInfo.processInfo.environment)
        try child.run()
        try first.launched(child)
        let config = try RemoteWorkspaceJobRegistration.prepare(task: a, runID: run.id, owner: first, context: h.context, connections: [])
        let jobs = RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
        var job = sshJob(task: a, owner: first.record)
        job.command = "sleep 10"
        let legacy = mode == "legacyReviewed"
        job.schemaVersion = legacy ? 2 : RemoteWorkspaceJobRecord.currentSchemaVersion
        job.status = legacy ? .unverified : .starting
        job.launchPermit = legacy ? nil : .pending
        job.remoteClock = .init(bootID: "fixture-boot", deadline: 60)
        try jobs.create(job)
        for _ in 0..<200 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let evidence = try RuntimeManagedSSHHelperEvidenceTests.evidence(runtime: mode == "copilot" ? .copilotCLI : .claudeCode)
        first.stopped(proof: child.stopProof(executionID: first.record.executionID,
            toolsStopped: false, remoteWorkExcluded: false, managedSSHOnly: !legacy && evidence.managedSSHOnly),
            turns: 1, tokens: 0, seconds: 1)
        try first.beginSettlement()
        a.status = .completed; run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        try first.completeSettlement(localWorkStopped: true, toolsStopped: true)
        first.finish()
        #expect((first.record.pendingSSHJobSetDigest != nil) == !legacy && first.record.resourcesReleased == false)
        let task = h.makeTask(runtime: .claudeCode, goal: "Answer once", model: "claude-opus-5")
        task.workspace = a.workspace
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ProviderStreams/claude/foreground-tool-completion.jsonl")
        let executable = try h.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body:
            "cat " + HeadlessChatScenarioTests.shQuote(fixture.path)))
        let queue = TaskQueue(poolSize: 1, workerFactory: {
            h.makeWorker(runtime: .claudeCode, executablePath: executable, permissionPolicy: .autonomous, sandboxEnforcementOverride: .off)
        }, sandboxEnforcementProvider: { .off })
        _ = queue.signalExecutionRequest(id: request.id, task: task, modelContext: h.context)
        for _ in 0..<200 where request.state != .waitingForResource { try await Task.sleep(for: .milliseconds(10)) }
        #expect(request.state == .waitingForResource && task.runs.isEmpty)
        if mode == "reviewed" || legacy {
            let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context, reviewSSHJobs: true)
            try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context)
        }
        let closed = try jobs.update(jobID: job.jobID) {
            $0.status = legacy ? .unverified : .cancelled
            $0.launchPermit = legacy ? nil : .withdrawn
            $0.cancellationRequestedAt = Date()
            $0.launchFence = legacy ? .legacySealed : .cancelledBeforeStart
            $0.lastObservation = .init(at: Date(), outcome: .reachable)
        }
        let wakeCount = queue.observedDispatchWakeCount
        let refreshCount = queue.remoteAdmissionRefresh.completedRefreshCount
        try RemoteWorkspaceJobEventReconciler.reconcile(closed, task: a, context: h.context, store: jobs)
        #expect(queue.remoteAdmissionRefresh.isPending)
        for _ in 0..<100 where queue.remoteAdmissionRefresh.isPending { await Task.yield() }
        #expect(queue.remoteAdmissionRefresh.completedRefreshCount == refreshCount + 1)
        #expect(queue.observedDispatchWakeCount > wakeCount)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context)?.resourcesReleased == !legacy)
        for _ in 0..<500 where request.state.isActive { try await Task.sleep(for: .milliseconds(20)) }
        #expect(request.state == .completed && task.runs.count == 1)
        #expect(request.id == submission.requestID)
        // The request verdict precedes the worker's asynchronous baseline save
        // and final lease release. A new review must use that final receipt.
        for _ in 0..<200 {
            if let settled = try RuntimeTaskOwnerJournal.read(task: task, context: h.context), settled.state == .finished,
               let lease = try? RuntimeTaskOwnerJournal.acquire(task: task, context: h.context) {
                withExtendedLifetime(lease) {}
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let successor = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(successor.state == .finished)
        #expect(successor.workspaceContinuationRequestID == (legacy ? request.id : nil))
        #expect((successor.inheritedToolUncertainty == true) == legacy)
        if legacy {
            let follow = try ExecutionRequestSubmissionService.submitFollowUp(message: "A separately reviewed question", for: task, into: h.context).get()
            let followRequest = try #require(try TaskTurnRequestRepository.request(id: follow.requestID, in: h.context))
            let claims = queue.resourceLockClaims(for: followRequest, task: task, runMode: "fixture", sandboxEnforcement: .off)
            #expect(!queue.canAcquireResourceLocks(claims, task: task, context: h.context))
            let fresh = try RuntimeWorkspaceContinuation.preview(task: task, request: followRequest, context: h.context,
                previous: successor, reviewSSHJobs: true)
            #expect(fresh.beneficiaryReceiptDigest != nil)
            try RuntimeWorkspaceContinuation.authorize(fresh, task: task, request: followRequest, context: h.context)
            #expect(try RuntimeExecutionOwner.store(in: h.context).workspaceContinuation(requestID: followRequest.id) == fresh)
            _ = queue.signalExecutionRequest(id: followRequest.id, task: task, modelContext: h.context)
            for _ in 0..<500 where followRequest.state.isActive { try await Task.sleep(for: .milliseconds(20)) }
            #expect(followRequest.state == .completed && task.runs.count == 2)
            #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.workspaceContinuationRequestID == followRequest.id)
        }
        _ = await queue.cancelAllAndWait()
    }

    @Test("Fresh follow-up review rejects cancelled, replayed and changed receiver requests", arguments: ["cancelled", "replayed", "receiverChanged"])
    func followUpReviewFences(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        _ = try completed(h)
        let (task, previous) = try completed(h)
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Review this request", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context, previous: previous, reviewSSHJobs: true)
        if fault == "cancelled" { _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled) }
        if fault == "replayed" { TaskHistoryRead.event(id: request.sourceEventID, in: task)?.run = task.runs.first }
        if fault == "receiverChanged" { var changed = previous; changed.limits.tokensSpent += 1; try save(changed, h) }
        #expect(throws: (any Error).self) {
            try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context, previous: previous, reviewSSHJobs: true)
        }
        #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context) }
        #expect(try RuntimeExecutionOwner.store(in: h.context).workspaceContinuation(requestID: request.id) == nil)
    }

    @Test("SSH release preserves immutable receipts, later observations, and predecessor follow-up",
          arguments: [false, true], ["plain", "legacyArchive", "laterObservation", "legacyArchiveAndObservation"])
    func releasePreservesHistory(advanceReview: Bool, archiveCase: String) throws {
        let legacyArchive = archiveCase.hasPrefix("legacyArchive")
        let laterObservation = archiveCase.contains("Observation")
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, initial) = try completed(h)
        let jobs = try sshStore(h, task: a, owner: initial)
        var job = sshJob(task: a, owner: initial); job.launchPermit = .pending
        try jobs.create(job)
        var original = initial
        let proof = try #require(initial.stopProof)
        original.inheritedToolUncertainty = false
        original.stopProof = .init(executionID: original.executionID, process: proof.process, reaped: true,
            processGroupEmpty: true, toolsStopped: true, remoteWorkExcluded: true, capturedAt: proof.capturedAt)
        original.resourcesReleased = false
        original.pendingSSHJobSetDigest = try RuntimeWorkspaceRemoteJobs.releaseEvidence(task: a, owner: original, context: h.context).identity
        try save(original, h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let archive = store.root.appendingPathComponent("retained/\(a.id.uuidString)/\(original.ownerID.uuidString)/\(original.executionID.uuidString).json")
        var archived: Data?
        if legacyArchive {
            var unattributed = original; unattributed.taskOwnerID = nil
            try store.retain(unattributed)
            archived = try Data(contentsOf: archive)
        }
        if advanceReview {
            let (b, request) = try next(h, after: a)
            let proposed = try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context, reviewSSHJobs: true)
            try RuntimeWorkspaceContinuation.authorize(proposed, task: b, request: request, context: h.context)
            archived = try Data(contentsOf: archive)
        }
        try jobs.update(jobID: job.jobID) {
            $0.launchPermit = .withdrawn; $0.status = .cancelled
            $0.cancellationRequestedAt = Date(); $0.launchFence = .cancelledBeforeStart
            $0.lastObservation = .init(at: Date(), outcome: .reachable)
        }
        try RuntimeHostNoToolReceiptReconciliation.reconcile(in: store, context: h.context)
        let released = try #require(try RuntimeExecutionOwner.existing(task: a, context: h.context))
        #expect(released.resourcesReleased == true && released.canReplace)
        // Repeating after an interrupted journal save reuses the immutable attestation.
        try save(original, h)
        try RuntimeHostNoToolReceiptReconciliation.reconcile(in: store, context: h.context)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == released)
        let attestation = store.root.appendingPathComponent("reconciliations/\(original.executionID.uuidString).release")
        let attestedBytes = try Data(contentsOf: attestation)
        if laterObservation {
            // The annotation may arrive after this generation was archived.
            // It must not become an input to the original release digest.
            try store.retain(released)
            if archived == nil { archived = try Data(contentsOf: archive) }
            var observed = released
            observed.legacyProviderReadObservation = .init(executionID: released.executionID,
                retainedHead: released.retainedExecutionHead, legacyKey: "antigravity_cli:/synthetic/legacy/settings",
                bootedAt: Date())
            try save(observed, h)
        }
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Continue the original task", for: a, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let acquisition = RuntimeExecutionOwner.acquire(task: a, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true, userRequest: request)
        let owner = try #require(acquisition)
        defer { owner.finish() }
        let history = try store.retainedExecutions(of: owner.record)
        #expect(history.first == released)
        #expect(try Data(contentsOf: attestation) == attestedBytes)
        if let archived { #expect(try Data(contentsOf: archive) == archived) }
        else { #expect(try RuntimeExecutionOwnerStore.read(archive) == released) }
        var unrelated = released; unrelated.limits.tokensSpent += 1
        #expect(throws: (any Error).self) { try store.retain(unrelated) }
    }

    @Test("Complete SSH inventories are paged and corrupt job pages fail closed",
        arguments: ["valid", "missing", "cycle", "duplicate", "corrupt", "symlink"])
    func pagedSSHInventory(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try completed(h)
        let jobs = try sshStore(h, task: a, owner: original)
        for _ in 0..<200 {
            var job = sshJob(task: a, owner: original)
            job.schemaVersion = 2; job.status = .unverified; job.cancellationRequestedAt = Date()
            job.launchFence = .legacySealed; job.lastObservation = .init(at: Date(), outcome: .reachable)
            try jobs.create(job)
        }
        let (b, request) = try next(h, after: a)
        let proposal = try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context, reviewSSHJobs: true)
        #expect(try JSONEncoder().encode(proposal.sources[0]).count > 32_768)
        try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: request, context: h.context)
        let store = RuntimeExecutionOwner.store(in: h.context)
        #expect(try store.workspaceContinuation(requestID: request.id) == proposal)
        let headerURL = store.root.appendingPathComponent(request.id.uuidString + ".handoff")
        let header = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: headerURL)) as? [String: Any])
        let entries = store.root.appendingPathComponent("workspace-continuations")
        let sourceHead = try #require(header["head"] as? String)
        let source = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: entries.appendingPathComponent(sourceHead + ".handoffentry"))) as? [String: Any])
        let head = try #require(source["reviewedJobHead"] as? String)
        let pageURL = entries.appendingPathComponent(head + ".handoffjobs")
        var page = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: pageURL)) as? [String: Any])
        if fault == "missing" { try FileManager.default.removeItem(at: pageURL) }
        if fault == "cycle" { page["next"] = head; try JSONSerialization.data(withJSONObject: page).write(to: pageURL) }
        if fault == "duplicate" {
            var items = try #require(page["jobs"] as? [[String: Any]]); items[1] = items[0]; page["jobs"] = items
            try JSONSerialization.data(withJSONObject: page).write(to: pageURL)
        }
        if fault == "corrupt" { try Data("{}".utf8).write(to: pageURL) }
        if fault == "symlink" {
            try FileManager.default.removeItem(at: pageURL)
            try FileManager.default.createSymbolicLink(at: pageURL, withDestinationURL: headerURL)
        }
        if fault == "valid" {
            #expect(try store.workspaceContinuation(requestID: request.id)?.sources[0].reviewedSSHJobs?.count == 200)
            let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
            owner.finish()
        } else {
            #expect(throws: (any Error).self) { try store.workspaceContinuation(requestID: request.id) }
            #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
        }
    }

    @Test("An unresolved SSH job blocks both the timeout check and a later launch")
    func timeoutCheckRemoteJobs() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, original) = try completed(h)
        let run = try #require(task.runs.first)
        run.status = .failed; run.typedStopReason = .providerRunWallClockExceeded
        task.status = .pendingUser
        var record = original
        record.state = .unverified; record.resourcesReleased = false
        let proof = try #require(record.stopProof)
        record.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
            processGroupEmpty: false, toolsStopped: false, remoteWorkExcluded: false, capturedAt: proof.capturedAt)
        try save(record, h)
        let jobs = try sshStore(h, task: task, owner: record)
        func startJob() throws -> String {
            let job = sshJob(task: task, owner: record)
            try jobs.create(job)
            return job.jobID
        }
        let first = try startJob()
        #expect(throws: (any Error).self) { try RuntimeTimeoutRecoveryCheck.check(task: task, runID: run.id, context: h.context) }
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == record)
        try jobs.update(jobID: first) { $0.status = .succeeded }
        try RuntimeTimeoutRecoveryCheck.check(task: task, runID: run.id, context: h.context)
        _ = try startJob()
        let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: "New question", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
        #expect(task.runs.count == 1 && request.runID == nil)
    }

    @Test("Resumed timeout preparation revalidates retained SSH registrations", arguments:
        ["terminal", "running", "unreadable", "missingRegistration", "changedRegistration"], [1, 2])
    func resumedTimeoutPreparationChecksRemoteJobs(fault: String, preparationCount: Int) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, original) = try completed(h)
        let run = try #require(task.runs.first)
        run.status = .failed; run.typedStopReason = .providerRunWallClockExceeded
        task.status = .pendingUser
        var record = original
        record.state = .unverified; record.resourcesReleased = false
        let proof = try #require(record.stopProof)
        record.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
            processGroupEmpty: false, toolsStopped: false, remoteWorkExcluded: false, capturedAt: proof.capturedAt)
        try save(record, h)
        let jobs = try sshStore(h, task: task, owner: record)
        var job = sshJob(task: task, owner: record)
        job.status = .succeeded
        try jobs.create(job)
        try RuntimeTimeoutRecoveryCheck.check(task: task, runID: run.id, context: h.context)
        let checked = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(checked.stopProof?.groupObservedEmptyAt != nil)
        let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: "New question", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
        for _ in 0..<preparationCount {
            let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
                maxRunSeconds: 60, userRequest: request))
            owner.finish() // End preparation without crossing the provider launch boundary.
        }
        let interrupted = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(interrupted.stopProof == nil && interrupted.providerProcess == nil)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let retained = try store.retainedExecutions(of: interrupted)
        #expect(retained.count == preparationCount && retained.last == checked)
        let registration = RemoteWorkspaceJobRegistration.directory(taskID: task.id,
            executionID: checked.executionID, context: h.context).appendingPathComponent("configuration.json")
        switch fault {
        case "running": try jobs.update(jobID: job.jobID) { $0.status = .running }
        case "unreadable": try Data("{}".utf8).write(to: registration)
        case "missingRegistration": try FileManager.default.removeItem(at: registration)
        case "changedRegistration":
            var configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registration)) as? [String: Any])
            var binding = try #require(configuration["ownerBinding"] as? [String: Any])
            binding["executionID"] = UUID().uuidString; configuration["ownerBinding"] = binding
            try JSONSerialization.data(withJSONObject: configuration).write(to: registration)
        default: break
        }
        // Local continuation still has a valid basis. Admission must also reread
        // the original registration even though the current receipt has no proof.
        #expect(RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: h.context))
        let resumed = RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, userRequest: request)
        defer { resumed?.finish() }
        if fault == "terminal" {
            let resumed = try #require(resumed)
            #expect(resumed.record.ownerID == checked.ownerID)
            #expect(resumed.record.continuingUserRequestID == request.id)
            #expect(resumed.record.resourcesReleased == false)
        } else {
            #expect(resumed == nil)
            #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == interrupted)
            #expect(try store.retainedExecutions(of: interrupted) == retained)
        }
        #expect(task.runs.count == 1 && request.runID == nil && request.startedAt == nil)
        #expect(run.status == .failed && run.typedStopReason == .providerRunWallClockExceeded)
    }

    @Test("Timeout recovery with workspace approval rejects host-only cancellations in current and retained jobs",
          arguments: ["v3Cancelled", "v3Withdrawn", "v4Missing", "v4Issued", "withdrawn", "noRemote"], ["check", "current", "retainedOnce", "retainedTwice"])
    func timeoutCancellationInventory(condition: String, stage: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let preparationCount = stage == "retainedTwice" ? 2 : stage == "retainedOnce" ? 1 : 0
        let (holder, task, grantRequest) = try completedRememberedWorkspace(h)
        let holderReceipt = try RuntimeExecutionOwner.existing(task: holder, context: h.context)
        var original = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        let run = try #require(task.runs.first)
        run.status = .failed; run.typedStopReason = .providerRunWallClockExceeded
        task.status = .pendingUser
        original.state = .unverified; original.resourcesReleased = false
        let proof = try #require(original.stopProof)
        original.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
            processGroupEmpty: false, toolsStopped: false, remoteWorkExcluded: false, capturedAt: proof.capturedAt)
        try save(original, h)
        let jobs = try sshStore(h, task: task, owner: original)
        let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: "A new reviewed question", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
        // The persisted workspace grant cannot replace the required timeout check.
        #expect(original.workspaceContinuationRequestID == grantRequest.id)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
        #expect(throws: (any Error).self) {
            try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context,
                previous: original, reviewSSHJobs: true)
        }
        if stage != "check" {
            try RuntimeTimeoutRecoveryCheck.check(task: task, runID: run.id, context: h.context)
            for _ in 0..<preparationCount {
                let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
                    maxRunSeconds: 60, userRequest: request))
                owner.finish()
            }
        }
        if condition != "noRemote" {
            var job = sshJob(task: task, owner: original)
            job.schemaVersion = condition.hasPrefix("v3") ? 3 : RemoteWorkspaceJobRecord.currentSchemaVersion
            job.status = .cancelled; job.launchFence = .cancelledBeforeStart
            job.launchPermit = ["withdrawn", "v3Withdrawn"].contains(condition) ? .withdrawn : condition == "v4Issued" ? .issued : nil
            job.cancellationRequestedAt = Date(); job.lastObservation = .init(at: Date(), outcome: .reachable)
            job.remoteClock = .init(bootID: "fixture-boot", deadline: 60)
            try jobs.create(job)
            #expect(try jobs.load(jobID: job.jobID).status == .cancelled)
        }
        let blocked = !["withdrawn", "noRemote"].contains(condition)
        let inventory = try RuntimeWorkspaceRemoteJobs.inventory(task: task, context: h.context)
        #expect(inventory.count == (condition == "noRemote" ? 0 : 1))
        if condition != "noRemote" { #expect(inventory[0].status == (blocked ? .unverified : .cancelled)) }
        let before = try #require(try RuntimeTaskOwnerJournal.read(task: task, context: h.context))
        let store = RuntimeExecutionOwner.store(in: h.context)
        let retained = try store.retainedExecutions(of: before)
        #expect(retained.count == preparationCount)
        if stage == "check" {
            if blocked {
                #expect(throws: (any Error).self) { try RuntimeTimeoutRecoveryCheck.check(task: task, runID: run.id, context: h.context) }
            } else {
                try RuntimeTimeoutRecoveryCheck.check(task: task, runID: run.id, context: h.context)
            }
        } else {
            #expect(RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: h.context))
        }
        if blocked {
            #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.requireNoKnownRemoteWork(task: task, context: h.context) }
            #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
            #expect(try RuntimeTaskOwnerJournal.read(task: task, context: h.context) == before)
            #expect(try store.retainedExecutions(of: before) == retained)
        } else {
            try RuntimeWorkspaceContinuation.requireNoKnownRemoteWork(task: task, context: h.context)
            let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
            #expect(owner.record.ownerID == original.ownerID && owner.record.resourcesReleased == false)
            #expect(owner.record.workspaceContinuationRequestID == grantRequest.id)
            owner.finish()
        }
        #expect(task.runs.count == 1 && request.runID == nil && request.startedAt == nil)
        #expect(run.status == .failed && run.typedStopReason == .providerRunWallClockExceeded)
        #expect(try RuntimeExecutionOwner.existing(task: holder, context: h.context) == holderReceipt)
    }

    @Test("Large predecessor sets use protected entries and partial or corrupt chains fail closed", arguments: ["valid", "missing", "cycle", "symlink"])
    func pagedAuthorization(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        var last: AgentTask?
        for _ in 0..<24 { last = try completed(h).0 }
        let (b, request) = try next(h, after: #require(last))
        let proposed = try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context)
        #expect(try JSONEncoder().encode(proposed).count > 32_768)
        try RuntimeWorkspaceContinuation.authorize(proposed, task: b, request: request, context: h.context)
        let store = RuntimeExecutionOwner.store(in: h.context)
        #expect(try store.workspaceContinuation(requestID: request.id) == proposed)
        let headerURL = store.root.appendingPathComponent(request.id.uuidString + ".handoff")
        let header = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: headerURL)) as? [String: Any])
        let head = try #require(header["head"] as? String)
        let entryURL = store.root.appendingPathComponent("workspace-continuations").appendingPathComponent(head + ".handoffentry")
        if fault == "missing" { try FileManager.default.removeItem(at: entryURL) }
        if fault == "cycle" {
            var entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: entryURL)) as? [String: Any])
            entry["next"] = head
            try JSONSerialization.data(withJSONObject: entry).write(to: entryURL)
        }
        if fault == "symlink" {
            try FileManager.default.removeItem(at: entryURL)
            try FileManager.default.createSymbolicLink(at: entryURL, withDestinationURL: headerURL)
        }
        if fault == "valid" {
            let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
            owner.finish()
        } else {
            #expect(throws: (any Error).self) { try store.workspaceContinuation(requestID: request.id) }
            #expect(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
        }
    }

    @Test("Every predecessor in a waiting request's saved continuation keeps fresh SSH checks")
    func waitingContinuationAwaitsEverySource() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (first, _) = try completed(h)
        let (second, _) = try completed(h)
        let (b, request) = try next(h, after: second)
        try approve(h, task: b, request: request)
        let sources = try #require(try RuntimeExecutionOwner.store(in: h.context).workspaceContinuation(requestID: request.id)).sources
        #expect(Set(sources.map(\.receipt.taskID)) == [first.id, second.id])
        // The queue names only the first conflicting holder.
        TaskTurnRequestStateMachine.transition(request, to: .waitingForResource, blockingTaskID: first.id)
        #expect(request.state == .waitingForResource)
        try h.context.save()
        #expect(try RemoteWorkspaceJobMonitorSession.awaitedTaskIDs(context: h.context) == [first.id, second.id])
    }

    @Test("Legacy quoted SSH aliases stay readable only with identical saved destinations", arguments: ["same", "target", "arguments", "id", "name", "duplicate"], ["alias", "quoted", "identity"])
    func legacySSHRendering(fault: String, style: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "SSH registration", model: "test")
        let connection = SSHConnection(name: "QA", host: "unused.example.test", user: "qa",
            keyPath: style == "identity" ? "~/keys/qa key" : "",
            configAlias: style == "identity" ? "" : (style == "quoted" ? "qa'host with space" : "qa-alias"))
        let legacy = style == "identity" ? "'-i' '~/keys/qa key' 'qa@unused.example.test'"
            : (style == "quoted" ? "'qa'\\''host with space'" : "'qa-alias'")
        SSHConnectionManager.save([connection], workspacePath: h.workspaceURL.path)
        let connections = RemoteWorkspaceJobShim.offeredConnections(task: task, targets: [RemoteWorkspaceSSHRoute.connectTarget(for: connection)])
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run); try owner.prepareLaunch()
        _ = try RemoteWorkspaceJobRegistration.prepare(task: task, runID: run.id, owner: owner, context: h.context, connections: connections)
        let url = RemoteWorkspaceJobRegistration.directory(taskID: task.id, executionID: owner.record.executionID, context: h.context)
            .appendingPathComponent("configuration.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var items = try #require(json["connections"] as? [[String: Any]])
        items[0]["target"] = fault == "target" ? "different-destination" : legacy
        if fault == "arguments" { items[0]["arguments"] = ["different-destination"] }
        if fault == "id" { items[0]["id"] = UUID().uuidString }
        if fault == "name" { items[0]["name"] = "Changed name" }
        if fault == "duplicate" { SSHConnectionManager.save([connection, connection], workspacePath: h.workspaceURL.path) }
        json["connections"] = items
        let data = try JSONSerialization.data(withJSONObject: json)
        try RemoteWorkspaceJobProtectedFile.write(data, to: url)
        if fault == "same" { #expect(try RemoteWorkspaceJobRegistration.loadAll(task: task, context: h.context).count == 1) }
        else { #expect(throws: (any Error).self) { try RemoteWorkspaceJobRegistration.loadAll(task: task, context: h.context) } }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("An attributed legacy receipt covers older owners on the same row, while copied rows keep their fences", arguments: ["same", "imported", "ambiguous", "orphan"])
    func legacyOwnerProjection(mode: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, current) = try completed(h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        do {
            let scoped = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
            try FileManager.default.removeItem(at: scoped.recordURL)
        }
        var legacy = current; legacy.taskOwnerID = nil
        do { let lease = try store.acquire(taskID: a.id); try lease.save(legacy) }
        h.context.insert(TaskEvent(task: a, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: TaskEvent.payloadString(legacy)))
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        oldJSON["ownerID"] = UUID().uuidString
        var old = try JSONDecoder().decode(RuntimeExecutionOwnerRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        old.executionID = UUID()
        old.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: a,
            runMode: "old_owner", sandboxEnforcement: .off)
        let auditTask: AgentTask
        if mode == "imported" || mode == "ambiguous" {
            auditTask = h.makeTask(runtime: .claudeCode, goal: "Imported copy", model: "test")
            auditTask.id = a.id
        } else { auditTask = a }
        let oldEvent = TaskEvent(task: auditTask, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: TaskEvent.payloadString(old))
        if mode == "orphan" { oldEvent.task = nil }
        h.context.insert(oldEvent)
        if mode == "ambiguous" {
            h.context.insert(TaskEvent(task: auditTask, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(legacy)))
        }
        try h.context.save()
        let originalAudit = oldEvent.payload
        let originalBytes = try Data(contentsOf: store.root.appendingPathComponent(a.id.uuidString + ".json"))
        let claims = try RuntimeResourceOwnership.claims(in: store, context: h.context)
        #expect(oldEvent.payload == originalAudit)
        #expect(try Data(contentsOf: store.root.appendingPathComponent(a.id.uuidString + ".json")) == originalBytes)
        if mode != "same" { #expect(Set(old.resourceClaims!).isSubset(of: Set(claims))) }
        else {
            #expect(Set(claims) == Set(legacy.resourceClaims!))
            let (b, request) = try next(h, after: a)
            try approve(h, task: b, request: request)
            let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
            owner.finish()
            #expect(try store.read(taskID: a.id) == legacy)
        }
    }

    @Test("Forked historical audit does not duplicate a verified source fence; missing source authority still blocks", arguments: ["verified", "missing", "unmatched", "otherRow"])
    func forkedAuditProjection(mode: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, original) = try completed(h)
        let fork = h.makeTask(runtime: .claudeCode, goal: "Fork", model: "test")
        fork.forkedFromID = a.id
        var copied = original; copied.executionID = UUID()
        copied.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: a,
            runMode: "fork_history", sandboxEnforcement: .off)
        let event = TaskEvent(task: fork, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: TaskEvent.payloadString(copied))
        if mode != "unmatched" {
            let source: AgentTask
            if mode == "otherRow" {
                source = h.makeTask(runtime: .claudeCode, goal: "Other same UUID row", model: "test")
                source.id = a.id
            } else { source = a }
            h.context.insert(TaskEvent(task: source, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(copied)))
        }
        h.context.insert(event); try h.context.save()
        let store = RuntimeExecutionOwner.store(in: h.context)
        if mode == "missing" {
            let lease = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        let before = event.payload
        let claims = try RuntimeResourceOwnership.claims(in: store, context: h.context)
        if mode != "verified" { #expect(Set(copied.resourceClaims!).isSubset(of: Set(claims))) }
        else {
            #expect(Set(claims) == Set(original.resourceClaims!))
            let (b, request) = try next(h, after: a)
            try approve(h, task: b, request: request)
            let owner = try #require(RuntimeExecutionOwner.acquire(task: b, context: h.context, maxRunSeconds: 60, userRequest: request))
            owner.finish()
            #expect(try RuntimeExecutionOwner.existing(task: a, context: h.context) == original)
        }
        #expect(event.payload == before)
    }

    @Test("One queue runs and revisits four tool-using tasks with SSH and one workspace approval")
    func successiveWorkerTasks() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        SSHConnectionManager.save([SSHConnection(name: "configured-unused", host: "unused.example.test",
            user: "fixture", remotePath: "/srv")], workspacePath: h.workspaceURL.path)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderStreams/claude/foreground-tool-completion.jsonl")
        let frames = h.rootURL.appendingPathComponent("frames.jsonl")
        let fixtureText = try String(contentsOf: fixture, encoding: .utf8)
        func stageFrames(for task: AgentTask) throws {
            try fixtureText.replacingOccurrences(of: "foreground-fixture", with: "fixture-" + task.id.uuidString)
                .write(to: frames, atomically: true, encoding: .utf8)
        }
        let executable = try h.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body:
            "cat " + HeadlessChatScenarioTests.shQuote(frames.path)))
        let policy = AgentRuntimeExecutionPolicy.default.withRemoteSSHRoute(
            RemoteWorkspaceSSHRoute(targets: ["fixture@unused.example.test"], route: .nativeShell))
        let queue = TaskQueue(poolSize: 0)
        var previous: AgentTask?
        var sequence: [AgentTask] = []
        for index in 1...4 {
            let task = h.makeTask(runtime: .claudeCode, goal: "Task \(index)", model: "claude-opus-5")
            if let previous { task.workspace = previous.workspace }
            let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: h.context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
            if index == 2 {
                let proposal = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context)
                try RuntimeWorkspaceContinuation.authorize(proposal, task: task, request: request, context: h.context, rememberWorkspace: true)
            }
            if index > 2 {
                queue.refreshResourceOwnership(in: h.context)
                let claims = queue.resourceLockClaims(for: request, task: task, runMode: "initial", sandboxEnforcement: .off)
                #expect(queue.canAcquireResourceLocks(claims, task: task, context: h.context))
                #expect(try RuntimeExecutionOwner.store(in: h.context).workspaceContinuation(requestID: request.id) == nil)
            }
            let leaseID = UUID()
            let claims = queue.resourceLockClaims(for: request, task: task, runMode: "task", sandboxEnforcement: .off).map { $0.leased(leaseID) }
            let lease = try #require(queue.acquireResourceLocksIfAvailable(claims, task: task, modelContext: h.context))
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: h.context)
            try stageFrames(for: task)
            let worker = h.makeWorker(runtime: .claudeCode, executablePath: executable, permissionPolicy: .autonomous)
            _ = await worker.execute(task: task, modelContext: h.context, executionRequestID: request.id,
                executionPolicy: policy.withResourceAdmission(workspaceAccess: .exclusive, sandboxEnforcement: .off, claims: lease)) { _ in }
            try h.context.save()
            queue.releaseResourceLocks(lease, task: task, modelContext: h.context)
            #expect(queue.localResourceLocks.isEmpty)
            #expect(!queue.persistedResourceLocks.isEmpty)
            #expect(task.status == .completed)
            #expect(task.runs.count == 1)
            #expect(task.events.contains { $0.type == "tool.use" })
            let receipt = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
            #expect(receipt.stopProof?.toolsStopped == false && receipt.resourcesReleased == false)
            previous = task
            sequence.append(task)
        }
        #expect(Set(sequence.compactMap(\.sessionId)).count == 4)
        for index in [1, 2, 1, 0] {
            let task = sequence[index]
            let originalSession = task.sessionId
            let before = task.runs.count
            let message = "Return to task \(index)"
            let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: message, for: task, into: h.context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
            let leaseID = UUID()
            let claims = queue.resourceLockClaims(for: request, task: task, runMode: "continue", sandboxEnforcement: .off).map { $0.leased(leaseID) }
            let lease = try #require(queue.acquireResourceLocksIfAvailable(claims, task: task, modelContext: h.context))
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: h.context)
            try stageFrames(for: task)
            let worker = h.makeWorker(runtime: .claudeCode, executablePath: executable, permissionPolicy: .autonomous)
            await worker.continueSession(task: task, message: message, existingMessageEventID: submitted.eventID,
                turnRequestID: request.id, modelContext: h.context,
                executionPolicy: policy.withResourceAdmission(workspaceAccess: .exclusive, sandboxEnforcement: .off, claims: lease)) { _ in }
            try h.context.save()
            queue.releaseResourceLocks(lease, task: task, modelContext: h.context)
            #expect(queue.localResourceLocks.isEmpty)
            #expect(!queue.persistedResourceLocks.isEmpty)
            #expect(task.status == .completed)
            #expect(task.runs.count == before + 1)
            #expect(task.sessionId == originalSession)
        }
    }

    @Test("Only a completed protected owner can replace a local lease with a durable fence", arguments:
        ["completed", "cancelled", "settling", "running", "failed", "extraResource", "weakerAccess", "otherOwner", "missing", "corrupt", "liveLease"])
    func completedLocalLeaseRetirement(mode: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, original) = try completed(h)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var record = original
        let leaseID = UUID()
        var claims = (record.resourceClaims ?? []).map { $0.leased(leaseID) }
        record.resourceClaims = claims
        var receiver = task
        switch mode {
        case "cancelled": record.cancellationRequested = true
        case "settling": record.settlementInProgress = true
        case "running": task.runs.first?.status = .running
        case "failed": task.runs.first?.status = .failed
        case "extraResource": claims.append(.init(taskID: task.id, resourceKey: h.rootURL.appendingPathComponent("uncaptured").path,
            accessMode: .write, runMode: "task", leaseID: leaseID))
        case "weakerAccess": record.resourceClaims?[0].accessMode = .readOnly
        case "otherOwner":
            receiver = h.makeTask(runtime: .claudeCode, goal: "Imported row", model: "test")
            receiver.id = task.id
        default: break
        }
        try save(record, h); try h.context.save()
        let url = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID).recordURL
        if mode == "missing" { try FileManager.default.removeItem(at: url) }
        if mode == "corrupt" { try Data("invalid".utf8).write(to: url) }
        var active: RuntimeExecutionOwnerStore.Lease?
        if mode == "liveLease" { active = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID) }
        defer { withExtendedLifetime(active) {} }
        let bytes = try? Data(contentsOf: url)
        let canRetire = (try? RuntimeResourceOwnership.canRetireLocalClaims(claims, task: receiver, context: h.context)) ?? false
        #expect(canRetire == (mode == "completed"))
        if ["completed", "cancelled", "settling", "running", "failed", "extraResource", "liveLease"].contains(mode) {
            let queue = TaskQueue(poolSize: 0); queue.localResourceLocks = claims
            queue.releaseResourceLocks(claims, task: task, modelContext: h.context)
            #expect(queue.localResourceLocks.isEmpty == (mode == "completed"))
            #expect(!queue.persistedResourceLocks.isEmpty)
            let contender = TaskResourceLockClaim(taskID: UUID(), resourceKey: claims[0].resourceKey,
                accessMode: .write, runMode: "unapproved", resourceKind: claims[0].resourceKind)
            #expect(!queue.canAcquireResourceLocks([contender]))
            if mode == "completed" {
                let later = claims.map { $0.leased(UUID()) }
                queue.localResourceLocks = later
                queue.releaseResourceLocks(claims, task: task, modelContext: h.context)
                #expect(queue.localResourceLocks == later)
            }
        }
        #expect((try? Data(contentsOf: url)) == bytes)
    }

    private func completedRememberedWorkspace(_ h: HeadlessChatHarness, legacySource: Bool = false, cleanCrash: Bool = false) throws -> (AgentTask, AgentTask, TaskTurnRequest) {
        let (old, original) = try completed(h)
        if cleanCrash {
            var receipt = original; receipt.state = .stopped; receipt.inheritedToolUncertainty = false
            receipt.resourcesReleased = false
            let proof = try #require(receipt.stopProof)
            receipt.stopProof = .init(executionID: proof.executionID, process: proof.process,
                reaped: true, processGroupEmpty: true, toolsStopped: true, remoteWorkExcluded: true, capturedAt: proof.capturedAt)
            try save(receipt, h)
        }
        if legacySource {
            let store = RuntimeExecutionOwner.store(in: h.context)
            do {
                let lease = try store.acquire(taskID: old.id, taskOwnerID: old.persistentModelID)
                try FileManager.default.removeItem(at: lease.recordURL)
            }
            var legacy = original; legacy.taskOwnerID = nil
            do { let lease = try store.acquire(taskID: old.id); try lease.save(legacy) }
            h.context.insert(TaskEvent(task: old, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
                payload: TaskEvent.payloadString(legacy)))
            try h.context.save()
        }
        let (task, request) = try next(h, after: old)
        let proposed = try RuntimeWorkspaceContinuation.preview(task: task, request: request, context: h.context)
        try RuntimeWorkspaceContinuation.authorize(proposed, task: task, request: request, context: h.context, rememberWorkspace: true)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
        let acquiredClaims = owner.record.resourceClaims
        owner.finish()
        let run = TaskRun(task: task); run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = .completed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished; record.inheritedToolUncertainty = true
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = acquiredClaims
        record.workspaceContinuationRequestID = request.id
        record.continuingUserRequestID = request.id
        try save(record, h)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running)
        _ = TaskTurnRequestStateMachine.transition(request, to: .completed)
        try h.context.save()
        return (old, task, request)
    }

    @Test("Check again lets a new Copilot message finish after a wall-clock timeout in a reserved workspace",
          arguments: [false, true])
    func recheckTimedOutCopilot(alreadyQueued: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let (holder, _, rootGrant) = try completedRememberedWorkspace(h)
        let holderReceipt = try RuntimeExecutionOwner.existing(task: holder, context: h.context)
        let task = h.makeTask(runtime: .copilotCLI, goal: "Preserve partial work", model: "gpt-5", tokenBudget: 200_000)
        task.workspace = holder.workspace
        let initial = try ExecutionRequestSubmissionService.submitInitial(for: task, into: h.context).get()
        let expired = try #require(try TaskTurnRequestRepository.request(id: initial.requestID, in: h.context))

        let marker = h.rootURL.appendingPathComponent("launches")
        let fake = try h.writeExecutable(named: "copilot", script: HeadlessChatScenarioTests.copilotScript(body: """
            if [ ! -f '\(marker.path)' ]; then
              echo first > '\(marker.path)'
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Partial output"}}'
              exec /bin/sleep 60
            fi
            echo next >> '\(marker.path)'
            printf '%s\\n' '{"type":"assistant.message","data":{"content":"The new instruction finished."}}' \
              '{"type":"result","exitCode":0}'
            """))
        let worker = h.makeWorker(runtime: .copilotCLI, executablePath: fake, permissionPolicy: .autonomous,
            sandboxEnforcementOverride: .off)
        worker.maxRunSeconds = 5
        let queue = TaskQueue(poolSize: 1, workerFactory: { worker }, sandboxEnforcementProvider: { .off })
        await queue.signalExecutionRequest(id: expired.id, task: task, modelContext: h.context).value
        let run = try #require(task.runs.first)
        try #require(run.typedStopReason == .providerRunWallClockExceeded && expired.state == .failed)
        let partial = run.output
        var receipt = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        let original = try #require(receipt.stopProof)
        let grant = try RuntimeExecutionOwner.store(in: h.context).workspaceContinuation(requestID: expired.id)
        #expect(grant?.inheritedAuthorizationID == rootGrant.id)
        // Reproduce the older capture made while the group was still draining.
        // The timeout, reaped process identity, settlement and request are real.
        receipt.stopProof = .init(executionID: original.executionID, process: original.process, reaped: original.reaped,
            processGroupEmpty: false, toolsStopped: false, remoteWorkExcluded: false, capturedAt: original.capturedAt)
        try save(receipt, h)
        let initialBlock = RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context)
        try #require(initialBlock != nil)
        func submitNewMessage() throws -> TaskTurnRequest {
            let result = try ExecutionRequestSubmissionService.submitFollowUp(message: "A new instruction", for: task, into: h.context).get()
            return try #require(try TaskTurnRequestRepository.request(id: result.requestID, in: h.context))
        }
        worker.maxRunSeconds = 60
        let queued = alreadyQueued ? try submitNewMessage() : nil
        if let queued {
            try #require(TaskTurnRequestStateMachine.transition(queued, to: .waitingForResource).changed)
            try h.context.save()
        }
        queue.recheckTimedOutRun(run.id, task: task, context: h.context)
        let checked = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        try #require(checked.stopProof?.groupObservedEmptyAt != nil)
        #expect(checked.stopProof?.processGroupEmpty == false && checked.stopProof?.remoteWorkExcluded == false)
        #expect(!checked.canReplace && checked.resourcesReleased == false && checked.limits == receipt.limits)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
        let eventCount = task.events.count
        queue.recheckTimedOutRun(run.id, task: task, context: h.context)
        #expect(task.events.count == eventCount)
        #expect(try TaskTurnRequestRepository.requests(for: task, in: h.context).count == (alreadyQueued ? 2 : 1))
        #expect(try RuntimeExecutionOwner.existing(task: holder, context: h.context) == holderReceipt)

        let request = try queued ?? submitNewMessage()
        if !alreadyQueued {
            _ = queue.signalExecutionRequest(id: request.id, task: task, modelContext: h.context)
        }
        let finished = await h.waitUntil(task: task, timeoutSeconds: 45) { _ in !request.state.isActive && !worker.isRunning }
        await queue.cancelAllAndWait()
        try #require(finished)
        #expect(request.state == .completed && task.runs.count == 2)
        #expect(expired.state == .failed && run.typedStopReason == .providerRunWallClockExceeded && run.output == partial)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "first\nnext\n")
        let successor = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(successor.ownerID == receipt.ownerID && successor.inheritedToolUncertainty == true)
        #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: successor).first == checked)
    }

    @Test("Remembered approval survives a store reopen and still serializes two successors")
    func rememberedScopeReopenAndCompetition() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (_, b, root) = try completedRememberedWorkspace(h)
        let (c, cr) = try next(h, after: b)
        let (d, dr) = try next(h, after: b)
        let cid = c.id; let crid = cr.id; let did = d.id; let drid = dr.id
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: Array(h.container.configurations))
        let context = reopened.mainContext
        let restored = try #require(try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == cid })).first)
        let request = try #require(try TaskTurnRequestRepository.request(id: crid, in: context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: restored, context: context, maxRunSeconds: 60, userRequest: request))
        defer { owner.finish() }
        #expect(try RuntimeExecutionOwner.store(in: context).workspaceContinuation(requestID: crid)?.inheritedAuthorizationID == root.id)
        let competing = try #require(try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == did })).first)
        let pending = try #require(try TaskTurnRequestRepository.request(id: drid, in: context))
        #expect(RuntimeExecutionOwner.acquire(task: competing, context: context, maxRunSeconds: 60, userRequest: pending) == nil)
    }

    @Test("Remembered approval never admits new uncertainty or expands its resource scope", arguments:
        ["changedOriginal", "unrelatedOwner", "failed", "cancelled", "settling", "running", "liveLease", "scheduled", "expandedScope", "missingGrant", "requestOnly"])
    func rememberedScopeFences(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (old, b, root) = try completedRememberedWorkspace(h)
        let (c, request) = try next(h, after: b)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var live: RuntimeExecutionOwnerStore.Lease?
        defer { withExtendedLifetime(live) {} }
        switch fault {
        case "changedOriginal":
            var changed = try #require(try RuntimeExecutionOwner.existing(task: old, context: h.context))
            changed.limits.tokensSpent += 1; try save(changed, h)
        case "unrelatedOwner": _ = try completed(h)
        case "failed": b.runs.first?.status = .failed
        case "cancelled":
            var changed = try #require(try RuntimeExecutionOwner.existing(task: b, context: h.context))
            changed.cancellationRequested = true; try save(changed, h)
        case "settling":
            var changed = try #require(try RuntimeExecutionOwner.existing(task: b, context: h.context))
            changed.settlementInProgress = true; try save(changed, h)
        case "running": b.runs.first?.status = .running
        case "liveLease": live = try store.acquire(taskID: b.id, taskOwnerID: b.persistentModelID)
        case "scheduled": request.kind = .scheduled
        case "expandedScope": break
        case "missingGrant": try FileManager.default.removeItem(at: store.root.appendingPathComponent(root.id.uuidString + ".handoff"))
        default:
            var grant = try #require(try store.workspaceContinuation(requestID: root.id)); grant.workspaceScope = nil
            let lease = try store.acquire(taskID: b.id, taskOwnerID: b.persistentModelID)
            try lease.saveWorkspaceContinuation(grant)
        }
        try h.context.save()
        var claims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: c, runMode: "initial", sandboxEnforcement: .off)
        if fault == "expandedScope" {
            claims.append(.init(taskID: c.id, resourceKey: h.rootURL.appendingPathComponent("different").path,
                accessMode: .write, runMode: "initial", requestID: request.id))
        }
        #expect(RuntimeExecutionOwner.acquire(task: c, context: h.context, maxRunSeconds: 60, userRequest: request, resourceClaims: claims) == nil)
        #expect(try store.workspaceContinuation(requestID: request.id) == nil)
    }

    @Test("A remembered workspace does not block independent resources that need no exception")
    func independentScopeNeedsNoAuthorization() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (_, b, _) = try completedRememberedWorkspace(h)
        let (c, request) = try next(h, after: b)
        let claims = [TaskResourceLockClaim(taskID: c.id, resourceKey: h.rootURL.appendingPathComponent("independent").path,
            accessMode: .write, runMode: "initial", requestID: request.id)]
        let owner = try #require(RuntimeExecutionOwner.acquire(task: c, context: h.context,
            maxRunSeconds: 60, userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.workspaceContinuationRequestID == nil)
        #expect(try RuntimeExecutionOwner.store(in: h.context).workspaceContinuation(requestID: request.id) == nil)
    }


    @Test("Returning to an acknowledged task requires a new human instruction and preserves preparation", arguments:
        ["valid", "legacy", "cleanCrash", "ownChanged", "cancelled", "retry", "consumed", "liveOther", "preflight", "savedGrant"])
    func returningTaskFences(mode: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (old, b, _) = try completedRememberedWorkspace(h, legacySource: mode == "legacy", cleanCrash: mode == "cleanCrash")
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "A new instruction", for: old, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let store = RuntimeExecutionOwner.store(in: h.context)
        var live: RuntimeExecutionOwnerStore.Lease?
        defer { withExtendedLifetime(live) {} }
        switch mode {
        case "ownChanged":
            var changed = try #require(try RuntimeExecutionOwner.existing(task: old, context: h.context))
            changed.limits.tokensSpent += 1; try save(changed, h)
        case "cancelled": _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled)
        case "retry": request.kind = .retry
        case "consumed": TaskHistoryRead.event(id: request.sourceEventID, in: old)?.run = old.runs.first
        case "liveOther": live = try store.acquire(taskID: b.id, taskOwnerID: b.persistentModelID)
        case "savedGrant":
            let previous = try #require(try RuntimeExecutionOwner.existing(task: old, context: h.context))
            let grant = try #require(try RuntimeWorkspaceContinuationScope.inherited(task: old, request: request,
                context: h.context, claims: nil, previous: previous))
            let lease = try store.acquire(taskID: old.id, taskOwnerID: old.persistentModelID)
            try lease.saveWorkspaceContinuation(grant)
        default: break
        }
        try h.context.save()
        if mode == "legacy" || mode == "cleanCrash" {
            let url: URL
            if mode == "legacy" { url = store.root.appendingPathComponent(old.id.uuidString + ".json") }
            else { url = try store.acquire(taskID: old.id, taskOwnerID: old.persistentModelID).recordURL }
            let bytes = try Data(contentsOf: url)
            let queue = TaskQueue(poolSize: 0); queue.refreshResourceOwnership(in: h.context)
            let claims = queue.resourceLockClaims(for: request, task: old, runMode: "follow_up", sandboxEnforcement: .off)
            #expect(queue.canAcquireResourceLocks(claims, task: old, context: h.context))
            #expect(try Data(contentsOf: url) == bytes)
        }
        let candidate = RuntimeExecutionOwner.acquire(task: old, context: h.context, maxRunSeconds: 60, userRequest: request)
        if ["ownChanged", "cancelled", "retry", "consumed", "liveOther"].contains(mode) {
            #expect(candidate == nil); return
        }
        guard let owner = candidate else { Issue.record("Returning task failed for \(mode)"); return }
        owner.chargePreparation(seconds: 3)
        let limits = owner.record.limits
        #expect(owner.record.workspaceContinuationRequestID == request.id)
        owner.finish()
        if mode == "preflight" {
            let again = RuntimeExecutionOwner.acquire(task: old, context: h.context, maxRunSeconds: 900, userRequest: request)
            guard let resumed = again else { Issue.record("Interrupted follow-up could not resume"); return }
            defer { resumed.finish() }
            #expect(resumed.record.limits == limits)
            #expect(resumed.record.workspaceContinuationRequestID == request.id)
        }
    }

}
