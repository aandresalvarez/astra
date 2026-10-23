import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Composer submission intent")
@MainActor
struct ComposerSubmissionIntentTests {
    private func request(_ text: String, runtime: AgentRuntimeID = .claudeCode) -> RuntimeEligibilityPreviewRequest {
        .newTask(draftTask: nil, workspace: nil, selectedSkills: [], attachedFiles: [], acceptedTurn: text,
                 requestedRuntime: runtime, runtimeExplicitlySelected: true, selectedPolicyLevelRaw: "review",
                 skipPermissions: false, defaultModel: "test-model", defaultBudget: 1_000,
                 providerSettings: .headlessScenario, readinessStates: [runtime: .ready])
    }

    @Test("Return before the debounce remembers exactly one send")
    func earlyReturnIsConsumedOnce() {
        let intent = ComposerSubmissionIntent()
        let request = request("message")
        #expect(!intent.canSubmitOrWait(request: request, state: .idle, canExecute: false))
        #expect(!intent.canSubmitOrWait(request: request, state: .pending(signature: request.signature), canExecute: false))
        #expect(intent.matches(request.submissionSignature))
        #expect(intent.consume(evaluatedRequest: request, currentRequest: request, allowed: true))
        #expect(!intent.consume(evaluatedRequest: request, currentRequest: request, allowed: true))
        #expect(intent.signature == nil)
    }

    @Test("History and readiness refresh preserve the draft but require a fresh verdict")
    func historyRefreshKeepsPendingSend() {
        let task = AgentTask(title: "QA", goal: "Answer briefly", runtime: .claudeCode)
        func request(_ revision: Int, readiness: RuntimeReadinessState) -> RuntimeEligibilityPreviewRequest {
            .existingTask(task: task, messageText: "Continue", attachedFiles: [],
                selectedPolicyLevelRaw: "review", skipPermissions: false, providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: readiness], eventRevision: revision)
        }
        let original = request(0, readiness: .warning)
        for refreshed in [request(1, readiness: .warning), request(0, readiness: .ready)] {
            let intent = ComposerSubmissionIntent()
            intent.requestIfUnresolved(request: original, state: .idle)
            intent.invalidate(unless: refreshed.submissionSignature)
            #expect(intent.signature != nil)
            #expect(original.signature != refreshed.signature, "Admission must recheck changed history/readiness")
            // Even before SwiftUI cancels the old async pass, it cannot consume the send.
            #expect(!intent.consume(evaluatedRequest: original, currentRequest: refreshed, allowed: true))
            #expect(!intent.consume(evaluatedRequest: original, currentRequest: refreshed, allowed: false))
            #expect(intent.matches(refreshed.submissionSignature))
            #expect(intent.consume(evaluatedRequest: refreshed, currentRequest: refreshed, allowed: true))
        }
        let blocked = request(1, readiness: .blocked)
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(request: original, state: .idle)
        #expect(!intent.consume(evaluatedRequest: blocked, currentRequest: blocked, allowed: false))
        #expect(intent.signature == nil)
    }

    @Test("Edits cancel the original intent, including a late evaluation")
    func changedRequestNeverSendsLater() {
        let original = request("original")
        let changed = request("edited message")
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(request: original, state: .idle)
        intent.invalidate(unless: changed.submissionSignature)
        #expect(!intent.consume(evaluatedRequest: original, currentRequest: changed, allowed: true))
        #expect(!intent.consume(evaluatedRequest: changed, currentRequest: changed, allowed: true))
    }

    @Test("A late old evaluation cannot consume a newer explicit send")
    func staleEvaluationCannotConsumeNewIntent() {
        let old = request("old"), new = request("new")
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(request: old, state: .idle)
        intent.requestIfUnresolved(request: new, state: .idle)
        #expect(!intent.consume(evaluatedRequest: old, currentRequest: new, allowed: true))
        #expect(intent.matches(new.submissionSignature))
        #expect(intent.consume(evaluatedRequest: new, currentRequest: new, allowed: true))
    }

    @Test("Cancel and leaving the composer prevent delayed submission")
    func cancellationDoesNotClearDraft() {
        let draft = TaskComposerDraft()
        draft.text = "Keep this message for editing"
        let request = request(draft.text)
        draft.submissionIntent.requestIfUnresolved(request: request, state: .idle)
        draft.submissionIntent.cancel()
        #expect(!draft.submissionIntent.consume(evaluatedRequest: request, currentRequest: request, allowed: true))
        #expect(draft.text == "Keep this message for editing")
    }

    @Test("An unavailable or blocked check never becomes a delayed send")
    func failedCheckDoesNotSend() {
        let intent = ComposerSubmissionIntent()
        let request = request("request")
        #expect(!intent.canSubmitOrWait(request: request,
            state: .evaluated(signature: request.signature, snapshot: nil), canExecute: false))
        #expect(intent.signature == nil)
        intent.requestIfUnresolved(request: request, state: .idle)
        #expect(!intent.consume(evaluatedRequest: request, currentRequest: request, allowed: false))
        #expect(!intent.consume(evaluatedRequest: request, currentRequest: request, allowed: true))
    }

    @Test("An immediate eligible submission clears a previously waiting send")
    func immediateSubmissionDoesNotLeaveAnIntent() {
        let intent = ComposerSubmissionIntent()
        let request = request("request")
        intent.requestIfUnresolved(request: request, state: .idle)
        #expect(intent.canSubmitOrWait(request: request, state: .idle, canExecute: true))
        #expect(!intent.consume(evaluatedRequest: request, currentRequest: request, allowed: true))
    }

    @Test("Model, budget and reasoning choices invalidate a waiting send in both composers")
    func executionChoicesArePartOfRequestIdentity() {
        let task = AgentTask(title: "QA", goal: "Answer briefly", runtime: .claudeCode)
        func existing() -> String {
            RuntimeEligibilityPreviewRequest.existingTask(task: task, messageText: "Hello", attachedFiles: [],
                selectedPolicyLevelRaw: "review", skipPermissions: false, providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: .ready], eventRevision: 0).submissionSignature
        }
        func newTask() -> String {
            RuntimeEligibilityPreviewRequest.newTask(draftTask: nil, workspace: nil, selectedSkills: [],
                attachedFiles: [], acceptedTurn: "Hello", requestedRuntime: .claudeCode,
                runtimeExplicitlySelected: true, selectedPolicyLevelRaw: "review", skipPermissions: false,
                defaultModel: task.model, defaultBudget: task.tokenBudget, reasoningEffort: task.reasoningEffort,
                providerSettings: .headlessScenario, readinessStates: [.claudeCode: .ready]).submissionSignature
        }
        let beforeModel = [existing(), newTask()]
        task.model = "another-model"
        let beforeBudget = [existing(), newTask()]
        #expect(zip(beforeModel, beforeBudget).allSatisfy { $0 != $1 })
        task.tokenBudget += 1
        let beforeEffort = [existing(), newTask()]
        #expect(zip(beforeBudget, beforeEffort).allSatisfy { $0 != $1 })
        task.reasoningEffort = "high"
        #expect(zip(beforeEffort, [existing(), newTask()]).allSatisfy { $0 != $1 })
    }

    @Test("Waiting never lets an old runtime verdict authorize the current text",
          arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func eligibilityRemainsExact(runtime: AgentRuntimeID) {
        let task = AgentTask(title: "QA", goal: "Answer briefly", runtime: runtime)
        let snapshot = TaskLaunchAdmissionService.evaluate(
            task: task,
            intent: TaskTurnIntentSnapshot(taskID: task.id, sourceEventID: nil, acceptedTurn: "Answer briefly"),
            requestedRuntime: runtime,
            runtimeConfiguration: AgentRuntimeConfiguration(providerSettings: ProviderSettingsSnapshot.headlessScenario.providerSettings,
                                                            defaultRuntimeID: runtime),
            executionPolicy: .default,
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [runtime],
            isRuntimeUsable: { _, _ in true },
            isHostControlBrokerAvailable: { true }
        )
        let old = request("old", runtime: runtime), current = request("current", runtime: runtime)
        let stale = RuntimeEligibilityPreviewState.evaluated(signature: old.signature, snapshot: snapshot)
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(request: current, state: stale)
        #expect(intent.matches(current.submissionSignature))
        #expect(!RuntimeEligibilitySubmissionPolicy.canExecute(hasInput: true, runtime: runtime,
            readinessStates: [runtime: .ready], previewState: stale, signature: current.signature))
        #expect(!intent.consume(evaluatedRequest: old, currentRequest: current, allowed: true))
        let resolved = RuntimeEligibilityPreviewState.evaluated(signature: current.signature, snapshot: snapshot)
        let allowed = RuntimeEligibilitySubmissionPolicy.canExecute(hasInput: true, runtime: runtime,
            readinessStates: [runtime: .ready], previewState: resolved, signature: current.signature)
        #expect(intent.consume(evaluatedRequest: current, currentRequest: current, allowed: allowed) == snapshot.selectedCandidate.isEligible)
        if !allowed {
            #expect(!intent.canSubmitOrWait(request: current, state: resolved, canExecute: false))
            #expect(intent.signature == nil)
        }
    }
}
