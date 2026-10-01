import Foundation
import ASTRACore
import ASTRAModels

enum TaskComposerSlashCommandID: String, CaseIterable, Sendable {
    case remember
    case mcp
    case routine
    case recap
}

struct TaskComposerSlashOption: Equatable, Identifiable, Sendable {
    var id: TaskComposerSlashCommandID
    var command: String

    var executesImmediately: Bool {
        id == .recap
    }
}

enum TaskComposerSendAction: Equatable, Sendable {
    case none
    case remember(String)
    case recap
    case routine(instructions: String?)
    case mcpInstall(MCPInstallChatRequest)
    case mcpInstallFailure(String)
    case message(String)

    var launchesProviderWork: Bool {
        switch self {
        case .recap, .routine, .message:
            true
        case .none, .remember, .mcpInstall, .mcpInstallFailure:
            false
        }
    }
}

struct TaskComposerRuntimeUpdate: Equatable, Sendable {
    var previousRuntime: String?
    var runtime: String
    var previousModel: String
    var resolvedModel: String

    var modelChanged: Bool {
        previousModel != resolvedModel
    }
}

enum TaskComposerCoordinator {
    static func hasInput(messageText: String, attachedFiles: [String]) -> Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    static func shouldShowSlashMenu(messageText: String) -> Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && !trimmed.contains(" ") && trimmed.count < 14
    }

    static func visibleSlashOptions(messageText: String) -> [TaskComposerSlashOption] {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        var options: [TaskComposerSlashOption] = []
        if "/remember".hasPrefix(trimmed) {
            options.append(TaskComposerSlashOption(id: .remember, command: "/remember "))
        }
        if "/mcp".hasPrefix(trimmed) {
            options.append(TaskComposerSlashOption(id: .mcp, command: "/mcp "))
        }
        if "/routine".hasPrefix(trimmed) || "/schedule".hasPrefix(trimmed) {
            options.append(TaskComposerSlashOption(id: .routine, command: "/routine "))
        }
        if "/recap".hasPrefix(trimmed) {
            options.append(TaskComposerSlashOption(id: .recap, command: "/recap"))
        }
        return options
    }

    static func sendAction(
        messageText: String,
        attachedFiles: [String],
        hasWorkspace: Bool = true
    ) -> TaskComposerSendAction {
        guard hasInput(messageText: messageText, attachedFiles: attachedFiles) else { return .none }

        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("/remember ") {
            let memoryText = String(trimmed.dropFirst("/remember ".count))
                .trimmingCharacters(in: .whitespaces)
            return .remember(memoryText)
        }

        if lower == "/recap" || lower.hasPrefix("/recap ") {
            return .recap
        }

        if lower == "/routine" || lower.hasPrefix("/routine ") || lower == "/schedule" || lower.hasPrefix("/schedule ") {
            let commandLength = lower.hasPrefix("/routine") ? "/routine ".count : "/schedule ".count
            let instructions = (lower == "/routine" || lower == "/schedule")
                ? ""
                : String(trimmed.dropFirst(commandLength)).trimmingCharacters(in: .whitespaces)
            return .routine(instructions: instructions.isEmpty ? nil : instructions)
        }

        if lower == "/mcp" || lower.hasPrefix("/mcp ") {
            let outcome = MCPInstallChatCommand.explicitInstallTurnOutcome(
                input: trimmed,
                hasWorkspace: hasWorkspace
            )
            if let request = outcome.request {
                return .mcpInstall(request)
            }
            return .mcpInstallFailure(outcome.assistantMessage)
        }

        return .message(composedMessage(messageText: messageText, attachedFiles: attachedFiles))
    }

    /// The text a conversation message persists and sends: the typed text,
    /// then one `Attached files:` block listing each attachment.
    static func composedMessage(messageText: String, attachedFiles: [String]) -> String {
        TaskAttachmentBlock.message(messageText, attaching: attachedFiles)
    }

    /// `requestedModel` is a model the user picked together with the runtime
    /// (the composer's model selector); it wins when the runtime offers it,
    /// while `previousModel` still records what the task had before.
    static func runtimeUpdate(
        previousRuntime: String?,
        selectedRuntime: String,
        currentModel: String,
        requestedModel: String? = nil,
        cache: RuntimeModelAvailabilityCache
    ) -> TaskComposerRuntimeUpdate {
        let resolvedRuntime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: selectedRuntime)
        let resolvedModel = RuntimeModelAvailability.modelForRuntimeSwitch(
            currentModel: requestedModel ?? currentModel,
            to: resolvedRuntime,
            cache: cache
        )
        return TaskComposerRuntimeUpdate(
            previousRuntime: previousRuntime,
            runtime: selectedRuntime,
            previousModel: currentModel,
            resolvedModel: resolvedModel
        )
    }

    /// Applies a user-driven runtime switch to `task` (composer picker or a
    /// dock action like "Switch to Codex CLI") and logs the same
    /// `task_runtime_changed` breadcrumb shape from both call sites, varying
    /// only by `source`. Marks `runtimeExplicitlySelected` so the launch
    /// resolver respects this pick instead of silently rerouting it away
    /// (see AgentRuntimeLaunchRuntimeResolver / TaskRuntimeCompatibilityService).
    @MainActor
    static func applyRuntimeSwitch(
        to runtime: String,
        requestedModel: String? = nil,
        task: AgentTask,
        cache: RuntimeModelAvailabilityCache,
        source: String
    ) {
        let update = runtimeUpdate(
            previousRuntime: task.runtimeID,
            selectedRuntime: runtime,
            currentModel: task.model,
            requestedModel: requestedModel,
            cache: cache
        )
        task.runtimeID = runtime
        task.runtimeExplicitlySelected = true
        task.model = update.resolvedModel
        task.updatedAt = Date()
        AppLogger.breadcrumb(action: "task_runtime_changed", category: "UI", taskID: task.id, fields: [
            "source": source,
            "previous_runtime": update.previousRuntime ?? "none",
            "runtime": update.runtime,
            "previous_model": update.previousModel,
            "model": update.resolvedModel,
            "model_changed": String(update.modelChanged),
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])
    }

    /// The decision dock's "Switch to …" for a policy-blocked task: the same
    /// acknowledgement gate as the composer, then `then` (the retry) only once
    /// the switch has actually been applied.
    @MainActor
    static func requestDockRuntimeSwitch(
        to runtime: String,
        task: AgentTask,
        cache: RuntimeModelAvailabilityCache,
        prompt: RuntimeSensitiveDataSwitchPrompt,
        then: @escaping () -> Void
    ) {
        let update = runtimeUpdate(
            previousRuntime: task.runtimeID,
            selectedRuntime: runtime,
            currentModel: task.model,
            requestedModel: nil,
            cache: cache
        )
        prompt.request(
            RuntimeSensitiveDataSwitchRequest(
                // Where the conversation last ran, not task.runtimeID: a
                // launch fallback may already have rewritten the latter to
                // the very runtime this switch is asking about.
                previous: RuntimeSensitiveDataLaunchGate.conversationRuntimeID(of: task)
                    .flatMap { AgentRuntimeID(rawValue: $0) }
                    ?? AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: task.runtimeID ?? AgentRuntimeID.claudeCode.rawValue),
                next: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtime),
                model: update.resolvedModel
            ),
            guard: sensitiveDataSwitchGuard(for: task)
        ) {
            applyRuntimeSwitch(
                to: runtime,
                requestedModel: update.resolvedModel,
                task: task,
                cache: cache,
                source: "policy_block_switch_action"
            )
            then()
        }
    }

    /// Guards runtime switches in an existing task's composer.
    static func sensitiveDataSwitchGuard(for task: AgentTask) -> RuntimeSensitiveDataSwitchGuard {
        RuntimeSensitiveDataSwitchGuard(
            hasConversation: { hasProviderConversation(task) },
            recordAcknowledgement: { previous, next, model in
                recordSensitiveDataRiskAcknowledgement(task: task, previous: previous, next: next, model: model)
            }
        )
    }

    /// Whether anything in this task has already gone to a provider. Runs are
    /// not the only way: Goal mode sends the planning conversation through
    /// `SpecEngine` and records it as plan events, with no run at all.
    static func hasProviderConversation(_ task: AgentTask) -> Bool {
        guard task.runs.isEmpty else { return true }
        return task.events.contains {
            $0.type == TaskPlanConversationEventTypes.userMessage
                || $0.type == TaskPlanConversationEventTypes.assistantMessage
        }
    }

    /// Recorded before the switch it allows, so the thread reads in order.
    static func recordSensitiveDataRiskAcknowledgement(
        task: AgentTask,
        previous: AgentRuntimeID,
        next: AgentRuntimeID,
        model: String
    ) {
        task.modelContext?.insert(sensitiveDataRiskAcknowledgementEvent(
            task: task,
            previous: previous,
            next: next,
            model: model
        ))
        AppLogger.breadcrumb(action: "task_sensitive_data_risk_acknowledged", category: "UI", taskID: task.id, fields: [
            "previous_runtime": previous.rawValue,
            "runtime": next.rawValue,
            "model": model,
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])
    }

    static func sensitiveDataRiskAcknowledgementEvent(
        task: AgentTask,
        previous: AgentRuntimeID,
        next: AgentRuntimeID,
        model: String
    ) -> TaskEvent {
        TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.System.sensitiveDataRiskAcknowledged,
            payload: RuntimeSensitiveDataRiskAcknowledgement(
                previousRuntimeID: previous.rawValue,
                runtimeID: next.rawValue,
                model: model
            )
        )
    }

    /// Combines a task/draft's already-persisted explicit-pick flag with the
    /// composer's session-scoped "did the user just touch the runtime picker"
    /// signal. Sticky-true: once either side has recorded an explicit pick, a
    /// later resync (e.g. ChatPanelView.saveDraft() copying the composer's
    /// live selection onto an already-created draft) must never clobber it
    /// back to false.
    static func explicitRuntimeSelection(existing: Bool, composerFlagged: Bool) -> Bool {
        existing || composerFlagged
    }
}
