import Foundation
import SwiftData
import ASTRACore

@MainActor
final class AgentEventRecordingState {
    private let maxCoalescedPayloadLength: Int
    private var lastConversationEventByKey: [String: TaskEvent] = [:]

    init(maxCoalescedPayloadLength: Int = 4_096) {
        self.maxCoalescedPayloadLength = maxCoalescedPayloadLength
    }

    func appendConversationChunk(
        type: String,
        text: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard !text.isEmpty else { return }
        let key = conversationKey(type: type, run: run)
        if let existing = lastConversationEventByKey[key],
           existing.payload.count + text.count <= maxCoalescedPayloadLength {
            existing.payload += text
            existing.timestamp = Date()
            return
        }

        let event = TaskEvent(task: task, type: type, payload: text, run: run)
        modelContext.insert(event)
        lastConversationEventByKey[key] = event
    }

    func breakConversationCoalescing(for run: TaskRun) {
        let prefix = "\(run.id.uuidString)#"
        lastConversationEventByKey = lastConversationEventByKey.filter { key, _ in
            !key.hasPrefix(prefix)
        }
    }

    private func conversationKey(type: String, run: TaskRun) -> String {
        "\(run.id.uuidString)#\(type)"
    }
}

enum AgentEventRecorder {
    @MainActor
    static func recordClaudeRunEvent(
        _ parsed: ParsedEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        switch parsed {
        case .thinking(let text):
            appendConversationChunk(
                type: "agent.thinking",
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )

        case .text(let text):
            run.output += text
            appendConversationChunk(
                type: "agent.response",
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )

        case .toolUse(let name, _, let input):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(
                task: task,
                type: "tool.use",
                payload: toolUsePayload(name: name, input: input),
                run: run
            ))
            if let fileChange = StreamEventParser.extractFileChange(from: parsed) {
                run.appendFileChange(StoredFileChange(from: fileChange))
                let existingVersion = task.artifacts
                    .filter { $0.path == fileChange.path }
                    .map(\.version)
                    .max() ?? 0
                modelContext.insert(Artifact(
                    task: task,
                    type: fileChange.changeType.rawValue,
                    path: fileChange.path,
                    version: existingVersion + 1
                ))
            }

        case .toolResult(_, let content):
            recordingState?.breakConversationCoalescing(for: run)
            if !content.isEmpty {
                modelContext.insert(TaskEvent(task: task, type: "tool.result", payload: String(content.prefix(10000)), run: run))
            }

        case .usage(let totalInput, let totalOutput):
            let totalTokens = totalInput + totalOutput
            if totalTokens > 0 {
                task.tokensUsed = max(task.tokensUsed, totalTokens)
                run.tokensUsed = max(run.tokensUsed, totalTokens)
                run.inputTokens = max(run.inputTokens, totalInput)
                run.outputTokens = max(run.outputTokens, totalOutput)
            }

        case .result(let text, let costUSD, let totalInput, let totalOutput, let durationMs, let numTurns, let isError):
            recordingState?.breakConversationCoalescing(for: run)
            let totalTokens = totalInput + totalOutput
            task.tokensUsed = totalTokens
            run.tokensUsed = totalTokens
            run.inputTokens = totalInput
            run.outputTokens = totalOutput

            if let cost = costUSD {
                task.costUSD = cost
                run.costUSD = cost
            }
            if let text, run.output.isEmpty {
                let visibleText = visibleTextWithoutProtocolMarkers(text)
                if !visibleText.isEmpty {
                    run.output = visibleText
                }
            }

            let details = [
                "tokens: \(totalTokens) (in: \(totalInput), out: \(totalOutput))",
                costUSD.map { String(format: "cost: $%.4f", $0) },
                durationMs.map { "duration: \($0)ms" },
                numTurns.map { "turns: \($0)" }
            ].compactMap { $0 }.joined(separator: " | ")
            modelContext.insert(TaskEvent(task: task, type: "task.stats", payload: details, run: run))

            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "tokens_total": String(totalTokens),
                "tokens_input": String(totalInput),
                "tokens_output": String(totalOutput),
                "turns": numTurns.map(String.init) ?? "unknown",
                "duration_ms": durationMs.map(String.init) ?? "unknown",
                "has_error": String(isError)
            ])
            if isError {
                AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                    "reason": "agent_reported_error"
                ], level: .warning)
            }

        case .systemInit(let model, let sessionId):
            recordingState?.breakConversationCoalescing(for: run)
            if let sessionId {
                task.sessionId = sessionId
                run.providerSessionId = sessionId
                AppLogger.audit(.workerSessionStarted, category: "Worker", taskID: task.id, fields: [
                    "session_id_prefix": String(sessionId.prefix(8))
                ], level: .debug)
            }
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "stream": "started",
                "model": model ?? "unknown"
            ])

        case .teammateStarted(let taskId, let name, let prompt):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(
                task: task,
                type: "team.agent.started",
                payload: "\(name) spawned: \(String(prompt.prefix(200)))",
                run: run,
                agentName: name,
                agentId: taskId
            ))
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "team_event": "teammate_started",
                "agent_id": taskId
            ])

        case .teammateCompleted(let taskId, let name):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(
                task: task,
                type: "team.agent.completed",
                payload: "\(name) finished",
                run: run,
                agentName: name,
                agentId: taskId
            ))
            AppLogger.audit(.taskCompleted, category: "Worker", taskID: task.id, fields: [
                "team_event": "teammate_completed",
                "agent_id": taskId
            ])

        case .teamCreated(let name, let description):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "team.created", payload: "Team '\(name)' created: \(description)", run: run, teamName: name))
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "team_event": "team_created"
            ])

        case .teamDeleted(let name):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "team.deleted", payload: "Team '\(name)' disbanded", run: run, teamName: name))
            AppLogger.audit(.taskCompleted, category: "Worker", taskID: task.id, fields: [
                "team_event": "team_deleted"
            ])

        case .teamMessage(let from, let to, let content):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "team.message", payload: content, run: run, agentName: from, agentId: to))

        case .permissionDenied(let tool, let reason):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "permission.denied", payload: "Permission denied for tool: \(tool). \(String(reason.prefix(300)))", run: run))
            AppLogger.audit(.workerPermissionDenied, category: "Worker", taskID: task.id, fields: [
                "tool": normalizedPermissionTool(tool),
                "reason_summary": permissionReasonSummary(reason),
                "source": "claude_stream"
            ], level: .warning)

        case .astraProtocol(let event):
            recordingState?.breakConversationCoalescing(for: run)
            recordAstraProtocol(event, to: task, run: run, modelContext: modelContext)

        case .unknown(let type):
            recordingState?.breakConversationCoalescing(for: run)
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "event": "unknown_stream_event",
                "event_type": type
            ], level: .debug)
        }
    }

    @MainActor
    static func recordClaudeFollowUpEvent(
        _ parsed: ParsedEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        switch parsed {
        case .thinking(let text):
            appendConversationChunk(
                type: "agent.thinking",
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .text(let text):
            run.output += text
            appendConversationChunk(
                type: "agent.response",
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .toolUse(let name, _, let input):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(
                task: task,
                type: "tool.use",
                payload: toolUsePayload(name: name, input: input),
                run: run
            ))
            if let fileChange = StreamEventParser.extractFileChange(from: parsed) {
                run.appendFileChange(StoredFileChange(from: fileChange))
            }
        case .usage(let totalInput, let totalOutput):
            let totalTokens = totalInput + totalOutput
            if totalTokens > 0 {
                let previousRunTokens = run.tokensUsed
                run.tokensUsed = max(run.tokensUsed, totalTokens)
                run.inputTokens = max(run.inputTokens, totalInput)
                run.outputTokens = max(run.outputTokens, totalOutput)
                task.tokensUsed += max(0, run.tokensUsed - previousRunTokens)
            }
        case .result(_, let costUSD, let totalInput, let totalOutput, _, _, _):
            recordingState?.breakConversationCoalescing(for: run)
            let totalTokens = totalInput + totalOutput
            let previousRunTokens = run.tokensUsed
            task.tokensUsed += max(0, totalTokens - previousRunTokens)
            run.tokensUsed = totalTokens
            run.inputTokens = totalInput
            run.outputTokens = totalOutput
            if let cost = costUSD {
                task.costUSD += cost
                run.costUSD = cost
            }
        case .systemInit(_, let sessionId):
            recordingState?.breakConversationCoalescing(for: run)
            if let sessionId {
                task.sessionId = sessionId
                run.providerSessionId = sessionId
            }
        case .toolResult(_, let content):
            recordingState?.breakConversationCoalescing(for: run)
            if !content.isEmpty {
                modelContext.insert(TaskEvent(task: task, type: "tool.result", payload: String(content.prefix(10000)), run: run))
            }
        case .permissionDenied(let tool, let reason):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "permission.denied", payload: "Permission denied for tool: \(tool). \(String(reason.prefix(300)))", run: run))
            AppLogger.audit(.workerPermissionDenied, category: "Worker", taskID: task.id, fields: [
                "tool": normalizedPermissionTool(tool),
                "reason_summary": permissionReasonSummary(reason),
                "source": "claude_follow_up"
            ], level: .warning)
        case .astraProtocol(let event):
            recordingState?.breakConversationCoalescing(for: run)
            recordAstraProtocol(event, to: task, run: run, modelContext: modelContext)
        default:
            recordingState?.breakConversationCoalescing(for: run)
            break
        }
    }

    @MainActor
    static func recordCopilotEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        switch event {
        case .started(let sessionID, let model):
            recordingState?.breakConversationCoalescing(for: run)
            if let sessionID {
                task.sessionId = sessionID
                run.providerSessionId = sessionID
            }
            let payload = model.map { "Copilot stream started with model \($0)." } ?? "Copilot stream started."
            modelContext.insert(TaskEvent(task: task, type: "task.started", payload: payload, run: run))

        case .thinking(let text):
            appendConversationChunk(
                type: "agent.thinking",
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )

        case .text(let text):
            run.output += text
            appendConversationChunk(
                type: "agent.response",
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )

        case .toolUse(let name, _, let inputSummary):
            recordingState?.breakConversationCoalescing(for: run)
            let suffix = inputSummary.map { ": \($0.prefix(300))" } ?? ""
            modelContext.insert(TaskEvent(task: task, type: "tool.use", payload: "Using tool: \(name)\(suffix)", run: run))

        case .toolResult(_, let content):
            recordingState?.breakConversationCoalescing(for: run)
            if !content.isEmpty {
                modelContext.insert(TaskEvent(task: task, type: "tool.result", payload: String(content.prefix(10000)), run: run))
            }

        case .fileChange(let path, let kind, let summary):
            recordingState?.breakConversationCoalescing(for: run)
            appendFileChange(path: path, kind: kind, summary: summary, task: task, run: run, modelContext: modelContext)

        case .permissionRequested(let tool, let reason):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "permission.denied", payload: "Permission requested for tool: \(tool). \(String(reason.prefix(300)))", run: run))
            AppLogger.audit(.workerPermissionDenied, category: "Worker", taskID: task.id, fields: [
                "tool": normalizedPermissionTool(tool),
                "reason_summary": permissionReasonSummary(reason),
                "source": "copilot_stream"
            ], level: .warning)

        case .stats(let input, let output, let cost, let duration, let turns):
            recordingState?.breakConversationCoalescing(for: run)
            let total = input + output
            if total > 0 {
                task.tokensUsed = total
                run.tokensUsed = total
                run.inputTokens = input
                run.outputTokens = output
            }
            if let cost {
                task.costUSD = cost
                run.costUSD = cost
            }
            let details = [
                total > 0 ? "tokens: \(total) (in: \(input), out: \(output))" : nil,
                cost.map { String(format: "cost: $%.4f", $0) },
                duration.map { "duration: \($0)ms" },
                turns.map { "turns: \($0)" }
            ].compactMap { $0 }.joined(separator: " | ")
            if !details.isEmpty {
                modelContext.insert(TaskEvent(task: task, type: "task.stats", payload: details, run: run))
            }

        case .completed(let summary):
            recordingState?.breakConversationCoalescing(for: run)
            if let summary, run.output.isEmpty {
                let visibleText = visibleTextWithoutProtocolMarkers(summary)
                if !visibleText.isEmpty {
                    run.output = visibleText
                }
            }

        case .astraProtocol(let event):
            recordingState?.breakConversationCoalescing(for: run)
            recordAstraProtocol(event, to: task, run: run, modelContext: modelContext)

        case .failed(let message):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, type: "error", payload: message, run: run))

        case .unknown(_, let type, _):
            recordingState?.breakConversationCoalescing(for: run)
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "event": "unknown_copilot_stream_event",
                "event_type": type
            ], level: .debug)
        }
    }

    static func parsedEvent(from event: AgentEvent) -> ParsedEvent? {
        switch event {
        case .started(let sessionID, let model):
            return .systemInit(model: model, sessionId: sessionID)
        case .thinking(let text):
            return .thinking(text: text)
        case .text(let text):
            return .text(text: text)
        case .toolUse(let name, let id, let inputSummary):
            let input: [String: Any]? = inputSummary.map { ["summary": $0] }
            return .toolUse(name: name, id: id, input: input)
        case .toolResult(let id, let content):
            return .toolResult(toolId: id, content: content)
        case .permissionRequested(let tool, let reason):
            return .permissionDenied(tool: tool, reason: reason)
        case .stats(let input, let output, let cost, let duration, let turns):
            return .result(text: nil, costUSD: cost, totalInputTokens: input, totalOutputTokens: output, durationMs: duration, numTurns: turns, isError: false)
        case .astraProtocol(let event):
            return .astraProtocol(event)
        case .completed(let summary):
            return .result(text: summary, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: false)
        case .failed(let message):
            return .result(text: message, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: true)
        case .fileChange(let path, let kind, let summary):
            let toolName = kind.lowercased().contains("write") ? "Write" : "Edit"
            var input: [String: Any] = ["file_path": path]
            if let summary, !summary.isEmpty {
                input["summary"] = summary
            }
            return .toolUse(name: toolName, id: "", input: input)
        case .unknown:
            return nil
        }
    }

    private static func normalizedPermissionTool(_ tool: String) -> String {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    @MainActor
    private static func appendConversationChunk(
        type: String,
        text: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState?
    ) {
        if let recordingState {
            recordingState.appendConversationChunk(
                type: type,
                text: text,
                to: task,
                run: run,
                modelContext: modelContext
            )
        } else {
            modelContext.insert(TaskEvent(task: task, type: type, payload: text, run: run))
        }
    }

    private static func permissionReasonSummary(_ reason: String) -> String {
        let words = reason
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .prefix(18)
            .joined(separator: " ")
        return words.isEmpty ? "none" : words
    }

    private static func toolUsePayload(name: String, input: [String: Any]?) -> String {
        let summary = toolInputSummary(name: name, input: input)
        let base = "Using tool: \(name)"
        guard let summary, !summary.isEmpty else { return base }
        return "\(base): \(LogSanitizer.sanitize(summary, maxLength: 300))"
    }

    private static func toolInputSummary(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "bash" || lower == "shell" {
            return firstString(in: input, keys: ["command", "cmd", "summary"])
        }
        if ["read", "write", "edit", "multiedit"].contains(lower) {
            return firstString(in: input, keys: ["file_path", "path", "target_path", "summary"])
        }
        if ["webfetch", "websearch"].contains(lower) {
            return firstString(in: input, keys: ["url", "uri", "summary"])
        }
        return firstString(in: input, keys: ["summary"])
    }

    private static func firstString(in input: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = input[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    @MainActor
    private static func recordAstraProtocol(
        _ event: AstraRunProtocolParsedEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        if case .valid(.planStep(let progress)) = event,
           let planID = progress.planID.flatMap(UUID.init(uuidString:)) ?? TaskPlanService.reconstruct(for: task).plan?.planID,
           let status = TaskPlanPayloadStepStatus(rawValue: progress.status.rawValue) {
            TaskPlanService.recordStepProgress(
                type: progress.type,
                planID: planID,
                stepID: progress.stepID,
                status: status,
                task: task,
                modelContext: modelContext,
                run: run,
                title: progress.title,
                detail: progress.detail,
                summary: progress.summary,
                reason: progress.reason
            )
            return
        }

        modelContext.insert(TaskEvent(
            task: task,
            type: event.taskEventType,
            payload: event.normalizedPayload,
            run: run
        ))
    }

    private static func visibleTextWithoutProtocolMarkers(_ text: String) -> String {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        var output = ""
        for item in pipeline.process(ParsedEvent.text(text: text)) + pipeline.flushParsedEvents() {
            if case .text(let text) = item {
                output += text
            }
        }
        return output
    }

    @MainActor
    private static func appendFileChange(
        path: String,
        kind: String,
        summary: String?,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard !path.isEmpty else { return }
        guard !run.fileChanges.contains(where: { $0.path == path }) else { return }
        let changeType: FileChange.FileChangeType = kind.lowercased().contains("write") ? .write : .edit
        let change = FileChange(
            path: path,
            changeType: changeType,
            content: summary,
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )
        run.appendFileChange(StoredFileChange(from: change))
        let existingVersion = task.artifacts
            .filter { $0.path == path }
            .map(\.version)
            .max() ?? 0
        modelContext.insert(Artifact(task: task, type: changeType.rawValue, path: path, content: summary, version: existingVersion + 1))
    }
}
