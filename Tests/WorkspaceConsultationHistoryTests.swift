import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace consultation historical attribution", .serialized)
@MainActor
struct WorkspaceConsultationHistoryTests {
    @Test("Ownership admission preserves pending run relationships and rejects ambiguous legacy owners",
          arguments: ["bound", "legacy", "bound_duplicate", "legacy_duplicate", "legacy_deleted_duplicate"])
    func ownershipAdmissionPreservesPendingRunGraph(scenario: String) throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        harness.context.autosaveEnabled = false
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain", model: "claude-sonnet-4-6")
        let request = try submitted(task, in: harness.context)
        if scenario.hasPrefix("legacy") { request.executionPolicySnapshotJSON = nil }
        if scenario.hasSuffix("duplicate") {
            let duplicate = AgentTask(title: "Imported copy", goal: "Owner ambiguity")
            duplicate.id = task.id
            harness.context.insert(duplicate)
            if scenario == "legacy_deleted_duplicate" {
                // Persist only fixture setup, before the pending run exists.
                try harness.context.save()
                harness.context.delete(duplicate)
            }
        }
        let run = TaskRun(task: task)
        harness.context.insert(run)
        #expect(try PersistedTurnRuntimeEventLinker.link(eventID: request.sourceEventID, to: run, for: task,
            fallbackType: "task.started", fallbackPayload: "", in: harness.context))
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        let accepted = scenario != "legacy_duplicate"
        let result = PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: run,
            task: task, in: harness.context)
        #expect(result.persisted == accepted)
        // Do not materialize task.runs before this boundary: that can hide an
        // incorrect refresh of the pending inverse during owner validation.
        #expect(run.task?.persistentModelID == task.persistentModelID)
        if !accepted {
            #expect(run.status == .failed)
            #expect(request.state == .admitted)
            #expect(associations(run, task: task).isEmpty)
            try harness.context.save()
        }
        let reloaded = ModelContext(harness.container)
        reloaded.autosaveEnabled = false
        let runID = run.id
        let savedRun = try #require(try reloaded.fetch(FetchDescriptor<TaskRun>(predicate: #Predicate { $0.id == runID })).first)
        #expect(savedRun.task?.persistentModelID == task.persistentModelID)
        let savedRequest = try TaskRunRequestAssociation.request(for: savedRun, in: reloaded)
        #expect(savedRequest?.id == (accepted ? request.id : nil))
        if accepted {
            #expect(savedRequest?.runID == savedRun.id)
            #expect(savedRequest?.sourceEventID == request.sourceEventID)
            let savedTask = try #require(savedRun.task)
            #expect(associations(savedRun, task: savedTask).count == 1)
        }
    }

    @Test("Retrying a failed or cancelled request retains each attempt's accepted workspace access",
          arguments: [false, true], ["failed", "cancelled", "legacy_failed", "legacy_cancelled"])
    func rerunRetainsConsultationAttribution(consultation: Bool, outcome: String) throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        harness.context.autosaveEnabled = false
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6")
        TaskWorkspaceConsultationPolicy.apply(consultation, to: task)
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: harness.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
        let originalClaims = request.resourceClaimsJSON
        let first = TaskRun(task: task)
        first.startedAt = Date().addingTimeInterval(-10)
        harness.context.insert(first)
        #expect(TaskTurnRequestStateMachine.transition(request, to: .admitted).rejection == nil)
        #expect(try PersistedTurnRuntimeEventLinker.link(eventID: request.sourceEventID, to: first, for: task,
            fallbackType: TaskEventTypes.Conversation.userMessage.rawValue, fallbackPayload: "Explain", in: harness.context))
        #expect(PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: first,
            task: task, in: harness.context).persisted)
        if outcome.hasPrefix("legacy_") {
            // An attempt saved by the previous version has only the mutable
            // source link. The next real reassociation must preserve it.
            for event in associations(first, task: task) { harness.context.delete(event) }
        }

        // A separate workspace writer creates this during the first attempt.
        let sibling = harness.workspaceURL.appendingPathComponent("sibling-result.md")
        try "Written by a concurrent task\n".write(to: sibling, atomically: true, encoding: .utf8)
        first.status = outcome.hasSuffix("failed") ? .failed : .cancelled
        first.completedAt = Date()
        #expect(TaskTurnRequestStateMachine.transition(request,
            to: outcome.hasSuffix("failed") ? .failed : .cancelled, runID: first.id).rejection == nil)
        try harness.context.save()
        #expect(TaskOutputWorkspaceDiscovery.filesChangedDuringRun(workspacePath: harness.workspaceURL.path,
            taskFolder: "", run: first).contains { $0.path == sibling.path } == !consultation)

        // Retry uses the same durable request but gives it a new run, through
        // the same state/linker boundaries used by AgentRuntimeWorker.
        #expect(TaskTurnRequestStateMachine.transition(request, to: .waitingForWorker).rejection == nil)
        #expect(request.runID == nil)
        TaskWorkspaceConsultationPolicy.apply(!consultation, to: task)
        let second = TaskRun(task: task)
        harness.context.insert(second)
        #expect(TaskTurnRequestStateMachine.transition(request, to: .admitted).rejection == nil)
        for _ in 0..<2 {
            #expect(try PersistedTurnRuntimeEventLinker.link(eventID: request.sourceEventID, to: second, for: task,
                fallbackType: TaskEventTypes.Conversation.userMessage.rawValue, fallbackPayload: "Explain", in: harness.context))
            #expect(PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: second,
                task: task, in: harness.context).persisted)
        }
        #expect(request.runID == second.id)
        #expect(TaskHistoryRead.event(id: request.sourceEventID, in: task)?.run?.id == second.id)
        #expect(request.resourceClaimsJSON == originalClaims)
        #expect(associations(first, task: task).count == 1)
        #expect(associations(second, task: task).count == 1)
        #expect(TaskOutputWorkspaceDiscovery.filesChangedDuringRun(workspacePath: harness.workspaceURL.path,
            taskFolder: "", run: first).contains { $0.path == sibling.path } == !consultation)

        let reloaded = ModelContext(harness.container)
        reloaded.autosaveEnabled = false
        let firstID = first.id
        let savedRun = try #require(try reloaded.fetch(FetchDescriptor<TaskRun>(predicate: #Predicate { $0.id == firstID })).first)
        let savedRequest = try #require(try TaskRunRequestAssociation.request(for: savedRun, in: reloaded))
        let savedTask = try #require(savedRun.task)
        #expect(savedRequest.runID == second.id)
        #expect(savedRequest.resourceClaimsJSON == originalClaims)
        #expect(TaskHistoryRead.event(id: request.sourceEventID, in: savedTask)?.run?.id == second.id)
        #expect(TaskOutputWorkspaceDiscovery.filesChangedDuringRun(workspacePath: harness.workspaceURL.path,
            taskFolder: "", run: savedRun).contains { $0.path == sibling.path } == !consultation)
    }

    @Test("Invalid historical references cannot authorize workspace inference but retain task outputs",
          arguments: ["missing_request", "malformed", "version", "foreign_request", "foreign_event", "missing_source",
                      "wrong_source", "wrong_run", "conflict", "corrupt_claims"])
    func invalidHistoricalAssociationIsConservative(fault: String) throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Work", model: "claude-sonnet-4-6")
        let request = try submitted(task, in: harness.context)
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-10)
        harness.context.insert(run)
        #expect(TaskTurnRequestStateMachine.transition(request, to: .admitted).rejection == nil)
        #expect(PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: run,
            task: task, in: harness.context).persisted)
        let sibling = harness.workspaceURL.appendingPathComponent("sibling.md")
        try "Workspace result".write(to: sibling, atomically: true, encoding: .utf8)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(URL(fileURLWithPath: folder).standardizedFileURL != harness.workspaceURL.standardizedFileURL)
        let output = URL(fileURLWithPath: folder).appendingPathComponent("answer.md")
        try "Owned task output".write(to: output, atomically: true, encoding: .utf8)
        #expect(TaskOutputDiscovery.files(for: task, run: run).contains { $0.path == sibling.path })
        let event = try #require(associations(run, task: task).first)
        switch fault {
        case "missing_request": harness.context.delete(request)
        case "malformed": event.payload = "{"
        case "version": event.payload = event.payload.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        case "missing_source": harness.context.delete(try #require(TaskHistoryRead.event(id: request.sourceEventID, in: task)))
        case "corrupt_claims": request.resourceClaimsJSON = "{"
        case "foreign_request", "foreign_event":
            let foreign = harness.makeTask(runtime: .claudeCode, goal: "Other task", model: "claude-sonnet-4-6")
            let foreignRequest = try submitted(foreign, in: harness.context)
            if fault == "foreign_event" { event.task = foreign }
            else {
                event.payload = TaskEvent.payloadString(TaskRunRequestAssociationPayload(taskID: task.id, runID: run.id,
                    requestID: foreignRequest.id, sourceEventID: foreignRequest.sourceEventID))
            }
        case "wrong_source", "wrong_run":
            event.payload = TaskEvent.payloadString(TaskRunRequestAssociationPayload(taskID: task.id,
                runID: fault == "wrong_run" ? UUID() : run.id, requestID: request.id,
                sourceEventID: fault == "wrong_source" ? UUID() : request.sourceEventID))
        default:
            let extra = TaskEvent.structuredPayloadEvent(task: task, eventType: TaskEventTypes.ExecutionRequest.runAssociated,
                payload: TaskRunRequestAssociationPayload(taskID: task.id, runID: run.id,
                    requestID: UUID(), sourceEventID: request.sourceEventID), run: run)
            harness.context.insert(extra)
        }
        try harness.context.save()
        let files = TaskOutputDiscovery.files(for: task, run: run)
        #expect(!files.contains { $0.path == sibling.path })
        #expect(files.contains { $0.path == output.path })
    }

    @Test("Failed running-state persistence keeps the previous attempt identifiable")
    func failedSavePreservesPreviousAssociation() throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        harness.context.autosaveEnabled = false
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain", model: "claude-sonnet-4-6")
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let request = try submitted(task, in: harness.context)
        let first = TaskRun(task: task)
        first.startedAt = Date().addingTimeInterval(-10)
        harness.context.insert(first)
        // Reconstruct the old release's already-completed attempt without the
        // new event; its source is the only remaining historical association.
        let source = try #require(TaskHistoryRead.event(id: request.sourceEventID, in: task))
        source.run = first
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: first.id)
        _ = TaskTurnRequestStateMachine.transition(request, to: .failed, runID: first.id)
        _ = TaskTurnRequestStateMachine.transition(request, to: .waitingForWorker)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        first.status = .failed
        first.completedAt = Date()
        try harness.context.save()
        let sibling = harness.workspaceURL.appendingPathComponent("sibling.md")
        try "Another writer".write(to: sibling, atomically: true, encoding: .utf8)
        let second = TaskRun(task: task)
        harness.context.insert(second)
        #expect(try PersistedTurnRuntimeEventLinker.link(eventID: source.id, to: second, for: task,
            fallbackType: "task.started", fallbackPayload: "", in: harness.context))
        let begin = PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: second, task: task,
            in: harness.context, persist: { false })
        #expect(!begin.persisted)
        #expect(second.status == .failed)
        #expect(try TaskRunRequestAssociation.request(for: first, in: harness.context)?.id == request.id)
        #expect(!TaskOutputDiscovery.files(for: task, run: first).contains { $0.path == sibling.path })

        let reloaded = ModelContext(harness.container)
        reloaded.autosaveEnabled = false
        let firstID = first.id
        let savedRun = try #require(try reloaded.fetch(FetchDescriptor<TaskRun>(predicate: #Predicate { $0.id == firstID })).first)
        let savedTask = try #require(savedRun.task)
        #expect(TaskHistoryRead.event(id: source.id, in: savedTask)?.run?.id == first.id)
        #expect(!TaskOutputDiscovery.files(for: savedTask, run: savedRun).contains { $0.path == sibling.path })
    }

    @Test("A conflicting historical binding stops reassociation, while a legacy fallback remains valid")
    func conflictStopsLinkWithoutBreakingLegacy() throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Work", model: "claude-sonnet-4-6")
        let request = try submitted(task, in: harness.context)
        let first = TaskRun(task: task)
        harness.context.insert(first)
        let source = try #require(TaskHistoryRead.event(id: request.sourceEventID, in: task))
        source.run = first
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        #expect(PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: first,
            task: task, in: harness.context).persisted)
        let reference = try #require(associations(first, task: task).first)
        reference.payload = "{"
        let second = TaskRun(task: task)
        harness.context.insert(second)
        #expect(throws: TaskRunRequestAssociation.Failure.self) {
            try PersistedTurnRuntimeEventLinker.link(eventID: source.id, to: second, for: task,
                fallbackType: "task.started", fallbackPayload: "", in: harness.context)
        }
        #expect(source.run?.id == first.id)
        #expect(associations(second, task: task).isEmpty)
        // false still means a legitimate legacy fallback, not failed linkage.
        #expect(try !PersistedTurnRuntimeEventLinker.link(eventID: nil, to: second, for: task,
            fallbackType: "task.started", fallbackPayload: "Legacy", in: harness.context))
        #expect(PersistedTurnRuntimeEventLinker.beginRuntime(requestID: nil, run: second,
            task: task, in: harness.context).persisted)
        #expect(try TaskRunRequestAssociation.request(for: second, in: harness.context) == nil)
        let sibling = harness.workspaceURL.appendingPathComponent("legacy-result.md")
        try "Legacy Work result".write(to: sibling, atomically: true, encoding: .utf8)
        #expect(TaskOutputDiscovery.files(for: task, run: second).contains { $0.path == sibling.path })
    }

    @Test("A worker aborts before its provider when a prior association cannot be preserved")
    func workerStopsBeforeProviderOnUnverifiableHistory() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Explain", model: "claude-sonnet-4-6", tokenBudget: 0)
        let request = try submitted(task, in: harness.context)
        let first = TaskRun(task: task)
        harness.context.insert(first)
        let source = try #require(TaskHistoryRead.event(id: request.sourceEventID, in: task))
        source.run = first
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        #expect(PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: first,
            task: task, in: harness.context).persisted)
        let reference = try #require(associations(first, task: task).first)
        reference.payload = "{"
        _ = TaskTurnRequestStateMachine.transition(request, to: .failed, runID: first.id)
        _ = TaskTurnRequestStateMachine.transition(request, to: .waitingForWorker)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        first.status = .failed
        first.completedAt = Date()
        try harness.context.save()
        try RuntimeRecoveryTestReceipt.install(task: task, run: first, context: harness.context)
        let fake = FakeAgentProcessRunner()
        let worker = AgentRuntimeWorker(processRunner: fake, providerSettingsSnapshotProvider: { .headlessScenario })
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.setExecutablePath("/bin/sh", for: .claudeCode)
        worker.setHomeDirectory(harness.rootURL.appendingPathComponent("provider-home").path, for: .claudeCode)
        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: harness.context)
        await worker.execute(task: task, modelContext: harness.context,
            existingStartEventID: request.sourceEventID, executionRequestID: request.id) { _ in }
        #expect(fake.receivedPrompts.isEmpty)
        #expect(task.runs.count == 2)
        let rejected = try #require(task.runs.first { $0.id != first.id })
        #expect(rejected.status == .failed)
        #expect(rejected.stopReason == "turn_running_persist_failed")
        #expect(request.state == .failed)
        #expect(source.run?.id == first.id)
    }

    private func associations(_ run: TaskRun, task: AgentTask) -> [TaskEvent] {
        TaskHistoryRead.events(for: task, runID: run.id).filter { $0.hasType(TaskEventTypes.ExecutionRequest.runAssociated) }
    }

    private func submitted(_ task: AgentTask, in context: ModelContext) throws -> TaskTurnRequest {
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        return try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
    }
}
