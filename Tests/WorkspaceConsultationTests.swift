import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace consultations", .serialized)
@MainActor
struct WorkspaceConsultationTests {
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
