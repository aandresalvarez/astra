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

        var message = messageText
        if !attachedFiles.isEmpty {
            let fileList = attachedFiles.map { "- \($0)" }.joined(separator: "\n")
            message += "\n\nAttached files:\n\(fileList)"
        }
        return .message(message)
    }

    static func runtimeUpdate(
        previousRuntime: String?,
        selectedRuntime: String,
        currentModel: String,
        cache: RuntimeModelAvailabilityCache
    ) -> TaskComposerRuntimeUpdate {
        let resolvedRuntime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: selectedRuntime)
        let resolvedModel = RuntimeModelAvailability.modelForRuntimeSwitch(
            currentModel: currentModel,
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
        task: AgentTask,
        cache: RuntimeModelAvailabilityCache,
        source: String
    ) {
        let update = runtimeUpdate(
            previousRuntime: task.runtimeID,
            selectedRuntime: runtime,
            currentModel: task.model,
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
