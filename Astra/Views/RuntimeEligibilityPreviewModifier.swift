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
            readinessStates[$0]?.allowsTaskLaunch == true
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
              readinessStates[runtime]?.allowsTaskLaunch == true,
              let snapshot = previewState.currentSnapshot(for: signature) else {
            return false
        }
        return snapshot.candidates[runtime]?.isEligible == true
    }
}

@MainActor
struct RuntimeEligibilityPreviewRequest {
    let signature: String
    /// User-authored choices; history and runtime probes only invalidate admission.
    let submissionSignature: String
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
    typealias BetweenRuntimes = @MainActor () async -> Bool
    private let evaluation: @MainActor ([AgentRuntimeID]?, BetweenRuntimes?) async -> TaskRuntimeEligibilitySnapshot?

    /// `candidateRuntimes: nil` scores every registered runtime.
    /// `betweenRuntimes` runs after each scored runtime but the last; answering
    /// false abandons the evaluation (nil). `yieldToMainRunLoop` is the one
    /// the composer uses.
    func evaluate(
        candidateRuntimes: [AgentRuntimeID]? = nil,
        betweenRuntimes: BetweenRuntimes? = nil
    ) async -> TaskRuntimeEligibilitySnapshot? {
        await evaluation(candidateRuntimes, betweenRuntimes)
    }

    /// Lets the main run loop take a turn, so keystrokes and layout queued
    /// behind an admission pass are handled before the next runtime is
    /// scored. A timer, not `Task.yield()`: a yield re-enqueues on the main
    /// queue and can resume before the run loop sees any input. Answers
    /// false once the preview has been superseded.
    static func yieldToMainRunLoop() async -> Bool {
        try? await Task.sleep(for: .milliseconds(1))
        return !Task.isCancelled
    }

    static func existingTask(
        task: AgentTask,
        messageText: String,
        attachedFiles: [String],
        selectedPolicyLevelRaw: String,
        skipPermissions: Bool,
        providerSettings: ProviderSettingsSnapshot,
        readinessStates: [AgentRuntimeID: RuntimeReadinessState],
        eventRevision: Int
    ) -> RuntimeEligibilityPreviewRequest {
        // Preview the turn Send will persist: the typed text plus its
        // attachment block. An attachment-only follow-up is then a turn like
        // any other, and attaching a file re-runs the preview.
        let acceptedTurn = TaskComposerCoordinator.composedMessage(
            messageText: messageText,
            attachedFiles: attachedFiles
        )
        let readiness = readinessSignature(readinessStates)
        let submissionSignature = ([
            task.id.uuidString,
            task.resolvedRuntimeID.rawValue,
            String(task.runtimeExplicitlySelected),
            task.model,
            String(task.tokenBudget),
            task.reasoningEffort ?? "",
            selectedPolicyLevelRaw,
            String(skipPermissions),
            acceptedTurn,
            providerSettings.signature
        ] + task.skills.map(\.id.uuidString).sorted()).joined(separator: "|")
        let signature = ([submissionSignature, String(eventRevision)] + readiness).joined(separator: "|")

        return RuntimeEligibilityPreviewRequest(
            signature: signature,
            submissionSignature: submissionSignature,
            hasAcceptedTurn: !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            taskID: task.id,
            acceptedTurnCharacterCount: acceptedTurn.count,
            selectedRuntime: task.resolvedRuntimeID
        ) { candidateRuntimes, betweenRuntimes in
            let intent = TaskTurnIntentResolver.preview(for: task, acceptedTurn: acceptedTurn)
            return await evaluate(
                task: task,
                intent: intent,
                requestedRuntime: task.resolvedRuntimeID,
                selectedPolicyLevelRaw: selectedPolicyLevelRaw,
                skipPermissions: skipPermissions,
                providerSettings: providerSettings,
                readinessStates: readinessStates,
                candidateRuntimes: candidateRuntimes,
                betweenRuntimes: betweenRuntimes
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
        reasoningEffort: String? = nil,
        providerSettings: ProviderSettingsSnapshot,
        readinessStates: [AgentRuntimeID: RuntimeReadinessState]
    ) -> RuntimeEligibilityPreviewRequest {
        let readiness = readinessSignature(readinessStates)
        let submissionSignature = ([
            draftTask?.id.uuidString ?? "new",
            // A switched composer keeps its draft and skills but not its workspace,
            // and a Replace import gives the same id a new model (path, environment).
            workspace?.id.uuidString ?? "none",
            workspace.map { String(describing: $0.persistentModelID) } ?? "none",
            requestedRuntime.rawValue,
            String(runtimeExplicitlySelected),
            defaultModel,
            String(defaultBudget),
            reasoningEffort ?? "",
            selectedPolicyLevelRaw,
            String(skipPermissions),
            acceptedTurn,
            providerSettings.signature
        ]
            + attachedFiles
            + selectedSkills.map(\.id.uuidString).sorted()).joined(separator: "|")
        let signature = ([submissionSignature] + readiness).joined(separator: "|")

        return RuntimeEligibilityPreviewRequest(
            signature: signature,
            submissionSignature: submissionSignature,
            hasAcceptedTurn: !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            taskID: draftTask?.id,
            acceptedTurnCharacterCount: acceptedTurn.count,
            selectedRuntime: requestedRuntime
        ) { candidateRuntimes, betweenRuntimes in
            let goal = acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines)
            // Preview the task the composer will actually submit, never the managed
            // draft: `quickRun` deletes the draft and enqueues a fresh task carrying the
            // live attachment and skill selection, which the draft only learns about on
            // the next `saveDraft()`. Evaluating an unmanaged projection also keeps this
            // read-only preview from becoming a second writer of durable state —
            // which it did, as phantom drafts, while it held the managed skills.
            let previewTask = ComposerTaskProjection.detachedTask(
                title: goal.isEmpty ? "New Task" : String(goal.prefix(60)),
                goal: goal,
                workspace: draftTask?.workspace ?? workspace,
                skills: selectedSkills,
                inputs: attachedFiles,
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
            previewTask.runtimeExplicitlySelected = runtimeExplicitlySelected
            previewTask.reasoningEffort = reasoningEffort
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
            return await evaluate(
                task: previewTask,
                intent: intent,
                requestedRuntime: requestedRuntime,
                selectedPolicyLevelRaw: selectedPolicyLevelRaw,
                skipPermissions: skipPermissions,
                providerSettings: providerSettings,
                readinessStates: readinessStates,
                candidateRuntimes: candidateRuntimes,
                betweenRuntimes: betweenRuntimes
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
        candidateRuntimes: [AgentRuntimeID]?,
        betweenRuntimes: BetweenRuntimes?
    ) async -> TaskRuntimeEligibilitySnapshot? {
        guard !Task.isCancelled else { return nil }
        var executionPolicy = AgentRuntimeExecutionPolicy.default.withTurnIntentSnapshot(intent)
        let configuration = AgentRuntimeConfiguration(
            providerSettings: providerSettings.providerSettings, defaultRuntimeID: requestedRuntime)
        var copilotExecutableAvailable: Bool?
        if (candidateRuntimes ?? AgentRuntimeAdapterRegistry.runtimeIDs).contains(.copilotCLI) {
            let settings = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).launchSettings(configuration: configuration)
            copilotExecutableAvailable = FileManager.default.isExecutableFile(atPath: settings.executablePath)
            if copilotExecutableAvailable == true {
                do {
                    executionPolicy.copilotCapabilityResolution = .answered(
                        try await CopilotCLIRuntime.requiredCapabilities(executablePath: settings.executablePath))
                } catch {
                    guard !Task.isCancelled else { return nil }
                    executionPolicy.copilotCapabilityResolution = .unavailable(error.localizedDescription)
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        let pass = TaskLaunchAdmissionService.AdmissionPass(
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
                readinessStates[runtime]?.allowsTaskLaunch == true
                    && (runtime != .copilotCLI || copilotExecutableAvailable != false)
            }
        )
        return await pass.evaluateIncrementally(betweenRuntimes: betweenRuntimes ?? { true })
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
    let submissionIntent: ComposerSubmissionIntent?
    let onSubmissionEvaluation: (RuntimeEligibilityPreviewRequest, Bool) -> Void

    private struct WorkID: Equatable {
        let signature: String
        let submitRequested: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: WorkID(signature: request.signature,
                               submitRequested: submissionIntent?.matches(request.submissionSignature) == true)) {
            submissionIntent?.invalidate(unless: request.submissionSignature)
            guard request.hasAcceptedTurn else {
                submissionIntent?.cancel()
                state = .idle
                return
            }
            // Nothing is written until the debounce elapses: a keystroke that
            // is followed by another one within 350 ms costs no state change and
            // therefore no extra body pass of the 6,000-line composer view.
            if submissionIntent?.matches(request.submissionSignature) != true {
                try? await Task.sleep(for: Self.debounce)
            }
            guard !Task.isCancelled else { return }
            let previous = state.lastResolvedSnapshot
            state = .pending(signature: request.signature, previous: previous)

            // Admission itself needs the managed models and stays on the main
            // actor, but the capability catalog, pack catalog and approval
            // records it consults are plain files. Read them once, here, off
            // the main actor; both passes below then resolve against them
            // without touching the disk.
            let inputsStartedAt = DispatchTime.now().uptimeNanoseconds
            let loadedInputs = await CapabilityResolutionInputs.loadDetached()
            guard !Task.isCancelled else { return }
            guard let inputs = loadedInputs else {
                state = .evaluated(signature: request.signature, snapshot: nil)
                onSubmissionEvaluation(request, false)
                return
            }
            let inputsMilliseconds = PerformanceTelemetry.elapsedMilliseconds(since: inputsStartedAt)

            // Score the selected runtime alone first. Send only consults that
            // one verdict, and admission costs roughly the same for each
            // runtime it scores, so this is the whole pause cost minus the
            // providers nobody asked about.
            let selectedStartedAt = DispatchTime.now().uptimeNanoseconds
            let selected = await CapabilityResolutionInputs.$pinned.withValue(inputs) {
                await request.evaluate(candidateRuntimes: [request.selectedRuntime])
            }
            guard !Task.isCancelled else { return }

            // An ineligible selection is the one case that still needs the rest
            // immediately: the launch block names a runtime to switch to, and
            // that suggestion can only come from scoring the others.
            let selectionIsEligible = selected?.selectedCandidate.isEligible == true
            logEvaluation(
                scope: selectionIsEligible ? "selected" : "selected_blocked",
                start: selectedStartedAt,
                snapshot: selected,
                inputsMilliseconds: inputsMilliseconds
            )

            if submissionIntent?.matches(request.submissionSignature) == true {
                state = .evaluated(signature: request.signature, snapshot: selected)
                onSubmissionEvaluation(request, selectionIsEligible)
                return
            }

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

            // Every runtime costs about as much as the selected one, so scoring
            // them back to back held the main actor for 0.5–0.9 s, often just
            // as typing resumed (2026-10-21 prod log). Score one at a time and
            // let the run loop in between: a keystroke then waits for at most
            // one runtime, and cancels the rest.
            let fullStartedAt = DispatchTime.now().uptimeNanoseconds
            let slices = MainActorSliceMeter()
            let full = await CapabilityResolutionInputs.$pinned.withValue(inputs) {
                await request.evaluate(betweenRuntimes: {
                    slices.endSlice()
                    let proceed = await RuntimeEligibilityPreviewRequest.yieldToMainRunLoop()
                    slices.beginSlice()
                    return proceed
                })
            }
            slices.endSlice()
            guard !Task.isCancelled else { return }
            logEvaluation(
                scope: "full",
                start: fullStartedAt,
                snapshot: full,
                inputsMilliseconds: inputsMilliseconds,
                longestSliceMilliseconds: slices.longestMilliseconds
            )
            state = .evaluated(signature: request.signature, snapshot: full)
        }
        .onChange(of: request.submissionSignature) { submissionIntent?.invalidate(unless: request.submissionSignature) }
        .onDisappear { submissionIntent?.cancel() }
    }

    private func logEvaluation(
        scope: String,
        start: UInt64,
        snapshot: TaskRuntimeEligibilitySnapshot?,
        inputsMilliseconds: Double,
        longestSliceMilliseconds: Double? = nil
    ) {
        var fields = [
            "accepted_turn_chars": PerformanceTelemetryFields.count(request.acceptedTurnCharacterCount),
            "candidate_count": PerformanceTelemetryFields.count(snapshot?.candidates.count ?? 0),
            // Off the main actor; kept out of the logged duration.
            "inputs_load_ms": String(format: "%.1f", inputsMilliseconds),
            "scope": scope,
            "result": snapshot == nil ? "unavailable" : "resolved"
        ]
        // The full pass yields between runtimes, so its duration is wall
        // clock; this is the longest the main actor was held in one go.
        if let longestSliceMilliseconds {
            fields["longest_main_actor_slice_ms"] = String(format: "%.1f", longestSliceMilliseconds)
        }
        PerformanceTelemetry.logIfNeeded(
            "runtime_eligibility_preview",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: fields,
            taskID: request.taskID
        )
    }
}

/// Times the stretches an incremental admission pass holds the main actor.
@MainActor
final class MainActorSliceMeter {
    private var sliceStart = DispatchTime.now().uptimeNanoseconds
    private(set) var longestMilliseconds: Double = 0

    func beginSlice() {
        sliceStart = DispatchTime.now().uptimeNanoseconds
    }

    func endSlice() {
        longestMilliseconds = max(longestMilliseconds, PerformanceTelemetry.elapsedMilliseconds(since: sliceStart))
    }
}

extension View {
    func runtimeEligibilityPreview(
        _ request: RuntimeEligibilityPreviewRequest,
        state: Binding<RuntimeEligibilityPreviewState>,
        submissionIntent: ComposerSubmissionIntent? = nil,
        onSubmissionEvaluation: @escaping (RuntimeEligibilityPreviewRequest, Bool) -> Void = { _, _ in }
    ) -> some View {
        modifier(RuntimeEligibilityPreviewModifier(request: request, state: state,
                                                  submissionIntent: submissionIntent, onSubmissionEvaluation: onSubmissionEvaluation))
    }
}

extension ChatPanelView {
    /// False while the composer waits for the capability snapshot of a workspace
    /// it was just switched to: submitting then would persist no skills, and
    /// none of that workspace's instructions or tools, on the task.
    var isCapabilitySnapshotCurrent: Bool {
        capabilitySnapshot.workspaceModelID == workspace?.persistentModelID
    }

    var selectedComposerRuntimeCanExecuteRequest: Bool {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        return RuntimeEligibilitySubmissionPolicy.canExecute(
            hasInput: hasInput && isCapabilitySnapshotCurrent,
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
            reasoningEffort: composerReasoningEffort,
            providerSettings: providerSettingsSnapshot,
            readinessStates: runtimeReadinessStates
        )
    }
}

extension TaskMainView {
    /// Everything the preview depends on except the typed text, read now. The
    /// composer calls this in `body` and applies the result to the text inside
    /// its reader, so the inputs stay dependencies of `TaskMainView` and the
    /// text stays a dependency of the reader alone.
    func runtimeEligibilityPreviewRequestBuilder() -> (String) -> RuntimeEligibilityPreviewRequest {
        let task = task
        let attachedFiles = attachedFiles
        let selectedPolicyLevelRaw = taskPolicyLevelRaw
        let skipPermissions = taskSkipPermissions
        let providerSettings = providerSettingsSnapshot
        let readinessStates = runtimeReadinessStates
        let eventRevision = threadViewModel.appliedSnapshotRevision
        return { messageText in
            .existingTask(
                task: task,
                messageText: messageText,
                attachedFiles: attachedFiles,
                selectedPolicyLevelRaw: selectedPolicyLevelRaw,
                skipPermissions: skipPermissions,
                providerSettings: providerSettings,
                readinessStates: readinessStates,
                eventRevision: eventRevision
            )
        }
    }

    /// The request for the live draft. For actions such as Send; `body` goes
    /// through `runtimeEligibilityPreviewRequestBuilder()` instead.
    var runtimeEligibilityPreviewRequest: RuntimeEligibilityPreviewRequest {
        runtimeEligibilityPreviewRequestBuilder()(composerDraft.text)
    }
}
