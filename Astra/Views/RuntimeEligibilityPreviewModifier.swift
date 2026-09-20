import SwiftUI
import ASTRACore
import ASTRAModels

struct RuntimeEligibilityPreviewState {
    private enum Phase {
        case idle
        case pending(signature: String, previous: TaskRuntimeEligibilitySnapshot?)
        case resolved(signature: String, snapshot: TaskRuntimeEligibilitySnapshot)
        case unavailable(signature: String)
    }

    private let phase: Phase

    static let idle = RuntimeEligibilityPreviewState(phase: .idle)

    /// `previous` is the verdict this state supersedes. The composer keeps
    /// showing it while the re-check runs, so typing no longer flips the
    /// provider pill to "Checking…" and back on every pause.
    static func pending(
        signature: String,
        previous: TaskRuntimeEligibilitySnapshot? = nil
    ) -> RuntimeEligibilityPreviewState {
        RuntimeEligibilityPreviewState(phase: .pending(signature: signature, previous: previous))
    }

    /// The verdict most recently resolved for this composer, whatever text it
    /// was for. Display only: `currentSnapshot(for:)` stays signature-exact,
    /// so a send can never ride on a verdict for different text.
    var lastResolvedSnapshot: TaskRuntimeEligibilitySnapshot? {
        switch phase {
        case .idle, .unavailable:
            return nil
        case .pending(_, let previous):
            return previous
        case .resolved(_, let snapshot):
            return snapshot
        }
    }

    static func evaluated(
        signature: String,
        snapshot: TaskRuntimeEligibilitySnapshot?
    ) -> RuntimeEligibilityPreviewState {
        guard let snapshot else {
            return RuntimeEligibilityPreviewState(
                phase: .unavailable(signature: signature)
            )
        }
        return RuntimeEligibilityPreviewState(
            phase: .resolved(signature: signature, snapshot: snapshot)
        )
    }

    func currentSnapshot(for expectedSignature: String?) -> TaskRuntimeEligibilitySnapshot? {
        guard let expectedSignature,
              case .resolved(let signature, let snapshot) = phase,
              signature == expectedSignature else {
            return nil
        }
        return snapshot
    }

    func isPending(for expectedSignature: String?) -> Bool {
        guard let expectedSignature,
              case .pending(let signature, _) = phase else {
            return false
        }
        return signature == expectedSignature
    }

    func isUnavailable(for expectedSignature: String?) -> Bool {
        guard let expectedSignature,
              case .unavailable(let signature) = phase else {
            return false
        }
        return signature == expectedSignature
    }
}

enum RuntimeEligibilitySubmissionPolicy {
    static func providersThatCanExecute(
        _ runtimes: [AgentRuntimeID],
        readinessStates: [AgentRuntimeID: RuntimeReadinessState],
        previewState: RuntimeEligibilityPreviewState,
        signature: String?
    ) -> [AgentRuntimeID] {
        guard let snapshot = previewState.currentSnapshot(for: signature) else {
            return []
        }
        return runtimes.filter {
            readinessStates[$0] == .ready
                && snapshot.candidates[$0]?.isEligible == true
        }
    }

    static func canExecute(
        hasInput: Bool,
        runtime: AgentRuntimeID,
        readinessStates: [AgentRuntimeID: RuntimeReadinessState],
        previewState: RuntimeEligibilityPreviewState,
        signature: String?
    ) -> Bool {
        guard hasInput,
              readinessStates[runtime] == .ready,
              let snapshot = previewState.currentSnapshot(for: signature) else {
            return false
        }
        return snapshot.candidates[runtime]?.isEligible == true
    }
}

@MainActor
struct RuntimeEligibilityPreviewRequest {
    let signature: String
    let hasAcceptedTurn: Bool
    let taskID: UUID?
    let acceptedTurnCharacterCount: Int
    /// The runtime the composer would actually launch. Scoring only this one is
    /// what makes the typing path cheap; see `RuntimeEligibilityPreviewModifier`.
    let selectedRuntime: AgentRuntimeID

    /// Stands in for the task identity of a composer that has neither a saved
    /// draft nor a workspace yet, so even that composer's previews agree with
    /// each other across edits.
    static let unanchoredComposerPreviewID = UUID(
        uuidString: "8F1D4C2E-0000-4000-A000-000000000001"
    )!
    private let evaluation: @MainActor ([AgentRuntimeID]?) async -> TaskRuntimeEligibilitySnapshot?

    /// `candidateRuntimes: nil` scores every registered runtime.
    func evaluate(
        candidateRuntimes: [AgentRuntimeID]? = nil
    ) async -> TaskRuntimeEligibilitySnapshot? {
        await evaluation(candidateRuntimes)
    }

    static func existingTask(
        task: AgentTask,
        acceptedTurn: String,
        selectedPolicyLevelRaw: String,
        skipPermissions: Bool,
        providerSettings: ProviderSettingsSnapshot,
        readinessStates: [AgentRuntimeID: RuntimeReadinessState],
        eventRevision: Int
    ) -> RuntimeEligibilityPreviewRequest {
        let readiness = readinessSignature(readinessStates)
        let signature = ([
            task.id.uuidString,
            task.resolvedRuntimeID.rawValue,
            String(task.runtimeExplicitlySelected),
            selectedPolicyLevelRaw,
            String(skipPermissions),
            acceptedTurn,
            providerSettings.signature,
            String(eventRevision)
        ] + task.skills.map(\.id.uuidString).sorted() + readiness).joined(separator: "|")

        return RuntimeEligibilityPreviewRequest(
            signature: signature,
            hasAcceptedTurn: !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            taskID: task.id,
            acceptedTurnCharacterCount: acceptedTurn.count,
            selectedRuntime: task.resolvedRuntimeID
        ) { candidateRuntimes in
            let intent = TaskTurnIntentResolver.preview(for: task, acceptedTurn: acceptedTurn)
            return evaluate(
                task: task,
                intent: intent,
                requestedRuntime: task.resolvedRuntimeID,
                selectedPolicyLevelRaw: selectedPolicyLevelRaw,
                skipPermissions: skipPermissions,
                providerSettings: providerSettings,
                readinessStates: readinessStates,
                candidateRuntimes: candidateRuntimes
            )
        }
    }

    static func newTask(
        draftTask: AgentTask?,
        workspace: Workspace?,
        selectedSkills: [Skill],
        attachedFiles: [String],
        acceptedTurn: String,
        requestedRuntime: AgentRuntimeID,
        runtimeExplicitlySelected: Bool,
        selectedPolicyLevelRaw: String,
        skipPermissions: Bool,
        defaultModel: String,
        defaultBudget: Int,
        providerSettings: ProviderSettingsSnapshot,
        readinessStates: [AgentRuntimeID: RuntimeReadinessState]
    ) -> RuntimeEligibilityPreviewRequest {
        let readiness = readinessSignature(readinessStates)
        let signature = ([
            draftTask?.id.uuidString ?? "new",
            requestedRuntime.rawValue,
            String(runtimeExplicitlySelected),
            selectedPolicyLevelRaw,
            String(skipPermissions),
            acceptedTurn,
            providerSettings.signature
        ]
            + attachedFiles
            + selectedSkills.map(\.id.uuidString).sorted()
            + readiness).joined(separator: "|")

        return RuntimeEligibilityPreviewRequest(
            signature: signature,
            hasAcceptedTurn: !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            taskID: draftTask?.id,
            acceptedTurnCharacterCount: acceptedTurn.count,
            selectedRuntime: requestedRuntime
        ) { candidateRuntimes in
            let goal = acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines)
            // Preview the task the composer will actually submit, never the managed
            // draft: `quickRun` deletes the draft and enqueues a fresh task carrying the
            // live attachment and skill selection, which the draft only learns about on
            // the next `saveDraft()`. Evaluating an unmanaged projection also keeps this
            // read-only preview from becoming a second writer of durable state.
            let previewTask = AgentTask(
                title: goal.isEmpty ? "New Task" : String(goal.prefix(60)),
                goal: goal,
                workspace: draftTask?.workspace ?? workspace,
                tokenBudget: defaultBudget,
                model: defaultModel,
                runtime: requestedRuntime
            )
            // This closure runs again on every keystroke, and a fresh AgentTask
            // mints a fresh UUID. Left alone, no two previews of this composer
            // would agree on a task identity, `carryingForwardUnscoredCandidates`
            // would refuse every merge, and the provider menu would drop each
            // runtime the narrow pass did not score. Anchor the preview to the
            // draft — or, before one exists, the workspace — so successive
            // previews are recognisably the same subject.
            previewTask.id = draftTask?.id
                ?? workspace?.id
                ?? Self.unanchoredComposerPreviewID
            previewTask.inputs = attachedFiles
            previewTask.skills = selectedSkills
            previewTask.runtimeExplicitlySelected = runtimeExplicitlySelected
            // Mirror the policy selection `quickRun` records, otherwise a workspace-level
            // default would outrank the composer's current pick (TaskPolicyStore.resolve
            // consults task events before workspace and global defaults).
            let composerLevel = skipPermissions
                ? AgentPolicyLevel.autonomous
                : AgentPolicyLevel.normalized(selectedPolicyLevelRaw)
            previewTask.events = [
                TaskEvent(
                    task: previewTask,
                    type: TaskPolicyStore.selectedPolicyEventType,
                    payload: composerLevel.rawValue
                )
            ]
            // The draft still owns the planning conversation, so a referential turn
            // ("continue") inherits exactly what the submitted task will inherit.
            let intent = TaskTurnIntentResolver.preview(
                for: draftTask ?? previewTask,
                acceptedTurn: acceptedTurn
            )
            return evaluate(
                task: previewTask,
                intent: intent,
                requestedRuntime: requestedRuntime,
                selectedPolicyLevelRaw: selectedPolicyLevelRaw,
                skipPermissions: skipPermissions,
                providerSettings: providerSettings,
                readinessStates: readinessStates,
                candidateRuntimes: candidateRuntimes
            )
        }
    }

    private static func evaluate(
        task: AgentTask,
        intent: TaskTurnIntentSnapshot,
        requestedRuntime: AgentRuntimeID,
        selectedPolicyLevelRaw: String,
        skipPermissions: Bool,
        providerSettings: ProviderSettingsSnapshot,
        readinessStates: [AgentRuntimeID: RuntimeReadinessState],
        candidateRuntimes: [AgentRuntimeID]?
    ) -> TaskRuntimeEligibilitySnapshot? {
        guard !Task.isCancelled else { return nil }
        let executionPolicy = AgentRuntimeExecutionPolicy.default.withTurnIntentSnapshot(intent)
        return TaskLaunchAdmissionService.evaluate(
            task: task,
            intent: intent,
            requestedRuntime: requestedRuntime,
            runtimeConfiguration: AgentRuntimeConfiguration(
                providerSettings: providerSettings.providerSettings,
                defaultRuntimeID: requestedRuntime
            ),
            executionPolicy: executionPolicy,
            fallbackPermissionPolicy: skipPermissions ? .autonomous : .interactive,
            defaultPolicyLevelRaw: selectedPolicyLevelRaw,
            phase: .run,
            candidateRuntimes: candidateRuntimes ?? AgentRuntimeAdapterRegistry.runtimeIDs,
            isRuntimeUsable: { runtime, _ in
                readinessStates[runtime] == .ready
            }
        )
    }

    private static func readinessSignature(
        _ states: [AgentRuntimeID: RuntimeReadinessState]
    ) -> [String] {
        AgentRuntimeAdapterRegistry.runtimeIDs.map {
            "\($0.rawValue)=\(states[$0]?.rawValue ?? "checking")"
        }
    }
}

private struct RuntimeEligibilityPreviewModifier: ViewModifier {
    /// The evaluation runs on the main actor and, on a 360-event thread, costs
    /// several hundred milliseconds (`runtime_eligibility_preview` in the log).
    /// At 180 ms it fired between most words; at 350 ms it fires when the user
    /// actually pauses, and the verdict is still back before they reach for
    /// Send.
    static let debounce: Duration = .milliseconds(350)

    /// How long the composer must stay quiet before the other providers are
    /// scored. Scoring costs about the same per runtime, so doing all of them
    /// on the typing path made the pause cost six times what Send needs; see
    /// the scope split in `body`.
    static let fullSetIdle: Duration = .milliseconds(600)

    let request: RuntimeEligibilityPreviewRequest
    @Binding var state: RuntimeEligibilityPreviewState

    func body(content: Content) -> some View {
        content.task(id: request.signature) {
            guard request.hasAcceptedTurn else {
                state = .idle
                return
            }
            // Nothing is written until the debounce elapses: a keystroke that
            // is followed by another one within 350 ms costs no state change and
            // therefore no extra body pass of the 6,000-line composer view.
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let previous = state.lastResolvedSnapshot
            state = .pending(signature: request.signature, previous: previous)

            // Score the selected runtime alone first. Send only consults that
            // one verdict, and admission costs roughly the same for each
            // runtime it scores, so this is the whole pause cost minus the
            // providers nobody asked about.
            let selectedStartedAt = DispatchTime.now().uptimeNanoseconds
            let selected = await request.evaluate(candidateRuntimes: [request.selectedRuntime])
            guard !Task.isCancelled else { return }

            // An ineligible selection is the one case that still needs the rest
            // immediately: the launch block names a runtime to switch to, and
            // that suggestion can only come from scoring the others.
            let selectionIsEligible = selected?.selectedCandidate.isEligible == true
            logEvaluation(
                scope: selectionIsEligible ? "selected" : "selected_blocked",
                start: selectedStartedAt,
                snapshot: selected
            )

            if let selected, selectionIsEligible {
                state = .evaluated(
                    signature: request.signature,
                    snapshot: selected.carryingForwardUnscoredCandidates(from: previous)
                )
                // The provider dropdown is the only surface that reads the other
                // verdicts, and reaching it means the composer went quiet.
                try? await Task.sleep(for: Self.fullSetIdle)
                guard !Task.isCancelled else { return }
            }

            let fullStartedAt = DispatchTime.now().uptimeNanoseconds
            let full = await request.evaluate()
            guard !Task.isCancelled else { return }
            logEvaluation(scope: "full", start: fullStartedAt, snapshot: full)
            state = .evaluated(signature: request.signature, snapshot: full)
        }
    }

    private func logEvaluation(
        scope: String,
        start: UInt64,
        snapshot: TaskRuntimeEligibilitySnapshot?
    ) {
        PerformanceTelemetry.logIfNeeded(
            "runtime_eligibility_preview",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "accepted_turn_chars": PerformanceTelemetryFields.count(request.acceptedTurnCharacterCount),
                "candidate_count": PerformanceTelemetryFields.count(snapshot?.candidates.count ?? 0),
                "scope": scope,
                "result": snapshot == nil ? "unavailable" : "resolved"
            ],
            taskID: request.taskID
        )
    }
}

extension View {
    func runtimeEligibilityPreview(
        _ request: RuntimeEligibilityPreviewRequest,
        state: Binding<RuntimeEligibilityPreviewState>
    ) -> some View {
        modifier(RuntimeEligibilityPreviewModifier(request: request, state: state))
    }
}

extension ChatPanelView {
    var selectedComposerRuntimeCanExecuteRequest: Bool {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        return RuntimeEligibilitySubmissionPolicy.canExecute(
            hasInput: hasInput,
            runtime: runtime,
            readinessStates: runtimeReadinessStates,
            previewState: runtimeEligibilityPreviewState,
            signature: runtimeEligibilityPreviewRequest.signature
        )
    }

    var runtimeEligibilityPreviewRequest: RuntimeEligibilityPreviewRequest {
        .newTask(
            draftTask: draftTask,
            workspace: workspace,
            selectedSkills: selectedSkills,
            attachedFiles: attachedFiles,
            acceptedTurn: messageText,
            requestedRuntime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID),
            runtimeExplicitlySelected: composerRuntimeExplicitlySelected,
            selectedPolicyLevelRaw: composerPolicyLevelRaw,
            skipPermissions: composerSkipPermissions,
            defaultModel: defaultModel,
            defaultBudget: defaultBudget,
            providerSettings: providerSettingsSnapshot,
            readinessStates: runtimeReadinessStates
        )
    }
}

extension TaskMainView {
    var runtimeEligibilityPreviewRequest: RuntimeEligibilityPreviewRequest {
        .existingTask(
            task: task,
            acceptedTurn: messageText,
            selectedPolicyLevelRaw: taskPolicyLevelRaw,
            skipPermissions: taskSkipPermissions,
            providerSettings: providerSettingsSnapshot,
            readinessStates: runtimeReadinessStates,
            eventRevision: threadViewModel.appliedSnapshotRevision
        )
    }
}
