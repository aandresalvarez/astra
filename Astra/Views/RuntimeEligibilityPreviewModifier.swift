import SwiftUI
import ASTRACore
import ASTRAModels

struct RuntimeEligibilityPreviewState {
    private enum Phase {
        case idle
        case pending(signature: String)
        case resolved(signature: String, snapshot: TaskRuntimeEligibilitySnapshot)
        case unavailable(signature: String)
    }

    private let phase: Phase

    static let idle = RuntimeEligibilityPreviewState(phase: .idle)

    static func pending(signature: String) -> RuntimeEligibilityPreviewState {
        RuntimeEligibilityPreviewState(phase: .pending(signature: signature))
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
              case .pending(let signature) = phase else {
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
    private let evaluation: @MainActor () async -> TaskRuntimeEligibilitySnapshot?

    func evaluate() async -> TaskRuntimeEligibilitySnapshot? {
        await evaluation()
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
            hasAcceptedTurn: !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            guard await debounce(acceptedTurn) else { return nil }
            let intent = TaskTurnIntentResolver.preview(for: task, acceptedTurn: acceptedTurn)
            return evaluate(
                task: task,
                intent: intent,
                requestedRuntime: task.resolvedRuntimeID,
                selectedPolicyLevelRaw: selectedPolicyLevelRaw,
                skipPermissions: skipPermissions,
                providerSettings: providerSettings,
                readinessStates: readinessStates
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
            hasAcceptedTurn: !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            guard await debounce(acceptedTurn) else { return nil }
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
                readinessStates: readinessStates
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
        readinessStates: [AgentRuntimeID: RuntimeReadinessState]
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
            isRuntimeUsable: { runtime, _ in
                readinessStates[runtime] == .ready
            }
        )
    }

    private static func debounce(_ acceptedTurn: String) async -> Bool {
        guard !acceptedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        try? await Task.sleep(for: .milliseconds(180))
        return !Task.isCancelled
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
    let request: RuntimeEligibilityPreviewRequest
    @Binding var state: RuntimeEligibilityPreviewState

    func body(content: Content) -> some View {
        content.task(id: request.signature) {
            guard request.hasAcceptedTurn else {
                state = .idle
                return
            }
            state = .pending(signature: request.signature)
            let snapshot = await request.evaluate()
            guard !Task.isCancelled else { return }
            state = .evaluated(signature: request.signature, snapshot: snapshot)
        }
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
