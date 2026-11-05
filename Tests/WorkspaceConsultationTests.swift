import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace consultations", .serialized)
@MainActor
struct WorkspaceConsultationTests {
    @Test("Saving an existing draft does not reapply a window-local consultation selection")
    func existingDraftDoesNotOverwriteDurableMode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Astra/Views/ChatPanelView.swift"), encoding: .utf8)
        let save = try #require(source.range(of: "func saveDraft()"))
        let existing = try #require(source[save.upperBound...].range(of: "if let draft = composerDraft {"))
        let newDraft = try #require(source[existing.upperBound...].range(of: "} else {"))
        #expect(!source[existing.upperBound..<newDraft.lowerBound].contains("TaskWorkspaceConsultationPolicy.apply("))
        #expect(source.contains("TaskWorkspaceConsultationPolicy.composerSelection(for: composerDraft, newTaskSelection: newTaskConsultationMode)"))
        #expect(!source.contains("TaskWorkspaceConsultationPolicy.apply(newTaskConsultationMode"))
    }

    @Test("Consult hides and blocks stale Goal actions before planning or approval")
    func consultationGatesStaleGoalActions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Astra/Views/ChatPanelView.swift"), encoding: .utf8)
        #expect(source.contains("!isConsultationMode && (isPlanMode || pendingPlan != nil || approvedDraftPlan != nil)"))
        #expect(source.contains("get: { !isConsultationMode && isPlanMode }"))
        #expect(source.contains("let shouldUseGoalMode = !isConsultationMode && isPlanMode"))
        for action in ["generatePlanFromConversation()", "approvePendingPlan()", "runApprovedPlan(_ plan:"] {
            let start = try #require(source.range(of: "private func " + action))
            let next = try #require(source[start.upperBound...].range(of: "private func "))
            #expect(source[start.upperBound..<next.lowerBound].contains("guard !isConsultationMode"))
        }
        let preparation = try String(contentsOf: root.appendingPathComponent("Astra/Views/ChatPanelViewWorktreeCreation.swift"), encoding: .utf8)
        #expect(preparation.contains("modeSource: draft"))
    }

    @Test("Two composer selections follow the saved draft and freeze its mode on submission", arguments: [false, true])
    func crossWindowSelectionUsesDurableDraft(consultation: Bool) throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let draft = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6")
        draft.status = .draft
        draft.constraints = ["Preserve user guidance"]
        draft.inputs = ["Previous task context"]
        // Each window retains its old new-task selection. The shared draft,
        // changed by the other window, is the authoritative selection now.
        let firstWindowLocal = !consultation
        let secondWindowLocal = consultation
        TaskWorkspaceConsultationPolicy.select(consultation, for: draft, in: harness.context)
        let savedConstraints = draft.constraints
        let selectionEvents = draft.events.filter { $0.eventType == TaskEventTypes.ResourceLock.consultationSelected }
        #expect(selectionEvents.count == 1)
        let first = TaskWorkspaceConsultationPolicy.composerSelection(for: draft, newTaskSelection: firstWindowLocal)
        let second = TaskWorkspaceConsultationPolicy.composerSelection(for: draft, newTaskSelection: secondWindowLocal)
        #expect(first == consultation && second == consultation)

        // An unrelated draft edit/save must not replay either window's cache.
        // existingDraftDoesNotOverwriteDurableMode pins the actual UI save path.
        draft.draftMessages = "Updated conversation from the first window"
        try harness.context.save()
        #expect(draft.constraints == savedConstraints)
        #expect(draft.inputs == ["Previous task context"])
        #expect(draft.events.filter { $0.eventType == TaskEventTypes.ResourceLock.consultationSelected }.count == 1)

        // Quick/spec creation copies the resolved selection into the new task.
        let created = harness.makeTask(runtime: .claudeCode, goal: "Run the selected mode", model: "claude-sonnet-4-6")
        TaskWorkspaceConsultationPolicy.apply(first, to: created)
        guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(for: created, into: harness.context) else {
            Issue.record("Could not submit the cross-window selection"); return
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
        #expect(TaskWorkspaceConsultationPolicy.isRequired(by: request, task: created) == consultation)
        TaskWorkspaceConsultationPolicy.select(!consultation, for: draft, in: harness.context)
        #expect(TaskWorkspaceConsultationPolicy.composerSelection(for: draft, newTaskSelection: firstWindowLocal) == !consultation)
        #expect(TaskWorkspaceConsultationPolicy.composerSelection(for: draft, newTaskSelection: secondWindowLocal) == !consultation)
        #expect(TaskWorkspaceConsultationPolicy.isRequired(by: request, task: created) == consultation)
        #expect(TaskWorkspaceConsultationPolicy.composerSelection(for: nil, newTaskSelection: firstWindowLocal) == firstWindowLocal)
    }

    @Test("Consultation runs alongside a writer but still launches read-only")
    func consultationAdmissionAndLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-consult-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Synthetic", primaryPath: root.path)
        let writer = AgentTask(title: "Work", goal: "Update files", workspace: workspace)
        let reader = AgentTask(title: "Question", goal: "What does this workspace do?", workspace: workspace)
        TaskWorkspaceConsultationPolicy.apply(true, to: reader)
        // Older ASTRA builds understand this declaration and keep future
        // turns read-only even though they do not offer live consultation.
        #expect(reader.constraints.contains("ASTRA_RESOURCE_ACCESS=read_only"))
        #expect(reader.constraints.contains(TaskWorkspaceConsultationPolicy.declaration))
        let request = TaskTurnRequest(task: reader, messageEventID: UUID(), sequence: 1,
            resourceClaims: TaskExecutionResourceClaimResolver.claims(for: reader))
        let lease = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: reader, runMode: "test")
        let held = TaskExecutionResourceBroker.lockClaims(for: TaskExecutionResourceClaimResolver.claims(for: writer),
            taskID: writer.id, requestID: UUID(), runMode: "test")
        #expect(lease.first?.isLiveWorkspaceReader == true)
        #expect(TaskExecutionResourceBroker.canAcquire(lease, active: held))
        #expect(TaskExecutionResourceBroker.canAcquire(held, active: lease))
        let access = try #require(TaskExecutionResourceAdmissionPolicy.workspaceAccess(from: lease))
        #expect(access == .shared)
        let plan = TaskLaunchResourceResolver.resolve(task: reader, runID: UUID(), runtime: .copilotCLI,
            phase: "run", prompt: reader.goal, contextText: "", workspacePath: root.path,
            workspaceAccess: access, requiresWorkspaceConsultation: true,
            gitCredentialContextProvider: { _, _, _, _ in .empty })
        #expect(plan.requiresSharedWorkspaceBoundary)
        #expect(!plan.diagnostics.contains { $0.code == "consultation_requires_read_only_workspace" })
        #expect(!plan.hostWritablePaths.contains(root.standardizedFileURL.path))
        #expect(plan.hostReadablePaths.contains(root.standardizedFileURL.path))
    }

    @Test("Waiting writers do not head-of-line block a live consultation")
    func fifoAllowsConsultation() {
        let workspace = Workspace(name: "Synthetic", primaryPath: "/tmp/astra-consult-fifo")
        let writer = AgentTask(title: "Earlier writer", goal: "Update files", workspace: workspace)
        let reader = AgentTask(title: "Question", goal: "Explain files", workspace: workspace)
        TaskWorkspaceConsultationPolicy.apply(true, to: reader)
        let a = TaskTurnRequest(task: writer, messageEventID: UUID(), sequence: 1,
            resourceClaims: TaskExecutionResourceClaimResolver.claims(for: writer))
        let b = TaskTurnRequest(task: reader, messageEventID: UUID(), sequence: 1,
            resourceClaims: TaskExecutionResourceClaimResolver.claims(for: reader))
        let candidate = ExecutionRequestAdmissionScheduler.Candidate(request: b, task: reader)
        let projection = ExecutionRequestAdmissionScheduler.Projection(activeRequests: [a, b],
            ordered: [.init(request: a, task: writer), candidate], missingTaskRequests: [])
        #expect(TaskExecutionResourceAdmissionPolicy.canAdmit(candidate, in: projection,
            dispatchedRequestIDs: [], activeTaskIDs: [], activeClaims: []))
    }

    @Test("Sandbox Off and intrinsic workflow writes keep exclusive admission")
    func unenforcedAndIntrinsicWritesRemainExclusive() throws {
        let workspace = Workspace(name: "Synthetic", primaryPath: "/tmp/astra-consult-boundary")
        let task = AgentTask(title: "Question", goal: "Explain files", workspace: workspace)
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
            resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
        let unconfined = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "test", sandboxEnforcement: .off)
        #expect(unconfined.first?.accessMode == .write)
        #expect(unconfined.first?.isLiveWorkspaceReader == false)
        let plan = TaskLaunchResourceResolver.resolve(task: task, runID: UUID(), runtime: .copilotCLI,
            phase: "run", prompt: task.goal, contextText: "", workspacePath: workspace.primaryPath,
            workspaceAccess: .exclusive, requiresWorkspaceConsultation: true,
            gitCredentialContextProvider: { _, _, _, _ in .empty })
        #expect(plan.diagnostics.contains { $0.code == "consultation_requires_read_only_workspace" && $0.severity == .error })
        task.validationStrategy = .runTests
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.access == .exclusive)
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.readConsistency == .live)
        task.validationStrategy = .manual
        task.isolationStrategy = .gitBranch
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.access == .exclusive)
        task.isolationStrategy = .sameDirectory
        task.templateHooksJSON = "{\"hook\":true}"
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).first?.access == .exclusive)
    }

    @Test("A persisted consultation keeps its accepted access when the task changes")
    func immutableRequestAndLegacyCompatibility() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workspace = Workspace(name: "Synthetic", primaryPath: "/tmp/astra-consult-persist")
        let task = AgentTask(title: "Question", goal: "Explain files", workspace: workspace)
        context.insert(task)
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(for: task, into: context) else {
            Issue.record("Could not submit the consultation"); return
        }
        TaskWorkspaceConsultationPolicy.apply(false, to: task)
        let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>())
        let request = try #require(requests.first { $0.id == submission.requestID })
        #expect(request.resourceClaims.first?.readConsistency == .live)
        #expect(TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "test").first?.isLiveWorkspaceReader == true)
        let decoded = try JSONDecoder().decode([TaskExecutionResourceClaim].self,
            from: Data("[{\"kind\":\"workspace\",\"key\":\"/tmp/astra-legacy\",\"access\":\"shared\"}]".utf8))
        #expect(decoded.first?.readConsistency == nil)
        let legacy = TaskExecutionResourceBroker.lockClaims(for: decoded, taskID: UUID(), requestID: nil, runMode: "test")
        var writer = try #require(legacy.first)
        writer.taskID = UUID()
        writer.accessMode = .write
        #expect(TaskExecutionResourceBroker.conflicts(try #require(legacy.first), writer))
        let oldLease = Data("{\"taskID\":\"\(UUID())\",\"resourceKey\":\"/tmp/astra-legacy\",\"accessMode\":\"read_only\",\"runMode\":\"test\",\"resourceKind\":\"workspace\"}".utf8)
        #expect(try JSONDecoder().decode(TaskResourceLockClaim.self, from: oldLease).isLiveWorkspaceReader == false)
    }

    @Test("Live flags never weaken other resources, writers, or combined stable claims")
    func observationIsWorkspaceOnly() throws {
        for kind in TaskExecutionResourceKind.allCases {
            let claims = TaskExecutionResourceBroker.lockClaims(for: [
                .init(kind: kind, key: "/tmp/astra-consult-kinds", access: .shared, readConsistency: .live)
            ], taskID: UUID(), requestID: nil, runMode: "test")
            let reader = try #require(claims.first)
            var writer = reader
            writer.accessMode = .write
            #expect(TaskExecutionResourceBroker.conflicts(reader, writer) == (kind != .workspace))
            #expect(TaskExecutionResourceBroker.conflicts(writer, writer))
        }
        let merged = TaskExecutionResourceBroker.lockClaims(for: [
            .init(kind: .workspace, key: "/tmp/astra-consult-merge", access: .shared, readConsistency: .live),
            .init(kind: .workspace, key: "/tmp/astra-consult-merge", access: .shared)
        ], taskID: UUID(), requestID: nil, runMode: "test")
        let stable = try #require(merged.first)
        #expect(!stable.isLiveWorkspaceReader)
        var observer = stable
        observer.readConsistency = .live
        #expect(!observer.coversAccess(of: stable))
        #expect(stable.coversAccess(of: observer))
    }

    @Test("Consult selection preserves user data and cannot change accepted active work")
    func selectionPersistence() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let task = AgentTask(title: "Question", goal: "Explain files")
        task.inputs = ["/tmp/input.md", "ASTRA_RESOURCE_ACCESS=write"]
        task.constraints = ["Keep the answer brief", "astra-resource-access: read-only"]
        context.insert(task)
        TaskWorkspaceConsultationPolicy.select(true, for: task, in: context)
        #expect(TaskWorkspaceConsultationPolicy.isEnabled(for: task))
        #expect(task.inputs == ["/tmp/input.md"])
        #expect(task.constraints.contains("Keep the answer brief"))
        #expect(task.events.contains { $0.eventType == TaskEventTypes.ResourceLock.consultationSelected })
        task.status = .running
        TaskWorkspaceConsultationPolicy.select(false, for: task, in: context)
        #expect(TaskWorkspaceConsultationPolicy.isEnabled(for: task))
        task.status = .completed
        TaskWorkspaceConsultationPolicy.select(false, for: task, in: context)
        #expect(!TaskWorkspaceConsultationPolicy.isEnabled(for: task))
        #expect(TaskExecutionResourceClaimResolver.workspaceAccess(for: task) == .exclusive)
    }

    @Test("A failed mode save restores constraints, inputs, and the original timestamp")
    func failedSelectionDoesNotChangeAuthority() throws {
        enum Failure: Error { case save }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let task = AgentTask(title: "Question", goal: "Explain files")
        task.inputs = ["ASTRA_RESOURCE_ACCESS=write"]
        let date = task.updatedAt
        context.insert(task)
        try context.save()
        TaskWorkspaceConsultationPolicy.select(true, for: task, in: context, persist: { throw Failure.save })
        #expect(!TaskWorkspaceConsultationPolicy.isEnabled(for: task))
        #expect(task.inputs == ["ASTRA_RESOURCE_ACCESS=write"])
        #expect(task.updatedAt == date)
        #expect(TaskExecutionResourceClaimResolver.workspaceAccess(for: task) == .exclusive)
    }

    @Test("Protected receipts and continuation retain live-read consistency")
    func protectedOwnerPreservesConsultation() throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        let workspace = Workspace(name: "Synthetic consultation", primaryPath: harness.workspaceURL.path)
        harness.context.insert(workspace)
        let task = AgentTask(title: "Question", goal: "Explain files", workspace: workspace)
        harness.context.insert(task)
        try harness.context.save()
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        let claims = TaskExecutionResourceBroker.lockClaims(for: TaskExecutionResourceClaimResolver.claims(for: task),
            taskID: task.id, requestID: UUID(), runMode: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: harness.context,
            maxRunSeconds: 60, resourceClaims: claims))
        defer { owner.finish() }
        let receiptURL = try #require(owner.receiptURL)
        let savedReceipt = try RuntimeExecutionOwnerStore.read(receiptURL)
        let receipt = try #require(savedReceipt)
        #expect(receipt.resourceClaims?.first?.isLiveWorkspaceReader == true)
        let inherited = RuntimeCompletedUserTurnContinuation.retainingClaims(receipt,
            additional: claims, requestID: UUID())
        #expect(inherited.first?.isLiveWorkspaceReader == true)
        var writer = try #require(inherited.first)
        writer.taskID = UUID()
        writer.accessMode = .write
        #expect(TaskExecutionResourceBroker.canAcquire(inherited, active: [writer]))
    }
}
