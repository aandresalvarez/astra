import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Composer submission intent")
@MainActor
struct ComposerSubmissionIntentTests {
    @Test("Return before the debounce remembers exactly one send")
    func earlyReturnIsConsumedOnce() {
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(signature: "message", state: .idle)
        intent.requestIfUnresolved(signature: "message", state: .pending(signature: "message"))
        #expect(intent.matches("message"))
        #expect(intent.consume(signature: "message", allowed: true))
        #expect(!intent.consume(signature: "message", allowed: true))
        #expect(intent.signature == nil)
    }

    @Test("Edits, workspace changes and provider changes cancel the original intent")
    func changedRequestNeverSendsLater() {
        for change in ["edited message", "different workspace", "different runtime", "new attachments"] {
            let intent = ComposerSubmissionIntent()
            intent.requestIfUnresolved(signature: "original", state: .idle)
            intent.invalidate(unless: change)
            #expect(!intent.consume(signature: "original", allowed: true))
            #expect(!intent.consume(signature: change, allowed: true))
        }
    }

    @Test("A late old evaluation cannot consume a newer explicit send")
    func staleEvaluationCannotConsumeNewIntent() {
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(signature: "old", state: .idle)
        intent.requestIfUnresolved(signature: "new", state: .idle)
        #expect(!intent.consume(signature: "old", allowed: true))
        #expect(intent.matches("new"))
        #expect(intent.consume(signature: "new", allowed: true))
    }

    @Test("Cancel and leaving the composer prevent delayed submission")
    func cancellationDoesNotClearDraft() {
        let draft = TaskComposerDraft()
        draft.text = "Keep this message for editing"
        draft.submissionIntent.requestIfUnresolved(signature: "request", state: .idle)
        draft.submissionIntent.cancel()
        #expect(!draft.submissionIntent.consume(signature: "request", allowed: true))
        #expect(draft.text == "Keep this message for editing")
    }

    @Test("An unavailable or blocked check never becomes a delayed send")
    func failedCheckDoesNotSend() {
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(signature: "request", state: .evaluated(signature: "request", snapshot: nil))
        #expect(intent.signature == nil)
        intent.requestIfUnresolved(signature: "request", state: .idle)
        #expect(!intent.consume(signature: "request", allowed: false))
        #expect(!intent.consume(signature: "request", allowed: true))
    }

    @Test("Model and budget changes invalidate a waiting send in both composers")
    func executionChoicesArePartOfRequestIdentity() {
        let task = AgentTask(title: "QA", goal: "Answer briefly", runtime: .claudeCode)
        func existing() -> String {
            RuntimeEligibilityPreviewRequest.existingTask(task: task, messageText: "Hello", attachedFiles: [],
                selectedPolicyLevelRaw: "review", skipPermissions: false, providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: .ready], eventRevision: 0).signature
        }
        func newTask() -> String {
            RuntimeEligibilityPreviewRequest.newTask(draftTask: nil, workspace: nil, selectedSkills: [],
                attachedFiles: [], acceptedTurn: "Hello", requestedRuntime: .claudeCode,
                runtimeExplicitlySelected: true, selectedPolicyLevelRaw: "review", skipPermissions: false,
                defaultModel: task.model, defaultBudget: task.tokenBudget, providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: .ready]).signature
        }
        let beforeModel = [existing(), newTask()]
        task.model = "another-model"
        let beforeBudget = [existing(), newTask()]
        #expect(zip(beforeModel, beforeBudget).allSatisfy { $0 != $1 })
        task.tokenBudget += 1
        #expect(zip(beforeBudget, [existing(), newTask()]).allSatisfy { $0 != $1 })
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
        let stale = RuntimeEligibilityPreviewState.evaluated(signature: "old", snapshot: snapshot)
        let intent = ComposerSubmissionIntent()
        intent.requestIfUnresolved(signature: "current", state: stale)
        #expect(intent.matches("current"))
        #expect(!RuntimeEligibilitySubmissionPolicy.canExecute(hasInput: true, runtime: runtime,
            readinessStates: [runtime: .ready], previewState: stale, signature: "current"))
        #expect(!intent.consume(signature: "old", allowed: true))
        let current = RuntimeEligibilityPreviewState.evaluated(signature: "current", snapshot: snapshot)
        let allowed = RuntimeEligibilitySubmissionPolicy.canExecute(hasInput: true, runtime: runtime,
            readinessStates: [runtime: .ready], previewState: current, signature: "current")
        #expect(intent.consume(signature: "current", allowed: allowed) == snapshot.selectedCandidate.isEligible)
    }
}
