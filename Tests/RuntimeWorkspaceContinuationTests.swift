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
    private func completed(_ h: HeadlessChatHarness) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .claudeCode, goal: "Keep previous work", model: "test")
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.setOutput("Preserved answer")
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); task.status = .completed
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.state = .finished; record.inheritedToolUncertainty = true
        record.settlementInProgress = false; record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        try save(record, h); try h.context.save()
        return (task, record)
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

    @Test("Known nonterminal SSH jobs block continuation even in retained lineage", arguments: [false, true])
    func knownRemoteJobs(retained: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (a, old) = try completed(h)
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
        var job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: a.id.uuidString,
            runID: old.runID?.uuidString, connection: .init(id: "fixture", name: "Fixture", target: "fixture", arguments: ["fixture"]),
            command: "true", createdAt: Date())
        job.status = .running
        try RemoteWorkspaceJobStore(rootPath: config.recordRootPath).create(job)
        #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.authorize(proposal, task: b, request: request, context: h.context) }
        #expect(throws: (any Error).self) { try RuntimeWorkspaceContinuation.preview(task: b, request: request, context: h.context) }
        #expect(try store.workspaceContinuation(requestID: request.id) == nil)
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
        try FileManager.default.copyItem(at: fixture, to: frames)
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
        for index in [1, 2, 1, 0] {
            let task = sequence[index]
            let before = task.runs.count
            let message = "Return to task \(index)"
            let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: message, for: task, into: h.context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
            let leaseID = UUID()
            let claims = queue.resourceLockClaims(for: request, task: task, runMode: "continue", sandboxEnforcement: .off).map { $0.leased(leaseID) }
            let lease = try #require(queue.acquireResourceLocksIfAvailable(claims, task: task, modelContext: h.context))
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: h.context)
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
