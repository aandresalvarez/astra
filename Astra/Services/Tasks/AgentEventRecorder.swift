import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
final class AgentEventRecordingState {
    private let maxCoalescedPayloadLength: Int
    private var lastConversationEventByKey: [String: TaskEvent] = [:]
    /// Runs whose `run.output` was last written by a `.completed` summary.
    /// Providers like Codex emit several `agent_message` items per turn (progress
    /// notes first, the final answer last). Tracking this lets a later
    /// `.completed` replace an earlier one (last-completed-wins) while never
    /// clobbering output assembled from streamed `.text` deltas.
    private var runsWithCompletedOutput: Set<UUID> = []

    init(maxCoalescedPayloadLength: Int = TaskRunAnswerPresentationPolicy.conversationChunkCoalescingCap) {
        self.maxCoalescedPayloadLength = maxCoalescedPayloadLength
    }

    func markOutputFromCompletedSummary(for run: TaskRun) {
        runsWithCompletedOutput.insert(run.id)
    }

    /// Call when streamed `.text` deltas are appended to `run.output`: the output
    /// is now stream-assembled, so a later `.completed` envelope must not replace
    /// it even if an earlier `.completed` had seeded the output first.
    func clearOutputFromCompletedSummary(for run: TaskRun) {
        runsWithCompletedOutput.remove(run.id)
    }

    func outputCameFromCompletedSummary(for run: TaskRun) -> Bool {
        runsWithCompletedOutput.contains(run.id)
    }

    func appendConversationChunk(
        eventType: TaskEventType,
        text: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard !text.isEmpty else { return }
        let key = conversationKey(eventType: eventType, run: run)
        if let existing = lastConversationEventByKey[key],
           existing.payload.count + text.count <= maxCoalescedPayloadLength {
            existing.payload += text
            existing.timestamp = Date()
            return
        }

        let event = TaskEvent(task: task, eventType: eventType, payload: text, run: run)
        modelContext.insert(event)
        lastConversationEventByKey[key] = event
    }

    func breakConversationCoalescing(for run: TaskRun) {
        let prefix = "\(run.id.uuidString)#"
        lastConversationEventByKey = lastConversationEventByKey.filter { key, _ in
            !key.hasPrefix(prefix)
        }
    }

    private func conversationKey(eventType: TaskEventType, run: TaskRun) -> String {
        "\(run.id.uuidString)#\(eventType.rawValue)"
    }
}

enum AgentEventRecordingPresentation {
    static func normalizedPermissionTool(_ tool: String) -> String {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func responseTextToAppend(_ incomingText: String, after existingOutput: String) -> String {
        guard !incomingText.isEmpty else { return "" }
        guard !existingOutput.isEmpty else { return incomingText }
        if incomingText == existingOutput {
            return ""
        }
        if incomingText.count > existingOutput.count,
           incomingText.hasPrefix(existingOutput) {
            let suffixStart = incomingText.index(incomingText.startIndex, offsetBy: existingOutput.count)
            return String(incomingText[suffixStart...])
        }
        // Partial-message providers re-send the streamed text as one complete
        // envelope. Protocol-marker stripping can shift whitespace between the
        // two copies, so a whitespace-insensitive repeat of the whole output is
        // an echo of what the deltas already recorded, not new output.
        let normalizedIncoming = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExisting = existingOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedIncoming.isEmpty, normalizedExisting == normalizedIncoming {
            return ""
        }
        // Multi-message turns: a later message can land between an earlier
        // message's deltas and its envelope echo, so the echo is no longer the
        // output's tail — and the echo can concatenate segments that were
        // recorded as separate chunks, shifting interior whitespace. Compare
        // with all whitespace runs collapsed; a substantial chunk whose
        // collapsed text already appears in the collapsed output (tail or
        // interior) is an echo. The length floor keeps short legitimate
        // repeats ("Done.") appendable.
        let collapsedIncoming = whitespaceCollapsed(normalizedIncoming)
        if collapsedIncoming.count >= echoLengthFloor,
           whitespaceCollapsed(normalizedExisting).contains(collapsedIncoming) {
            return ""
        }
        return incomingText
    }

    private static let echoLengthFloor = 80

    private static func whitespaceCollapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func permissionReasonSummary(_ reason: String) -> String {
        let words = reason
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .prefix(18)
            .joined(separator: " ")
        return words.isEmpty ? "none" : words
    }

    static func toolUsePayload(name: String, input: [String: Any]?) -> String {
        let summary = toolInputSummary(name: name, input: input)
        let base = "Using tool: \(name)"
        guard let summary, !summary.isEmpty else { return base }
        return "\(base): \(LogSanitizer.sanitize(summary, maxLength: 300))"
    }

    static func visibleTextWithoutProtocolMarkers(_ text: String) -> String {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        var output = ""
        for item in pipeline.process(ParsedEvent.text(text: text)) + pipeline.flushParsedEvents() {
            if case .text(let text) = item {
                output += text
            }
        }
        return output
    }

    static func toolInputSummary(name: String, input: [String: Any]?) -> String? {
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
}

enum AgentEventRecorder {
    /// Claude previously recorded through two Claude-only dispatch functions
    /// (`recordClaudeRunEvent` for `.initial`, `recordClaudeFollowUpEvent` for
    /// `.followUp`) that switched on `ParsedEvent` directly, duplicating the
    /// same token-accounting/last-completed-wins/permission-logging logic
    /// `recordProviderAgentEvent` already implements for the other five
    /// runtimes. Claude now maps its stream to `AgentEvent` (see
    /// `agentEvents(from:)` below and `AgentRuntimeAdapter`'s
    /// `AgentRuntimeWorkerEventRecording` conformance) and shares this single
    /// dispatcher, so a future provider-parity fix only needs to land once.
    @MainActor
    static func recordClaudeEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingMode: AgentRuntimeRecordingMode = .initial,
        recordingState: AgentEventRecordingState? = nil
    ) {
        recordProviderAgentEvent(
            event,
            providerDisplayName: "Claude Code",
            permissionSource: recordingMode == .followUp ? "claude_follow_up" : "claude_stream",
            unknownEventName: "unknown_claude_stream_event",
            to: task,
            run: run,
            modelContext: modelContext,
            recordingMode: recordingMode,
            recordingState: recordingState
        )
    }

    @MainActor
    static func recordCopilotEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        recordProviderAgentEvent(
            event,
            providerDisplayName: "Copilot",
            permissionSource: "copilot_stream",
            unknownEventName: "unknown_copilot_stream_event",
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    @MainActor
    static func recordAntigravityEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        recordProviderAgentEvent(
            event,
            providerDisplayName: "Antigravity",
            permissionSource: "antigravity_stream",
            unknownEventName: "unknown_antigravity_stream_event",
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    @MainActor
    static func recordCodexEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingMode: AgentRuntimeRecordingMode = .initial,
        recordingState: AgentEventRecordingState? = nil
    ) {
        recordProviderAgentEvent(
            event,
            providerDisplayName: "Codex",
            permissionSource: "codex_stream",
            unknownEventName: "unknown_codex_stream_event",
            to: task,
            run: run,
            modelContext: modelContext,
            recordingMode: recordingMode,
            recordingState: recordingState
        )
    }

    @MainActor
    static func recordCursorEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        recordProviderAgentEvent(
            event,
            providerDisplayName: "Cursor",
            permissionSource: "cursor_stream",
            unknownEventName: "unknown_cursor_stream_event",
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    @MainActor
    static func recordOpenCodeEvent(
        _ event: AgentEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState? = nil
    ) {
        recordProviderAgentEvent(
            event,
            providerDisplayName: "OpenCode",
            permissionSource: "opencode_stream",
            unknownEventName: "unknown_opencode_stream_event",
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    @MainActor
    private static func recordProviderAgentEvent(
        _ event: AgentEvent,
        providerDisplayName: String,
        permissionSource: String,
        unknownEventName: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingMode: AgentRuntimeRecordingMode = .initial,
        recordingState: AgentEventRecordingState? = nil
    ) {
        switch event {
        case .control:
            break

        case .started(let sessionID, let model):
            recordingState?.breakConversationCoalescing(for: run)
            if let sessionID {
                task.sessionId = sessionID
                run.providerSessionId = sessionID
                AppLogger.audit(.workerSessionStarted, category: "Worker", taskID: task.id, fields: [
                    "session_id_prefix": String(sessionID.prefix(8))
                ], level: .debug)
            }
            let payload = model.map { "\(providerDisplayName) stream started with model \($0)." }
                ?? "\(providerDisplayName) stream started."
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.started, payload: payload, run: run))
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "stream": "started",
                "model": model ?? "unknown"
            ])

        case .thinking(let text):
            appendConversationChunk(
                eventType: TaskEventTypes.Conversation.agentThinking,
                text: text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )

        case .text(let text):
            appendResponseText(
                text,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )

        case .toolUse(let name, _, let inputSummary):
            recordingState?.breakConversationCoalescing(for: run)
            let suffix = inputSummary.map { ": \($0.prefix(300))" } ?? ""
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Using tool: \(name)\(suffix)", run: run))

        case .toolResult(_, let content):
            recordingState?.breakConversationCoalescing(for: run)
            if !content.isEmpty {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.result, payload: String(content.prefix(10000)), run: run))
            }

        case .fileChange(let path, let kind, let summary, let oldString, let newString):
            recordingState?.breakConversationCoalescing(for: run)
            appendFileChange(
                path: path,
                kind: kind,
                summary: summary,
                oldString: oldString,
                newString: newString,
                task: task,
                run: run,
                modelContext: modelContext
            )

        case .teamEvent(let teamEvent):
            recordingState?.breakConversationCoalescing(for: run)
            recordTeamEvent(teamEvent, to: task, run: run, modelContext: modelContext)

        case .permissionRequested(let tool, let reason):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionDenied, payload: "Permission requested for tool: \(tool). \(String(reason.prefix(300)))", run: run))
            AppLogger.audit(.workerPermissionDenied, category: "Worker", taskID: task.id, fields: [
                "tool": AgentEventRecordingPresentation.normalizedPermissionTool(tool),
                "reason_summary": AgentEventRecordingPresentation.permissionReasonSummary(reason),
                "source": permissionSource
            ], level: .warning)

        case .stats(let input, let output, let cost, let duration, let turns):
            recordingState?.breakConversationCoalescing(for: run)
            let total = input + output
            if total > 0 {
                recordUsageTotals(
                    inputTokens: input,
                    outputTokens: output,
                    to: task,
                    run: run,
                    recordingMode: recordingMode
                )
            }
            if let cost {
                switch recordingMode {
                case .initial:
                    task.costUSD = cost
                case .followUp:
                    task.costUSD += cost
                }
                run.costUSD = cost
            }
            let details = [
                total > 0 ? "tokens: \(total) (in: \(input), out: \(output))" : nil,
                cost.map { String(format: "cost: $%.4f", $0) },
                duration.map { "duration: \($0)ms" },
                turns.map { "turns: \($0)" }
            ].compactMap { $0 }.joined(separator: " | ")
            if !details.isEmpty {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.stats, payload: details, run: run))
                AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                    "tokens_total": String(total),
                    "tokens_input": String(input),
                    "tokens_output": String(output),
                    "turns": turns.map(String.init) ?? "unknown",
                    "duration_ms": duration.map(String.init) ?? "unknown",
                    "has_error": "false"
                ])
            }

        case .completed(let summary):
            recordingState?.breakConversationCoalescing(for: run)
            if let summary {
                recordCompletedOutput(
                    summary,
                    to: run,
                    recordingState: recordingState
                )
            }

        case .astraProtocol(let event):
            recordingState?.breakConversationCoalescing(for: run)
            recordAstraProtocol(event, to: task, run: run, modelContext: modelContext)

        case .failed(let message):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: message, run: run))
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "agent_reported_error"
            ], level: .warning)

        case .unknown(_, let type, _):
            recordingState?.breakConversationCoalescing(for: run)
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "event": unknownEventName,
                "event_type": type
            ], level: .debug)
        }
    }

    static func parsedEvent(from event: AgentEvent) -> ParsedEvent? {
        switch event {
        case .control:
            return nil
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
        case .fileChange(let path, let kind, let summary, let oldString, let newString):
            let toolName = kind.lowercased().contains("write") ? "Write" : "Edit"
            var input: [String: Any] = ["file_path": path]
            if let summary, !summary.isEmpty {
                input["summary"] = summary
            }
            if let oldString {
                input["old_string"] = oldString
            }
            if let newString {
                input["new_string"] = newString
            }
            return .toolUse(name: toolName, id: "", input: input)
        case .teamEvent(let teamEvent):
            return parsedEvent(from: teamEvent)
        case .unknown:
            return nil
        }
    }

    /// Maps Claude's `ParsedEvent` stream onto the shared `AgentEvent` model so
    /// Claude can record through the same `recordProviderAgentEvent` dispatcher
    /// as the other five runtimes, instead of a Claude-only recording function.
    ///
    /// `Write`/`Edit` tool uses become `.fileChange` (preserving the precise
    /// `old_string`/`new_string` diff Claude's structured tool input carries,
    /// which the generic `.toolUse` case cannot represent) while every other
    /// tool use becomes `.toolUse` with the same smart input summary
    /// (`AgentEventRecordingPresentation.toolInputSummary`) Claude's own
    /// recorder already used, so recorded payload text is unchanged. `.result`
    /// can produce two events (`.completed` for the transcript text plus
    /// `.stats` for token/cost accounting), mirroring how Copilot/Cursor/
    /// OpenCode already split their terminal result envelope.
    static func agentEvents(from parsed: ParsedEvent) -> [AgentEvent] {
        switch parsed {
        case .systemInit(let model, let sessionId):
            return [.started(sessionID: sessionId, model: model)]
        case .thinking(let text):
            return [.thinking(text: text)]
        case .text(let text):
            return [.text(text: text)]
        case .toolUse(let name, let id, let input):
            let inputSummary = AgentEventRecordingPresentation.toolInputSummary(name: name, input: input)
            if let fileChange = StreamEventParser.extractFileChange(from: parsed) {
                // The pre-convergence Claude recorder always logged the tool
                // invocation itself before recording the file change; the
                // shared file-change path only appends the artifact, so both
                // events are needed to keep the transcript/audit trail intact.
                return [
                    .toolUse(name: name, id: id, inputSummary: inputSummary),
                    .fileChange(
                        path: fileChange.path,
                        kind: fileChange.changeType.rawValue,
                        summary: fileChange.content,
                        oldString: fileChange.oldString,
                        newString: fileChange.newString
                    )
                ]
            }
            return [.toolUse(name: name, id: id, inputSummary: inputSummary)]
        case .toolResult(let toolId, let content):
            return [.toolResult(id: toolId, content: content)]
        case .usage(let totalInput, let totalOutput):
            return [.stats(inputTokens: totalInput, outputTokens: totalOutput, costUSD: nil, durationMs: nil, turns: nil)]
        case .result(let text, let costUSD, let totalInput, let totalOutput, let durationMs, let numTurns, let isError):
            var events: [AgentEvent] = []
            if let text, !text.isEmpty {
                events.append(.completed(summary: text))
            }
            if isError {
                events.append(.failed(message: text ?? "Claude Code run failed."))
            }
            // A `.result` event always carries the authoritative final totals
            // (even when zero) regardless of isError, so it must reach
            // `recordProviderAgentEvent` as `.stats` unconditionally rather
            // than only on the success path, unlike other providers'
            // best-effort stats extraction — a failed run still spent tokens.
            events.append(.stats(inputTokens: totalInput, outputTokens: totalOutput, costUSD: costUSD, durationMs: durationMs, turns: numTurns))
            return events
        case .permissionDenied(let tool, let reason):
            return [.permissionRequested(tool: tool, reason: reason)]
        case .astraProtocol(let event):
            return [.astraProtocol(event)]
        case .teammateStarted(let taskId, let name, let prompt):
            return [.teamEvent(.teammateStarted(taskId: taskId, name: name, prompt: prompt))]
        case .teammateCompleted(let taskId, let name):
            return [.teamEvent(.teammateCompleted(taskId: taskId, name: name))]
        case .teamCreated(let name, let description):
            return [.teamEvent(.teamCreated(name: name, description: description))]
        case .teamDeleted(let name):
            return [.teamEvent(.teamDeleted(name: name))]
        case .teamMessage(let from, let to, let content):
            return [.teamEvent(.teamMessage(from: from, to: to, content: content))]
        case .unknown(let type):
            return [.unknown(provider: "claude_code", type: type, raw: "")]
        }
    }

    private static func parsedEvent(from teamEvent: AgentTeamEvent) -> ParsedEvent {
        switch teamEvent {
        case .teammateStarted(let taskId, let name, let prompt):
            return .teammateStarted(taskId: taskId, name: name, prompt: prompt)
        case .teammateCompleted(let taskId, let name):
            return .teammateCompleted(taskId: taskId, name: name)
        case .teamCreated(let name, let description):
            return .teamCreated(name: name, description: description)
        case .teamDeleted(let name):
            return .teamDeleted(name: name)
        case .teamMessage(let from, let to, let content):
            return .teamMessage(from: from, to: to, content: content)
        }
    }

    @MainActor
    private static func recordUsageTotals(
        inputTokens: Int,
        outputTokens: Int,
        to task: AgentTask,
        run: TaskRun,
        recordingMode: AgentRuntimeRecordingMode
    ) {
        let totalTokens = inputTokens + outputTokens
        switch recordingMode {
        case .initial:
            task.tokensUsed = totalTokens
            run.tokensUsed = totalTokens
            run.inputTokens = inputTokens
            run.outputTokens = outputTokens
        case .followUp:
            let previousRunTokens = run.tokensUsed
            run.tokensUsed = max(run.tokensUsed, totalTokens)
            run.inputTokens = max(run.inputTokens, inputTokens)
            run.outputTokens = max(run.outputTokens, outputTokens)
            task.tokensUsed += max(0, run.tokensUsed - previousRunTokens)
        }
    }

    @MainActor
    private static func recordCompletedOutput(
        _ summary: String,
        to run: TaskRun,
        recordingState: AgentEventRecordingState?
    ) {
        let visibleText = AgentEventRecordingPresentation.visibleTextWithoutProtocolMarkers(summary)
        let mayReplace = run.output.isEmpty
            || (recordingState?.outputCameFromCompletedSummary(for: run) ?? false)
        if !visibleText.isEmpty, mayReplace {
            run.output = visibleText
            recordingState?.markOutputFromCompletedSummary(for: run)
        }
    }

    @MainActor
    private static func appendResponseText(
        _ text: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState?
    ) {
        let textToAppend = AgentEventRecordingPresentation.responseTextToAppend(text, after: run.output)
        guard !textToAppend.isEmpty else { return }
        run.output += textToAppend
        // Output now contains streamed deltas; a later `.completed` envelope must
        // not clobber it even if an earlier `.completed` seeded the output.
        recordingState?.clearOutputFromCompletedSummary(for: run)
        appendConversationChunk(
            eventType: TaskEventTypes.Conversation.agentResponse,
            text: textToAppend,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    @MainActor
    private static func appendConversationChunk(
        eventType: TaskEventType,
        text: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState?
    ) {
        if let recordingState {
            recordingState.appendConversationChunk(
                eventType: eventType,
                text: text,
                to: task,
                run: run,
                modelContext: modelContext
            )
        } else {
            modelContext.insert(TaskEvent(task: task, eventType: eventType, payload: text, run: run))
        }
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

    @MainActor
    private static func appendFileChange(
        path: String,
        kind: String,
        summary: String?,
        oldString: String? = nil,
        newString: String? = nil,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard !path.isEmpty else { return }
        let changeType: FileChange.FileChangeType = kind.lowercased().contains("write") ? .write : .edit
        // A precise before/after diff (Claude's `Edit` tool) takes precedence
        // over the plain-text summary other providers fall back to.
        let hasDiff = oldString != nil || newString != nil
        // Providers without a diff can resend the same notification for one
        // edit, so those dedupe by path. A diff uniquely identifies a
        // distinct edit, so every one of Claude's own diffs is preserved even
        // when it repeats a path already recorded this run.
        guard hasDiff || !run.fileChanges.contains(where: { $0.path == path }) else { return }
        let change = FileChange(
            path: path,
            changeType: changeType,
            content: hasDiff ? nil : summary,
            oldString: hasDiff ? oldString : nil,
            newString: hasDiff ? newString : nil,
            timestamp: Date()
        )
        let storedChange = StoredFileChange(from: change)
        run.appendFileChange(storedChange)
        TaskArtifactPersistenceService.persistFileChangeArtifact(storedChange, for: task, modelContext: modelContext)
    }

    @MainActor
    private static func recordTeamEvent(
        _ event: AgentTeamEvent,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        switch event {
        case .teammateStarted(let taskId, let name, let prompt):
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Team.agentStarted,
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
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Team.agentCompleted,
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
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Team.created, payload: "Team '\(name)' created: \(description)", run: run, teamName: name))
            AppLogger.audit(.workerStarted, category: "Worker", taskID: task.id, fields: [
                "team_event": "team_created"
            ])

        case .teamDeleted(let name):
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Team.deleted, payload: "Team '\(name)' disbanded", run: run, teamName: name))
            AppLogger.audit(.taskCompleted, category: "Worker", taskID: task.id, fields: [
                "team_event": "team_deleted"
            ])

        case .teamMessage(let from, let to, let content):
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Team.message, payload: content, run: run, agentName: from, agentId: to))
        }
    }
}
