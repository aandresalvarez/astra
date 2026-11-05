import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace consultation submission boundaries", .serialized)
@MainActor
struct WorkspaceConsultationSubmissionTests {
    @Test("Template execution requires the current composer's explicit Work selection",
          arguments: ["draft_main", "draft_before", "new_main", "new_before"], [false, true])
    func templateRequiresExplicitWork(origin: String, consultation: Bool) throws {
        let beforePhase = origin.hasSuffix("before")
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let composer = harness.makeTask(runtime: .claudeCode, goal: "/template review", model: "claude-sonnet-4-6")
        let workspace = try #require(composer.workspace)
        composer.status = .draft
        // Keep typed persistence but exclude unrelated asynchronous mirror writes.
        TaskWorkspaceConsultationPolicy.select(consultation, for: composer, in: harness.context, persist: { try harness.context.save() })
        // Checkout inheritance is independent from the new composer's intent.
        // An explicit Work composer may reuse a Consult task's existing pin.
        let checkout = AgentTask(title: "Checkout", goal: "Existing checkout", workspace: workspace)
        harness.context.insert(checkout)
        checkout.status = .draft
        checkout.executionRootPath = harness.workspaceURL.path
        TaskWorkspaceConsultationPolicy.apply(true, to: checkout)
        let template = TaskTemplate(name: "Review", mainGoal: "Review files", workspace: workspace)
        if beforePhase { template.beforeGoal = "Prepare the review" }
        template.hooksJSON = #"{"PreToolUse":[{"matcher":"Read","hooks":[]}]}"#
        harness.context.insert(template)
        try harness.context.save()
        let taskCount = try harness.context.fetchCount(FetchDescriptor<AgentTask>())
        let requestCount = try harness.context.fetchCount(FetchDescriptor<TaskTurnRequest>())
        let selected = TaskWorkspaceConsultationPolicy.composerSelection(
            for: origin.hasPrefix("draft") ? composer : nil,
            newTaskSelection: origin.hasPrefix("draft") ? !consultation : consultation)
        #expect(selected == consultation)
        var submissions = 0
        var creation: WorkspaceCommandService.TemplateTaskCreation?
        var failure: Error?
        let filesBefore = try FileManager.default.subpathsOfDirectory(atPath: harness.workspaceURL.path).sorted()
        do {
            creation = try WorkspaceCommandService.createTemplateTasks(template: template, taskTitle: "Review", variables: [:],
                selectedSkills: [], defaultModel: "claude-sonnet-4-6", defaultRuntimeID: "claude_code",
                workspace: workspace, modelContext: harness.context, source: "test", consultation: selected,
                checkoutSource: checkout,
                submitInitial: { task, context in
                    submissions += 1
                    return ExecutionRequestSubmissionService.submitInitial(for: task, into: context)
                })
        } catch { failure = error }
        if consultation {
            #expect(failure is WorkspaceCommandService.TemplateExecutionError)
            #expect(failure?.localizedDescription.contains("Choose Work") == true)
            #expect(creation == nil)
            #expect(submissions == 0)
            #expect(try harness.context.fetchCount(FetchDescriptor<AgentTask>()) == taskCount)
            #expect(try harness.context.fetchCount(FetchDescriptor<TaskTurnRequest>()) == requestCount)
            #expect(try FileManager.default.subpathsOfDirectory(atPath: harness.workspaceURL.path).sorted() == filesBefore)
        } else {
            #expect(failure == nil)
            let created = try #require(creation)
            #expect(created.initialRequestSubmitted && submissions == 1)
            let runnable = created.beforeTask ?? created.mainTask
            let request = try #require(try TaskTurnRequestRepository.requests(for: runnable, in: harness.context).first)
            #expect(request.resourceClaims.contains { $0.kind == .workspace && $0.access == .exclusive })
            #expect(request.resourceClaims.allSatisfy { $0.readConsistency == nil })
            #expect(runnable.executionRootPath == checkout.executionRootPath)
            #expect((created.beforeTask != nil) == beforePhase)
        }
    }

    @Test("Quick and spec creation re-read durable mode after queuing and asynchronous preparation",
          arguments: ["quick_queued", "spec_queued", "quick_preparing", "spec_preparing"], [false, true])
    func queuedCreationUsesCurrentComposerMode(route: String, initialConsultation: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let composer = harness.makeTask(runtime: .claudeCode, goal: "Explain the workspace", model: "claude-sonnet-4-6")
        let workspace = try #require(composer.workspace)
        composer.status = .draft
        TaskWorkspaceConsultationPolicy.select(initialConsultation, for: composer, in: harness.context, persist: { try harness.context.save() })
        let created = AgentTask(title: "New task", goal: "Explain the workspace", workspace: workspace,
            model: "claude-sonnet-4-6", runtime: .claudeCode)
        if route.hasPrefix("spec") { created.constraints = ["Preserve user guidance"] }
        let changeDuringPreparation = route.hasSuffix("preparing")
        TaskWorkspaceConsultationPolicy.apply(
            TaskWorkspaceConsultationPolicy.composerSelection(for: composer, newTaskSelection: false), to: created)
        let creation = NewTaskCreationRun()
        defer { creation.detach() }
        var finished = false
        var failure: Error?
        var requestID: UUID?
        // Both UI routes use this production boundary. No provider or accepted
        // request exists when the other window changes the saved draft.
        creation.start({
            defer { finished = true }
            try await NewTaskWorktreeComposerFlow.prepareAndSubmit(created, consultationSelection: {
                TaskWorkspaceConsultationPolicy.composerSelection(for: composer, newTaskSelection: initialConsultation)
            }) {
                #expect(TaskWorkspaceConsultationPolicy.isEnabled(for: created)
                    == (changeDuringPreparation ? initialConsultation : !initialConsultation))
                try await TaskWorktreeService.prepare(task: created, request: nil, inheritingFrom: composer,
                    modeSource: composer, modelContext: harness.context, resourceQueue: nil)
                if changeDuringPreparation {
                    TaskWorkspaceConsultationPolicy.select(!initialConsultation, for: composer, in: harness.context, persist: { try harness.context.save() })
                    await Task.yield()
                }
            } submit: {
                TaskStateMachine.enqueueFromChatSubmission(created, modelContext: harness.context)
                harness.context.insert(created)
                guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(
                    for: created, into: harness.context) else { Issue.record("Synthetic submission failed"); return }
                requestID = submission.requestID
            }
        }, onError: { failure = $0; finished = true })
        #expect(!finished && requestID == nil)
        if !changeDuringPreparation {
            TaskWorkspaceConsultationPolicy.select(!initialConsultation, for: composer, in: harness.context, persist: { try harness.context.save() })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(finished && failure == nil)
        let id = try #require(requestID)
        let request = try #require(try TaskTurnRequestRepository.request(id: id, in: harness.context))
        #expect(TaskWorkspaceConsultationPolicy.isRequired(by: request, task: created) == !initialConsultation)
        #expect(TaskExecutionResourceClaimResolver.workspaceAccess(for: request)
            == (initialConsultation ? .exclusive : .shared))
        if route.hasPrefix("spec") { #expect(created.constraints.contains("Preserve user guidance")) }
        // A later change must never rewrite an already accepted request.
        let frozen = request.resourceClaimsJSON
        TaskWorkspaceConsultationPolicy.select(initialConsultation, for: composer, in: harness.context, persist: { try harness.context.save() })
        #expect(request.resourceClaimsJSON == frozen)
    }
}
