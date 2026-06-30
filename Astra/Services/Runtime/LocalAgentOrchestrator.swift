import Foundation
import SwiftData
import ASTRACore

struct LocalAgentModelTurnResult: Sendable {
    var exitCode: Int
    var text: String
    var error: String?
    var inputTokens: Int
    var outputTokens: Int
    var durationMs: Int?
    var benchmark: LocalAgentInferenceBenchmark
    var events: [AgentEvent]
    var timedOut: Bool
}

struct LocalAgentInferenceBenchmark: Sendable, Equatable {
    var helperDurationMs: Int?
    var firstTokenLatencyMs: Int?
    var tokensPerSecond: Double?
    var promptTokensPerSecond: Double?
    var modelLoadMs: Int?
    var activeMemoryBytes: Int?
    var peakMemoryBytes: Int?
    var cacheMemoryBytes: Int?
    var memoryLimitBytes: Int?
    var cacheLimitBytes: Int?
    var memoryBudgetBytes: Int?

    var hasValues: Bool {
        helperDurationMs != nil
            || firstTokenLatencyMs != nil
            || tokensPerSecond != nil
            || promptTokensPerSecond != nil
            || modelLoadMs != nil
            || activeMemoryBytes != nil
            || peakMemoryBytes != nil
            || cacheMemoryBytes != nil
            || memoryLimitBytes != nil
            || cacheLimitBytes != nil
            || memoryBudgetBytes != nil
    }
}

enum LocalAgentPromptModelFamily: String, Sendable, Equatable {
    case qwen
    case llama
    case generic
}

struct LocalAgentPromptAdapter: Sendable, Equatable {
    var family: LocalAgentPromptModelFamily
    var source: String
    var validatedModelType: String?
    var requiresValidatedModelFolder: Bool

    static func adapter(model: String, modelDirectory: String) -> LocalAgentPromptAdapter {
        let trimmedDirectory = modelDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDirectory.isEmpty {
            let report = LocalModelCatalog.validate(directory: trimmedDirectory)
            if report.state == .ready, let metadata = report.metadata {
                return adapter(modelType: metadata.modelType, source: "model-folder", validatedModelType: metadata.modelType)
            }
        }
        return adapter(modelType: model, source: "model-id", validatedModelType: nil)
    }

    static func initialMessages(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        modelDirectory: String
    ) -> [LocalModelChatMessage] {
        let adapter = adapter(model: model, modelDirectory: modelDirectory)
        return [
            LocalModelChatMessage(role: "system", content: adapter.systemPrompt(base: systemPrompt)),
            LocalModelChatMessage(role: "user", content: adapter.userPrompt(base: userPrompt))
        ]
    }

    private static func adapter(
        modelType rawValue: String,
        source: String,
        validatedModelType: String?
    ) -> LocalAgentPromptAdapter {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let family: LocalAgentPromptModelFamily
        if normalized.contains("qwen") {
            family = .qwen
        } else if normalized.contains("llama") {
            family = .llama
        } else {
            family = .generic
        }
        return LocalAgentPromptAdapter(
            family: family,
            source: source,
            validatedModelType: validatedModelType,
            requiresValidatedModelFolder: family == .llama
        )
    }

    private func systemPrompt(base: String) -> String {
        [
            base,
            modelFamilyAddendum
        ].joined(separator: "\n\n")
    }

    private func userPrompt(base: String) -> String {
        guard family == .qwen else { return base }
        let lowercased = base.lowercased()
        guard !lowercased.contains("/no_think"),
              !lowercased.contains("/think") else {
            return base
        }
        return base + "\n\n/no_think"
    }

    private var modelFamilyAddendum: String {
        let validationLine = validatedModelType.map {
            "Validated model_type: \($0)."
        } ?? "Model family inferred from configured model ID; selected model folder readiness remains authoritative."
        switch family {
        case .qwen:
            return """
            Local Agent model adapter: Qwen.
            \(validationLine)
            Use the model's chat template through MLX. Keep thinking disabled with /no_think and return exactly one JSON action object.
            """
        case .llama:
            return """
            Local Agent model adapter: Llama.
            \(validationLine)
            Use concise instruction-following behavior and return exactly one JSON action object; do not add markdown or conversational prefaces.
            """
        case .generic:
            return """
            Local Agent model adapter: Generic MLX text model.
            \(validationLine)
            Return exactly one JSON action object; do not add markdown or conversational prefaces.
            """
        }
    }
}

struct LocalAgentRuntimeControls: Sendable, Equatable {
    var maxTurns: Int
    var maxToolCalls: Int
    var toolTimeoutSeconds: Int

    init(
        maxTurns: Int = LocalModelSettingsStore.defaultLocalAgentMaxTurns,
        maxToolCalls: Int = LocalModelSettingsStore.defaultLocalAgentMaxToolCalls,
        toolTimeoutSeconds: Int = LocalModelSettingsStore.defaultLocalAgentToolTimeoutSeconds
    ) {
        self.maxTurns = min(max(maxTurns, 1), 32)
        self.maxToolCalls = min(max(maxToolCalls, 1), 50)
        self.toolTimeoutSeconds = min(max(toolTimeoutSeconds, 5), 120)
    }

    static func current(defaults: UserDefaults = .standard) -> LocalAgentRuntimeControls {
        LocalAgentRuntimeControls(
            maxTurns: LocalModelSettingsStore.localAgentMaxTurns(defaults: defaults),
            maxToolCalls: LocalModelSettingsStore.localAgentMaxToolCalls(defaults: defaults),
            toolTimeoutSeconds: LocalModelSettingsStore.localAgentToolTimeoutSeconds(defaults: defaults)
        )
    }
}

enum LocalAgentGitBranchPreflightDecision: Equatable {
    case notGitRepository(answer: String)
    case shellUnavailable(answer: String)
    case requestShellApproval(command: String, cwd: String)
}

enum LocalAgentGitBranchPreflight {
    static let branchListCommand = "git branch --all --no-color"

    static func decision(
        requestText: String,
        workspacePath: String,
        shellExecutionEnabled: Bool,
        fileManager: FileManager = .default
    ) -> LocalAgentGitBranchPreflightDecision? {
        guard isGitBranchListingRequest(requestText) else { return nil }

        let displayPath = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL.path
        guard isInsideGitWorkTree(workspacePath: workspacePath, fileManager: fileManager) else {
            return .notGitRepository(answer: """
            I cannot list Git branches because the selected workspace is not a Git repository: \(displayPath).

            Select or import a workspace that contains a Git checkout, then ask again.
            """)
        }

        guard shellExecutionEnabled else {
            return .shellUnavailable(answer: """
            The selected workspace is a Git repository, but Local Agent shell commands are disabled. I need shell approval to run `\(branchListCommand)`.

            Enable Shell commands in Runtime settings, then ask again.
            """)
        }

        return .requestShellApproval(command: branchListCommand, cwd: ".")
    }

    static func isGitBranchListingRequest(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        let branchTerms = ["branch", "branches", "bracnh", "bracnhes", "brach", "braches"]
        guard branchTerms.contains(where: { normalized.contains($0) }) else { return false }
        let gitContextTerms = ["git", "repo", "repository", "checkout", "worktree"]
        return gitContextTerms.contains(where: { normalized.contains($0) })
    }

    static func isInsideGitWorkTree(workspacePath: String, fileManager: FileManager = .default) -> Bool {
        let trimmed = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory) else { return false }

        var current = URL(fileURLWithPath: trimmed, isDirectory: isDirectory.boolValue)
            .standardizedFileURL
        if !isDirectory.boolValue {
            current.deleteLastPathComponent()
        }

        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return false }
            current = parent
        }
    }
}

@MainActor
final class LocalAgentOrchestrator {
    private let inferenceClient = LocalAgentInferenceClient()
    private let controls: LocalAgentRuntimeControls
    private let capabilities: LocalAgentToolCapabilities
    private let maxInvalidActionRepairs = 2
    private let maxMissingToolFinalRepairs = 1
    private var cancellationRequested = false
    private var cancellationRequestedAt: Date?
    private var activeCancellationToken: LocalAgentCancellationToken?

    init(
        controls: LocalAgentRuntimeControls = .current(),
        capabilities: LocalAgentToolCapabilities = .current()
    ) {
        self.controls = controls
        self.capabilities = capabilities
    }

    func cancel() {
        cancellationRequested = true
        if cancellationRequestedAt == nil {
            cancellationRequestedAt = Date()
        }
        activeCancellationToken?.cancel()
        inferenceClient.cancel()
    }

    static func buildInitialPrompt(for task: AgentTask, promptOverride: String?) -> String {
        if let promptOverride,
           !promptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return promptOverride
        }

        var parts: [String] = [
            """
            Local Agent Task:
            \(task.goal)

            Use only ASTRA-brokered tools. Do not claim an external action succeeded unless a tool observation proves it.
            """
        ]
        if !task.inputs.isEmpty {
            parts.append("Inputs:\n" + task.inputs.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !task.constraints.isEmpty {
            parts.append("Constraints:\n" + task.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !task.acceptanceCriteria.isEmpty {
            parts.append("Acceptance Criteria:\n" + task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    func run(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        prompt: String,
        workspacePath: String,
        executablePath: String,
        modelDirectory: String,
        permissionPolicy: PermissionPolicy,
        permissionManifest: RunPermissionManifest,
        timeoutSeconds: TimeInterval,
        onEvent: @escaping (ParsedEvent) -> Void
    ) async -> AgentProcessResult {
        let model = AgentRuntimeProcessRunner.model(task.model, for: .localMLX)
        let cancellationToken = LocalAgentCancellationToken()
        if cancellationRequested {
            cancellationToken.cancel()
        }
        activeCancellationToken = cancellationToken
        defer {
            if activeCancellationToken === cancellationToken {
                activeCancellationToken = nil
            }
        }
        var messages = LocalAgentPromptAdapter.initialMessages(
            systemPrompt: Self.systemPrompt(capabilities: capabilities),
            userPrompt: prompt,
            model: model,
            modelDirectory: modelDirectory
        )
        let toolExecutor = LocalAgentToolExecutor(
            task: task,
            workspacePath: workspacePath,
            requestTimeout: TimeInterval(controls.toolTimeoutSeconds),
            capabilities: capabilities,
            cancellationToken: cancellationToken
        )
        let policyGuard = AgentRuntimePolicyGuard(manifest: permissionManifest)
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var invalidActionCount = 0
        var invalidActionFailureCount = 0
        var invalidActionRepairCount = 0
        var plainTextFinalRepairCount = 0
        var observationFallbackFinalCount = 0
        var missingToolFinalCount = 0
        var missingToolFinalRepairCount = 0
        var executedToolCount = 0
        var successfulToolObservationCount = 0
        var failedToolObservationCount = 0
        var lastSuccessfulObservationContent: String?
        var lastSuccessfulObservationTool: String?
        var policyDecisionCount = 0
        var policyApprovalRequestCount = 0
        var policyViolationCount = 0
        var memoryDiagnosticCount = 0
        var watchdogWarningCount = 0
        var proposedToolNames = Set<String>()
        var executedToolNames = Set<String>()
        var successfulToolNames = Set<String>()
        var firstTokenLatencyMs: Int?
        var tokensPerSecond: Double?
        var promptTokensPerSecond: Double?
        var helperDurationMs: Int?
        var modelLoadMs: Int?
        var activeMemoryBytes: Int?
        var peakMemoryBytes: Int?
        var cacheMemoryBytes: Int?
        var memoryLimitBytes: Int?
        var cacheLimitBytes: Int?
        var memoryBudgetBytes: Int?
        let localAgentStartedAt = Date()

        func captureBenchmark(_ benchmark: LocalAgentInferenceBenchmark) {
            if firstTokenLatencyMs == nil {
                firstTokenLatencyMs = benchmark.firstTokenLatencyMs
            }
            tokensPerSecond = benchmark.tokensPerSecond ?? tokensPerSecond
            promptTokensPerSecond = benchmark.promptTokensPerSecond ?? promptTokensPerSecond
            helperDurationMs = benchmark.helperDurationMs ?? helperDurationMs
            if modelLoadMs == nil {
                modelLoadMs = benchmark.modelLoadMs
            }
            activeMemoryBytes = benchmark.activeMemoryBytes ?? activeMemoryBytes
            cacheMemoryBytes = benchmark.cacheMemoryBytes ?? cacheMemoryBytes
            memoryLimitBytes = benchmark.memoryLimitBytes ?? memoryLimitBytes
            cacheLimitBytes = benchmark.cacheLimitBytes ?? cacheLimitBytes
            memoryBudgetBytes = benchmark.memoryBudgetBytes ?? memoryBudgetBytes
            if let peak = benchmark.peakMemoryBytes {
                peakMemoryBytes = max(peakMemoryBytes ?? 0, peak)
            }
        }

        func recordMetrics(status: String, stopReason: String, turn: Int) {
            var fields = [
                "status": status,
                "stop_reason": stopReason,
                "turns": "\(turn)",
                "tool_calls": "\(executedToolCount)",
                "tool_successes": "\(successfulToolObservationCount)",
                "tool_errors": "\(failedToolObservationCount)",
                "policy_decisions": "\(policyDecisionCount)",
                "policy_approval_requests": "\(policyApprovalRequestCount)",
                "policy_violations": "\(policyViolationCount)",
                "input_tokens": "\(totalInputTokens)",
                "output_tokens": "\(totalOutputTokens)",
                "invalid_action_repairs": "\(invalidActionRepairCount)",
                "plain_text_final_repairs": "\(plainTextFinalRepairCount)",
                "observation_fallback_finals": "\(observationFallbackFinalCount)",
                "missing_tool_final_repairs": "\(missingToolFinalRepairCount)",
                "fake_completion_repairs": "\(missingToolFinalRepairCount)",
                "parse_success_rate": Self.metricRate(
                    numerator: max(0, turn - invalidActionFailureCount),
                    denominator: turn
                ),
                "tool_success_rate": Self.metricRate(
                    numerator: successfulToolObservationCount,
                    denominator: executedToolCount
                ),
                "policy_denial_rate": Self.metricRate(
                    numerator: policyViolationCount,
                    denominator: policyDecisionCount
                ),
                "memory_diagnostics": "\(memoryDiagnosticCount)",
                "watchdog_warnings": "\(watchdogWarningCount)",
                "enabled_capabilities": capabilities.enabled.map(\.rawValue).sorted().joined(separator: ","),
                "proposed_tools": proposedToolNames.sorted().joined(separator: ","),
                "executed_tools": executedToolNames.sorted().joined(separator: ","),
                "successful_tools": successfulToolNames.sorted().joined(separator: ","),
                "duration_ms": "\(max(0, Int(Date().timeIntervalSince(localAgentStartedAt) * 1_000)))"
            ]
            fields["helper_duration_ms"] = helperDurationMs.map(String.init)
            fields["first_token_latency_ms"] = firstTokenLatencyMs.map(String.init)
            fields["tokens_per_second"] = tokensPerSecond.map(Self.metricDouble)
            fields["prompt_tokens_per_second"] = promptTokensPerSecond.map(Self.metricDouble)
            fields["model_load_ms"] = modelLoadMs.map(String.init)
            fields["active_memory_bytes"] = activeMemoryBytes.map(String.init)
            fields["peak_memory_bytes"] = peakMemoryBytes.map(String.init)
            fields["cache_memory_bytes"] = cacheMemoryBytes.map(String.init)
            fields["memory_limit_bytes"] = memoryLimitBytes.map(String.init)
            fields["cache_limit_bytes"] = cacheLimitBytes.map(String.init)
            fields["memory_budget_bytes"] = memoryBudgetBytes.map(String.init)
            if let cancellationRequestedAt {
                fields["cancellation_latency_ms"] = "\(max(0, Int(Date().timeIntervalSince(cancellationRequestedAt) * 1_000)))"
            }
            Self.recordLocalAgentEvent(
                type: "local_agent.metrics",
                fields: fields,
                task: task,
                run: run,
                modelContext: modelContext
            )
            let outcome: LocalAgentBetaSoakOutcome
            switch status {
            case "completed":
                outcome = .completed
            case "approval_required":
                outcome = .approvalRequired
            case "cancelled":
                outcome = .cancelled
            default:
                outcome = .blocked
            }
            LocalAgentBetaSoakStore.recordRuntimeSample(LocalAgentBetaSoakSample(
                recordedAt: Date(),
                model: model,
                outcome: outcome,
                stopReason: stopReason,
                enabledCapabilities: capabilities.enabled.map(\.rawValue).sorted(),
                proposedTools: proposedToolNames.sorted(),
                executedTools: executedToolNames.sorted(),
                successfulTools: successfulToolNames.sorted(),
                turns: turn,
                toolCalls: executedToolCount,
                toolSuccesses: successfulToolObservationCount,
                toolErrors: failedToolObservationCount,
                policyDecisions: policyDecisionCount,
                policyApprovalRequests: policyApprovalRequestCount,
                policyViolations: policyViolationCount,
                invalidActionRepairs: invalidActionRepairCount,
                missingToolFinalRepairs: missingToolFinalRepairCount,
                watchdogWarnings: watchdogWarningCount,
                memoryDiagnostics: memoryDiagnosticCount,
                firstTokenLatencyMs: firstTokenLatencyMs,
                tokensPerSecond: tokensPerSecond
            ))
        }

        func completeFinal(answer: String, turn: Int, finalFormat: String = "json") -> AgentProcessResult {
            AgentEventRecorder.recordLocalModelEvent(
                .text(text: answer),
                to: task,
                run: run,
                modelContext: modelContext
            )
            AgentEventRecorder.recordLocalModelEvent(
                .stats(
                    inputTokens: totalInputTokens,
                    outputTokens: totalOutputTokens,
                    costUSD: nil,
                    durationMs: nil,
                    turns: turn
                ),
                to: task,
                run: run,
                modelContext: modelContext
            )
            onEvent(.text(text: answer))
            Self.recordLocalAgentEvent(
                type: "local_agent.final",
                fields: [
                    "turn": "\(turn)",
                    "answer_chars": "\(answer.count)",
                    "tool_calls": "\(executedToolCount)",
                    "format": finalFormat
                ],
                task: task,
                run: run,
                modelContext: modelContext
            )
            recordMetrics(status: "completed", stopReason: "completed", turn: turn)
            return AgentProcessResult(exitCode: 0)
        }

        func recordWatchdog(
            reason: String,
            phase: String,
            severity: String = "warning",
            fields: [String: String] = [:]
        ) {
            watchdogWarningCount += 1
            var payload = fields
            payload["reason"] = reason
            payload["phase"] = phase
            payload["severity"] = severity
            if payload["recovery"] == nil,
               let recovery = LocalAgentRecoverySuggestions.suggestion(for: reason) {
                payload["recovery"] = recovery
            }
            Self.recordLocalAgentEvent(
                type: "local_agent.watchdog",
                fields: payload,
                task: task,
                run: run,
                modelContext: modelContext
            )
        }

        func handleGitBranchPreflightIfNeeded() async -> AgentProcessResult? {
            let requestText = [
                task.title,
                task.goal,
                task.inputs.joined(separator: " "),
                task.constraints.joined(separator: " "),
                task.acceptanceCriteria.joined(separator: " "),
                prompt
            ].joined(separator: "\n")

            guard let decision = LocalAgentGitBranchPreflight.decision(
                requestText: requestText,
                workspacePath: workspacePath,
                shellExecutionEnabled: capabilities.contains(.shellExecution)
            ) else {
                return nil
            }

            switch decision {
            case .notGitRepository(let answer):
                Self.recordLocalAgentEvent(
                    type: "local_agent.git_branch_preflight",
                    fields: ["status": "not_git_repository"],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                return completeFinal(answer: answer, turn: 0, finalFormat: "git_branch_preflight")

            case .shellUnavailable(let answer):
                Self.recordLocalAgentEvent(
                    type: "local_agent.git_branch_preflight",
                    fields: ["status": "shell_unavailable"],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                return completeFinal(answer: answer, turn: 0, finalFormat: "git_branch_preflight")

            case .requestShellApproval(let command, let cwd):
                let tool = "shell.exec"
                let callID = "git-branches"
                let arguments: [String: LocalModelJSONValue] = [
                    "command": .string(command),
                    "cwd": .string(cwd),
                    "timeout_seconds": .number(20),
                    "max_output_bytes": .number(12_000)
                ]
                proposedToolNames.insert(tool)
                Self.recordLocalAgentEvent(
                    type: "local_agent.git_branch_preflight",
                    fields: [
                        "status": "shell_required",
                        "command": command
                    ],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )

                let approvalRequest = PermissionRequest.shell(command: command, toolName: Self.policyToolName(for: tool))
                let approvalGrants = PermissionBroker.approvalGrants(for: approvalRequest)
                guard !approvalGrants.isEmpty else {
                    policyDecisionCount += 1
                    policyViolationCount += 1
                    recordMetrics(status: "blocked", stopReason: "policy_violation", turn: 0)
                    return Self.policyStopResult(
                        violation: AgentRuntimePolicyViolation(
                            reason: "Local Agent shell execution could not be mapped to a scoped approval grant",
                            toolName: Self.policyToolName(for: tool),
                            detail: command
                        ),
                        fallbackRequest: approvalRequest,
                        callID: callID,
                        tool: tool,
                        arguments: arguments,
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                }

                guard policyGuard.hasAppliedApprovalGrants(approvalGrants) else {
                    policyDecisionCount += 1
                    policyApprovalRequestCount += 1
                    recordMetrics(status: "approval_required", stopReason: "permission_approval_required", turn: 0)
                    return Self.policyStopResult(
                        violation: AgentRuntimePolicyViolation(
                            reason: "Local Agent branch listing requires explicit ASTRA shell approval",
                            toolName: Self.policyToolName(for: tool),
                            detail: command,
                            requiresApproval: true,
                            permissionRequest: approvalRequest,
                            approvalGrants: approvalGrants
                        ),
                        fallbackRequest: approvalRequest,
                        callID: callID,
                        tool: tool,
                        arguments: arguments,
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                }

                policyDecisionCount += 1
                Self.recordLocalAgentEvent(
                    type: "local_agent.policy_decision",
                    fields: [
                        "status": "approved_grant",
                        "call_id": callID,
                        "tool": tool,
                        "policy_tool": Self.policyToolName(for: tool)
                    ],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                modelContext.insert(TaskEvent(
                    task: task,
                    type: "local_agent.policy",
                    payload: "Allowed previously approved ASTRA-brokered local tool `\(tool)`.",
                    run: run
                ))
                AgentEventRecorder.recordLocalModelEvent(
                    .toolUse(name: tool, id: callID, inputSummary: Self.argumentSummary(arguments)),
                    to: task,
                    run: run,
                    modelContext: modelContext
                )
                onEvent(.toolUse(name: tool, id: callID, input: nil))

                if shouldStopForCancellation(task: task) {
                    recordMetrics(status: "cancelled", stopReason: "local_agent_cancelled", turn: 0)
                    return cancellationResult(task: task, run: run, modelContext: modelContext, phase: "before git branch preflight")
                }

                let toolStartedAt = Date()
                let observation = await toolExecutor.execute(callID: callID, tool: tool, arguments: arguments)
                let toolDurationMs = max(0, Int(Date().timeIntervalSince(toolStartedAt) * 1_000))
                executedToolCount += 1
                executedToolNames.insert(tool)

                AgentEventRecorder.recordLocalModelEvent(
                    .toolResult(id: callID, content: observation.modelVisibleContent),
                    to: task,
                    run: run,
                    modelContext: modelContext
                )
                onEvent(.toolResult(toolId: callID, content: observation.modelVisibleContent))
                Self.recordLocalAgentEvent(
                    type: "local_agent.observation",
                    fields: [
                        "call_id": callID,
                        "tool": tool,
                        "status": observation.status,
                        "content_chars": "\(observation.modelVisibleContent.count)",
                        "duration_ms": "\(toolDurationMs)"
                    ],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                if !observation.eventFields.isEmpty {
                    var fields = observation.eventFields
                    fields["call_id"] = callID
                    fields["tool"] = tool
                    fields["status"] = observation.status
                    Self.recordLocalAgentEvent(
                        type: "local_agent.tool_artifact",
                        fields: fields,
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                }
                if observation.status.lowercased() == "ok" {
                    successfulToolObservationCount += 1
                    successfulToolNames.insert(tool)
                    lastSuccessfulObservationContent = observation.modelVisibleContent
                    lastSuccessfulObservationTool = tool
                } else {
                    failedToolObservationCount += 1
                }
                if Self.shouldReportToolWatchdog(
                    observation: observation,
                    durationMs: toolDurationMs,
                    timeoutSeconds: controls.toolTimeoutSeconds
                ) {
                    recordWatchdog(
                        reason: "tool_slow_or_timeout",
                        phase: "git_branch_preflight",
                        fields: [
                            "tool": tool,
                            "status": observation.status,
                            "duration_ms": "\(toolDurationMs)",
                            "timeout_seconds": "\(controls.toolTimeoutSeconds)"
                        ]
                    )
                }

                let answer: String
                if observation.status.lowercased() == "ok" {
                    answer = "Here is the available Git branch listing from `\(command)`:\n\n\(observation.modelVisibleContent)"
                } else {
                    answer = "I tried to list Git branches with `\(command)`, but the command failed:\n\n\(observation.modelVisibleContent)"
                }
                return completeFinal(answer: answer, turn: 0, finalFormat: "git_branch_preflight")
            }
        }

        modelContext.insert(TaskEvent(
            task: task,
            type: "system.info",
            payload: "Local Agent mode is running with ASTRA-brokered tools.",
            run: run
        ))

        if let preflightResult = await handleGitBranchPreflightIfNeeded() {
            return preflightResult
        }

        // Ensure the persistent serve helper (when enabled) is torn down on every exit path.
        defer { inferenceClient.shutdown() }

        for turn in 1...controls.maxTurns {
            if shouldStopForCancellation(task: task) {
                recordMetrics(status: "cancelled", stopReason: "local_agent_cancelled", turn: turn)
                return cancellationResult(task: task, run: run, modelContext: modelContext, phase: "before turn \(turn)")
            }

            modelContext.insert(TaskEvent(
                task: task,
                type: "local_agent.turn",
                payload: "Local Agent turn \(turn).",
                run: run
            ))

            let turnResult = await inferenceClient.generate(
                messages: messages,
                task: task,
                workspacePath: workspacePath,
                executablePath: executablePath,
                model: model,
                modelDirectory: modelDirectory,
                permissionPolicy: permissionPolicy,
                timeoutSeconds: timeoutSeconds
            )
            totalInputTokens += turnResult.inputTokens
            totalOutputTokens += turnResult.outputTokens
            captureBenchmark(turnResult.benchmark)
            recordNonTextEvents(turnResult.events, task: task, run: run, modelContext: modelContext, onEvent: onEvent)
            for memoryDiagnostic in Self.localMemoryDiagnostics(from: turnResult.events) {
                memoryDiagnosticCount += 1
                if Self.memoryDiagnosticLooksPressured(memoryDiagnostic) {
                    recordWatchdog(
                        reason: "memory_pressure",
                        phase: "inference",
                        severity: "warning",
                        fields: [
                            "turn": "\(turn)",
                            "message": String(memoryDiagnostic.prefix(240))
                        ]
                    )
                }
            }

            if shouldStopForCancellation(task: task) {
                recordMetrics(status: "cancelled", stopReason: "local_agent_cancelled", turn: turn)
                return cancellationResult(task: task, run: run, modelContext: modelContext, phase: "after local inference")
            }
            if turnResult.timedOut {
                recordWatchdog(
                    reason: "helper_timeout",
                    phase: "inference",
                    severity: "error",
                    fields: [
                        "turn": "\(turn)",
                        "timeout_seconds": "\(Int(timeoutSeconds))"
                    ]
                )
                Self.recordLocalAgentEvent(
                    type: "local_agent.blocked",
                    fields: ["reason": "helper_timeout"],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                recordMetrics(status: "blocked", stopReason: "helper_timeout", turn: turn)
                return AgentProcessResult(exitCode: -1, error: turnResult.error, timedOut: true)
            }
            guard turnResult.exitCode == 0 else {
                Self.recordLocalAgentEvent(
                    type: "local_agent.blocked",
                    fields: [
                        "reason": "helper_failed",
                        "exit_code": "\(turnResult.exitCode)"
                    ],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                recordMetrics(status: "blocked", stopReason: "helper_failed", turn: turn)
                return AgentProcessResult(exitCode: turnResult.exitCode, error: turnResult.error)
            }

            let assistantText = turnResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch LocalModelActionParser.parse(assistantText) {
            case .success(let action):
                invalidActionCount = 0
                Self.recordLocalAgentEvent(
                    type: "local_agent.action_proposed",
                    fields: Self.actionEventFields(action),
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                switch action {
                case .final(_, let answer):
                    if executedToolCount == 0, Self.requiresToolObservationBeforeFinal(task: task, prompt: prompt) {
                        missingToolFinalCount += 1
                        let message = "Local Agent returned a final answer before any ASTRA tool observation for an action-based task."
                        modelContext.insert(TaskEvent(
                            task: task,
                            type: "local_agent.missing_tool_observation",
                            payload: message,
                            run: run
                        ))
                        guard missingToolFinalCount <= maxMissingToolFinalRepairs else {
                            recordWatchdog(
                                reason: "missing_tool_observation_repair_budget_exhausted",
                                phase: "finalization",
                                severity: "error",
                                fields: [
                                    "turn": "\(turn)",
                                    "repairs": "\(missingToolFinalCount - 1)",
                                    "max_repairs": "\(maxMissingToolFinalRepairs)"
                                ]
                            )
                            Self.recordLocalAgentEvent(
                                type: "local_agent.blocked",
                                fields: [
                                    "reason": "missing_tool_observation",
                                    "repairs": "\(missingToolFinalCount - 1)"
                                ],
                                task: task,
                                run: run,
                                modelContext: modelContext
                            )
                            recordMetrics(status: "blocked", stopReason: "local_agent_missing_tool_observation", turn: turn)
                            return AgentProcessResult(
                                exitCode: -1,
                                runtimeStopReason: "local_agent_missing_tool_observation",
                                runtimeStopMessage: "Local Agent tried to finish an action-based task before using an ASTRA tool. No external action was executed."
                            )
                        }
                        Self.recordLocalAgentEvent(
                            type: "local_agent.repair_requested",
                            fields: [
                                "reason": "missing_tool_observation",
                                "attempt": "\(missingToolFinalCount)"
                            ],
                            task: task,
                            run: run,
                            modelContext: modelContext
                        )
                        missingToolFinalRepairCount += 1
                        messages.append(LocalModelChatMessage(role: "assistant", content: assistantText))
                        messages.append(LocalModelChatMessage(
                            role: "user",
                            content: "This task requires ASTRA tool observations before a final answer. Return a tool_call JSON object or ask_user. Do not claim the action is done without a tool observation."
                        ))
                        continue
                    }
                    return completeFinal(answer: answer, turn: turn)

                case .toolCall(let id, let tool, let arguments, _):
                    proposedToolNames.insert(tool)
                    guard executedToolCount < controls.maxToolCalls else {
                        modelContext.insert(TaskEvent(
                            task: task,
                            type: "local_agent.tool_budget_exceeded",
                            payload: "Local Agent reached the maximum ASTRA tool call limit of \(controls.maxToolCalls).",
                            run: run
                        ))
                        Self.recordLocalAgentEvent(
                            type: "local_agent.blocked",
                            fields: [
                                "reason": "tool_budget_exceeded",
                                "max_tool_calls": "\(controls.maxToolCalls)"
                            ],
                            task: task,
                            run: run,
                            modelContext: modelContext
                        )
                        recordMetrics(status: "blocked", stopReason: "local_agent_tool_budget_exceeded", turn: turn)
                        return AgentProcessResult(
                            exitCode: -1,
                            runtimeStopReason: "local_agent_tool_budget_exceeded",
                            runtimeStopMessage: "Local Agent reached the maximum ASTRA tool call limit before finishing."
                        )
                    }
                    if let disabledCapability = capabilities.disabledCapability(for: tool) {
                        policyDecisionCount += 1
                        policyViolationCount += 1
                        recordMetrics(status: "blocked", stopReason: "policy_violation", turn: turn)
                        return Self.policyStopResult(
                            violation: AgentRuntimePolicyViolation(
                                reason: "Local Agent capability '\(disabledCapability.displayName)' is disabled in Runtime settings",
                                toolName: Self.policyToolName(for: tool),
                                detail: "Enable \(disabledCapability.displayName) in Runtime settings before this tool can be requested."
                            ),
                            fallbackRequest: Self.fallbackPermissionRequest(tool: tool, arguments: arguments, task: task),
                            callID: id,
                            tool: tool,
                            arguments: arguments,
                            task: task,
                            run: run,
                            modelContext: modelContext
                        )
                    }
                    let policyProbe = Self.policyProbe(callID: id, tool: tool, arguments: arguments, task: task)
                    let policyMessage: String
                    if let violation = policyGuard.violation(for: policyProbe) {
                        let fallbackRequest = Self.fallbackPermissionRequest(tool: tool, arguments: arguments, task: task)
                        let approvalGrants = violation.approvalGrants.isEmpty
                            ? PermissionBroker.approvalGrants(for: violation.permissionRequest ?? fallbackRequest)
                            : violation.approvalGrants
                        if !violation.requiresApproval,
                           let explicitRequest = Self.localAgentExplicitApprovalRequest(tool: tool, arguments: arguments, task: task),
                           Self.isExplicitBrowserApprovalTool(tool) {
                            let explicitGrants = PermissionBroker.approvalGrants(for: explicitRequest)
                            let approvalName = Self.localAgentExplicitApprovalName(tool: tool)
                            if explicitGrants.isEmpty {
                                policyDecisionCount += 1
                                policyViolationCount += 1
                                recordMetrics(status: "blocked", stopReason: "policy_violation", turn: turn)
                                return Self.policyStopResult(
                                    violation: violation,
                                    fallbackRequest: fallbackRequest,
                                    callID: id,
                                    tool: tool,
                                    arguments: arguments,
                                    task: task,
                                    run: run,
                                    modelContext: modelContext
                                )
                            } else if policyGuard.hasAppliedApprovalGrants(explicitGrants) {
                                policyDecisionCount += 1
                                policyMessage = "Allowed previously approved ASTRA-brokered local tool `\(tool)`."
                            } else {
                                policyDecisionCount += 1
                                policyApprovalRequestCount += 1
                                recordMetrics(status: "approval_required", stopReason: "permission_approval_required", turn: turn)
                                return Self.policyStopResult(
                                    violation: AgentRuntimePolicyViolation(
                                        reason: "Local Agent \(approvalName) requires explicit ASTRA approval",
                                        toolName: Self.policyToolName(for: tool),
                                        detail: Self.localAgentExplicitApprovalDetail(tool: tool, arguments: arguments),
                                        requiresApproval: true,
                                        permissionRequest: explicitRequest,
                                        approvalGrants: explicitGrants
                                    ),
                                    fallbackRequest: explicitRequest,
                                    callID: id,
                                    tool: tool,
                                    arguments: arguments,
                                    task: task,
                                    run: run,
                                    modelContext: modelContext
                                )
                            }
                        } else if violation.requiresApproval, policyGuard.hasAppliedApprovalGrants(approvalGrants) {
                            policyDecisionCount += 1
                            policyMessage = "Allowed previously approved ASTRA-brokered local tool `\(tool)`."
                        } else {
                            policyDecisionCount += 1
                            if violation.requiresApproval {
                                policyApprovalRequestCount += 1
                            } else {
                                policyViolationCount += 1
                            }
                            recordMetrics(
                                status: violation.requiresApproval ? "approval_required" : "blocked",
                                stopReason: violation.requiresApproval ? "permission_approval_required" : "policy_violation",
                                turn: turn
                            )
                            return Self.policyStopResult(
                                violation: violation,
                                fallbackRequest: fallbackRequest,
                                callID: id,
                                tool: tool,
                                arguments: arguments,
                                task: task,
                                run: run,
                                modelContext: modelContext
                            )
                        }
                    } else if let approvalRequest = Self.localAgentExplicitApprovalRequest(tool: tool, arguments: arguments, task: task) {
                        let approvalGrants = PermissionBroker.approvalGrants(for: approvalRequest)
                        let approvalName = Self.localAgentExplicitApprovalName(tool: tool)
                        if approvalGrants.isEmpty {
                            policyDecisionCount += 1
                            policyViolationCount += 1
                            recordMetrics(status: "blocked", stopReason: "policy_violation", turn: turn)
                            return Self.policyStopResult(
                                violation: AgentRuntimePolicyViolation(
                                    reason: "Local Agent \(approvalName) could not be mapped to a scoped approval grant",
                                    toolName: Self.policyToolName(for: tool),
                                    detail: Self.localAgentExplicitApprovalDetail(tool: tool, arguments: arguments)
                                ),
                                fallbackRequest: approvalRequest,
                                callID: id,
                                tool: tool,
                                arguments: arguments,
                                task: task,
                                run: run,
                                modelContext: modelContext
                            )
                        } else if policyGuard.hasAppliedApprovalGrants(approvalGrants) {
                            policyDecisionCount += 1
                            policyMessage = "Allowed previously approved ASTRA-brokered local tool `\(tool)`."
                        } else {
                            policyDecisionCount += 1
                            policyApprovalRequestCount += 1
                            recordMetrics(status: "approval_required", stopReason: "permission_approval_required", turn: turn)
                            return Self.policyStopResult(
                                violation: AgentRuntimePolicyViolation(
                                    reason: "Local Agent \(approvalName) requires explicit ASTRA approval",
                                    toolName: Self.policyToolName(for: tool),
                                    detail: Self.localAgentExplicitApprovalDetail(tool: tool, arguments: arguments),
                                    requiresApproval: true,
                                    permissionRequest: approvalRequest,
                                    approvalGrants: approvalGrants
                                ),
                                fallbackRequest: approvalRequest,
                                callID: id,
                                tool: tool,
                                arguments: arguments,
                                task: task,
                                run: run,
                                modelContext: modelContext
                            )
                        }
                    } else {
                        policyDecisionCount += 1
                        policyMessage = "Allowed ASTRA-brokered local tool `\(tool)`."
                    }
                    Self.recordLocalAgentEvent(
                        type: "local_agent.policy_decision",
                        fields: [
                            "status": policyMessage.contains("previously approved") ? "approved_grant" : "allowed",
                            "call_id": id,
                            "tool": tool,
                            "policy_tool": Self.policyToolName(for: tool)
                        ],
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    modelContext.insert(TaskEvent(
                        task: task,
                        type: "local_agent.policy",
                        payload: policyMessage,
                        run: run
                    ))
                    AgentEventRecorder.recordLocalModelEvent(
                        .toolUse(name: tool, id: id, inputSummary: Self.argumentSummary(arguments)),
                        to: task,
                        run: run,
                        modelContext: modelContext
                    )
                    onEvent(.toolUse(name: tool, id: id, input: nil))

                    if shouldStopForCancellation(task: task) {
                        recordMetrics(status: "cancelled", stopReason: "local_agent_cancelled", turn: turn)
                        return cancellationResult(task: task, run: run, modelContext: modelContext, phase: "before tool \(tool)")
                    }
                    let toolStartedAt = Date()
                    let observation = await toolExecutor.execute(
                        callID: id,
                        tool: tool,
                        arguments: arguments
                    )
                    let toolDurationMs = max(0, Int(Date().timeIntervalSince(toolStartedAt) * 1_000))
                    executedToolNames.insert(tool)
                    if shouldStopForCancellation(task: task) {
                        recordMetrics(status: "cancelled", stopReason: "local_agent_cancelled", turn: turn)
                        return cancellationResult(task: task, run: run, modelContext: modelContext, phase: "after tool \(tool)")
                    }
                    AgentEventRecorder.recordLocalModelEvent(
                        .toolResult(id: id, content: observation.modelVisibleContent),
                        to: task,
                        run: run,
                        modelContext: modelContext
                    )
                    onEvent(.toolResult(toolId: id, content: observation.modelVisibleContent))
                    Self.recordLocalAgentEvent(
                        type: "local_agent.observation",
                        fields: [
                            "call_id": id,
                            "tool": tool,
                            "status": observation.status,
                            "content_chars": "\(observation.modelVisibleContent.count)",
                            "duration_ms": "\(toolDurationMs)"
                        ],
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    if !observation.eventFields.isEmpty {
                        var fields = observation.eventFields
                        fields["call_id"] = id
                        fields["tool"] = tool
                        fields["status"] = observation.status
                        Self.recordLocalAgentEvent(
                            type: "local_agent.tool_artifact",
                            fields: fields,
                            task: task,
                            run: run,
                            modelContext: modelContext
                        )
                    }
                    if observation.status.lowercased() == "ok" {
                        successfulToolObservationCount += 1
                        successfulToolNames.insert(tool)
                        lastSuccessfulObservationContent = observation.modelVisibleContent
                        lastSuccessfulObservationTool = tool
                    } else {
                        failedToolObservationCount += 1
                    }
                    if Self.shouldReportToolWatchdog(
                        observation: observation,
                        durationMs: toolDurationMs,
                        timeoutSeconds: controls.toolTimeoutSeconds
                    ) {
                        recordWatchdog(
                            reason: "tool_slow_or_timeout",
                            phase: "tool_execution",
                            fields: [
                                "turn": "\(turn)",
                                "tool": tool,
                                "status": observation.status,
                                "duration_ms": "\(toolDurationMs)",
                                "timeout_seconds": "\(controls.toolTimeoutSeconds)"
                            ]
                        )
                    }

                    messages.append(LocalModelChatMessage(role: "assistant", content: assistantText))
                    messages.append(LocalModelChatMessage(role: "tool", content: observation.modelVisibleContent))
                    executedToolCount += 1

                case .plan(_, let steps):
                    let planText = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                    modelContext.insert(TaskEvent(task: task, type: "plan.created", payload: planText, run: run))
                    messages.append(LocalModelChatMessage(role: "assistant", content: assistantText))
                    messages.append(LocalModelChatMessage(
                        role: "user",
                        content: "Plan noted. Continue by returning either a tool_call JSON object or a final JSON object."
                    ))

                case .askUser(_, let question):
                    Self.recordLocalAgentEvent(
                        type: "local_agent.blocked",
                        fields: [
                            "reason": "ask_user",
                            "question_chars": "\(question.count)"
                        ],
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    recordMetrics(status: "blocked", stopReason: "local_agent_asked_user", turn: turn)
                    return AgentProcessResult(
                        exitCode: -1,
                        runtimeStopReason: "local_agent_asked_user",
                        runtimeStopMessage: question
                    )

                case .blocked(let id, let reason):
                    Self.recordBlockedPlanStepIfApplicable(
                        actionID: id,
                        reason: reason,
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    Self.recordLocalAgentEvent(
                        type: "local_agent.blocked",
                        fields: [
                            "reason": "model_blocked",
                            "message": String(reason.prefix(500))
                        ],
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    recordMetrics(status: "blocked", stopReason: "local_agent_blocked", turn: turn)
                    return AgentProcessResult(
                        exitCode: -1,
                        runtimeStopReason: "local_agent_blocked",
                        runtimeStopMessage: reason
                    )

                case .cancelled(_, let reason):
                    recordMetrics(status: "cancelled", stopReason: "local_agent_cancelled", turn: turn)
                    return cancellationResult(
                        task: task,
                        run: run,
                        modelContext: modelContext,
                        phase: reason ?? "model returned cancelled"
                    )
                }

            case .failure(let error):
                if case .noJSONObject = error,
                   successfulToolObservationCount > 0,
                   !assistantText.isEmpty {
                    invalidActionFailureCount += 1
                    plainTextFinalRepairCount += 1
                    Self.recordLocalAgentEvent(
                        type: "local_agent.action_repaired",
                        fields: [
                            "reason": "plain_text_final_after_observation",
                            "turn": "\(turn)",
                            "answer_chars": "\(assistantText.count)",
                            "tool_calls": "\(executedToolCount)"
                        ],
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    return completeFinal(
                        answer: assistantText,
                        turn: turn,
                        finalFormat: "plain_text_after_observation"
                    )
                }
                invalidActionCount += 1
                invalidActionFailureCount += 1
                let message = error.localizedDescription
                modelContext.insert(TaskEvent(
                    task: task,
                    type: "local_agent.invalid_action",
                    payload: message,
                    run: run
                ))
                guard invalidActionCount <= maxInvalidActionRepairs else {
                    if let lastSuccessfulObservationContent,
                       !lastSuccessfulObservationContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        observationFallbackFinalCount += 1
                        Self.recordLocalAgentEvent(
                            type: "local_agent.action_repaired",
                            fields: [
                                "reason": "observation_final_after_invalid_action",
                                "turn": "\(turn)",
                                "repairs": "\(invalidActionCount - 1)",
                                "tool": lastSuccessfulObservationTool ?? "unknown",
                                "observation_chars": "\(lastSuccessfulObservationContent.count)"
                            ],
                            task: task,
                            run: run,
                            modelContext: modelContext
                        )
                        return completeFinal(
                            answer: lastSuccessfulObservationContent,
                            turn: turn,
                            finalFormat: "observation_after_invalid_action"
                        )
                    }
                    recordWatchdog(
                        reason: "invalid_action_repair_budget_exhausted",
                        phase: "action_parse",
                        severity: "error",
                        fields: [
                            "turn": "\(turn)",
                            "repairs": "\(invalidActionCount - 1)",
                            "max_repairs": "\(maxInvalidActionRepairs)",
                            "last_error": String(message.prefix(240))
                        ]
                    )
                    Self.recordLocalAgentEvent(
                        type: "local_agent.blocked",
                        fields: [
                            "reason": "invalid_action",
                            "repairs": "\(invalidActionCount - 1)",
                            "error": message
                        ],
                        task: task,
                        run: run,
                        modelContext: modelContext
                    )
                    recordMetrics(status: "blocked", stopReason: "local_agent_invalid_action", turn: turn)
                    return AgentProcessResult(
                        exitCode: -1,
                        runtimeStopReason: "local_agent_invalid_action",
                        runtimeStopMessage: "Local Agent could not produce a valid action after \(maxInvalidActionRepairs) repair attempt(s). Last error: \(message)"
                    )
                }
                Self.recordLocalAgentEvent(
                    type: "local_agent.repair_requested",
                    fields: [
                        "reason": "invalid_action",
                        "attempt": "\(invalidActionCount)",
                        "error": message
                    ],
                    task: task,
                    run: run,
                    modelContext: modelContext
                )
                invalidActionRepairCount += 1
                messages.append(LocalModelChatMessage(role: "assistant", content: assistantText))
                messages.append(LocalModelChatMessage(
                    role: "user",
                    content: "Repair the previous response. Return exactly one valid JSON object matching the Local Agent Action Protocol. Error: \(message)"
                ))
            }
        }

        recordWatchdog(
            reason: "turn_budget_exhausted",
            phase: "loop",
            fields: [
                "max_turns": "\(controls.maxTurns)"
            ]
        )
        Self.recordLocalAgentEvent(
            type: "local_agent.blocked",
            fields: [
                "reason": "max_turns",
                "max_turns": "\(controls.maxTurns)"
            ],
            task: task,
            run: run,
            modelContext: modelContext
        )
        recordMetrics(status: "blocked", stopReason: "local_agent_max_turns", turn: controls.maxTurns)
        return AgentProcessResult(
            exitCode: -1,
            runtimeStopReason: "local_agent_max_turns",
            runtimeStopMessage: "Local Agent reached the maximum turn limit before returning a final answer.",
            maxTurnsExceeded: true
        )
    }

    private func shouldStopForCancellation(task: AgentTask) -> Bool {
        cancellationRequested || Task.isCancelled || task.status == .cancelled
    }

    private func cancellationResult(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String
    ) -> AgentProcessResult {
        task.status = .cancelled
        modelContext.insert(TaskEvent(
            task: task,
            type: "local_agent.cancelled",
            payload: "Local Agent cancellation requested; stopped \(phase).",
            run: run
        ))
        Self.recordLocalAgentEvent(
            type: "local_agent.blocked",
            fields: [
                "reason": "cancelled",
                "phase": phase
            ],
            task: task,
            run: run,
            modelContext: modelContext
        )
        return AgentProcessResult(
            exitCode: -1,
            runtimeStopReason: "local_agent_cancelled",
            runtimeStopMessage: "Local Agent was cancelled."
        )
    }

    private func recordNonTextEvents(
        _ events: [AgentEvent],
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        onEvent: @escaping (ParsedEvent) -> Void
    ) {
        for event in events {
            switch event {
            case .text, .completed, .stats:
                continue
            default:
                AgentEventRecorder.recordLocalModelEvent(
                    event,
                    to: task,
                    run: run,
                    modelContext: modelContext
                )
                if let parsed = AgentEventRecorder.parsedEvent(from: event) {
                    onEvent(parsed)
                }
            }
        }
    }

    private static func argumentSummary(_ arguments: [String: LocalModelJSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(arguments),
              let text = String(data: data, encoding: .utf8) else {
            return "\(arguments.count) argument(s)"
        }
        return text
    }

    private static func metricDouble(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.2f", value)
    }

    private static func metricRate(numerator: Int, denominator: Int) -> String {
        guard denominator > 0 else { return "n/a" }
        return metricDouble(Double(numerator) / Double(denominator))
    }

    private static func actionEventFields(_ action: LocalModelAction) -> [String: String] {
        switch action {
        case .final(let id, let answer):
            var fields = [
                "action": "final",
                "answer_chars": "\(answer.count)"
            ]
            fields["id"] = id
            return fields
        case .toolCall(let id, let tool, let arguments, _):
            var fields = compactArgumentFields(arguments)
            fields["action"] = "tool_call"
            fields["id"] = id
            fields["tool"] = tool
            return fields
        case .plan(let id, let steps):
            var fields = [
                "action": "plan",
                "steps": "\(steps.count)"
            ]
            fields["id"] = id
            return fields
        case .askUser(let id, let question):
            var fields = [
                "action": "ask_user",
                "question_chars": "\(question.count)"
            ]
            fields["id"] = id
            return fields
        case .blocked(let id, let reason):
            var fields = [
                "action": "blocked",
                "reason_chars": "\(reason.count)"
            ]
            fields["id"] = id
            return fields
        case .cancelled(let id, let reason):
            var fields = [
                "action": "cancelled",
                "reason_chars": "\(reason?.count ?? 0)"
            ]
            fields["id"] = id
            return fields
        }
    }

    private static func compactArgumentFields(_ arguments: [String: LocalModelJSONValue]) -> [String: String] {
        var fields: [String: String] = ["argument_count": "\(arguments.count)"]
        for key in [
            "path", "query", "jql", "gmail_query", "file_id", "message_id",
            "channel_id", "thread_ts", "id", "name", "max_results", "max_bytes",
            "format", "limit", "overwrite"
        ] {
            if let value = arguments[key] {
                fields["arg_\(key)"] = String(String(describing: value).prefix(240))
            }
        }
        for key in ["analysisID", "analysis_id", "controlID", "control_id", "selector", "label", "role"] {
            if let value = arguments[key] {
                fields["arg_\(key)"] = String(String(describing: value).prefix(240))
            }
        }
        if let content = arguments["content"]?.stringValue {
            fields["arg_content_chars"] = "\(content.count)"
        }
        if let text = arguments["text"]?.stringValue {
            fields["arg_text_chars"] = "\(text.count)"
        }
        return fields
    }

    private static func recordLocalAgentEvent(
        type: String,
        fields: [String: String],
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        let payload: String
        if let data = try? JSONEncoder.sortedLocalAgentEventEncoder.encode(fields),
           let text = String(data: data, encoding: .utf8) {
            payload = text
        } else {
            payload = fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        }
        modelContext.insert(TaskEvent(task: task, type: type, payload: payload, run: run))
    }

    private static func policyProbe(
        callID: String,
        tool: String,
        arguments: [String: LocalModelJSONValue],
        task: AgentTask
    ) -> ParsedEvent {
        let policyTool = policyToolName(for: tool)
        return .toolUse(
            name: policyTool,
            id: callID,
            input: policyInput(tool: tool, arguments: arguments, task: task)
        )
    }

    private static func policyToolName(for tool: String) -> String {
        switch tool {
        case "workspace.read_file",
             "workspace.list_files",
             "workspace.search",
             "task.list_outputs",
             "task.read_output",
             "browser.read_page",
             "browser.analyze",
             "jira.search",
             "github.search",
             "google_drive.search",
             "google_drive.read",
             "gmail.search",
             "gmail.read",
             "slack.search",
             "slack.thread":
            return "Read"
        case "task.write_output",
             "workspace.write_file":
            return "Write"
        case "shell.exec":
            return "Bash"
        case "network.fetch":
            return "WebFetch"
        case "browser.click":
            return "browser.click"
        case "browser.type":
            return "browser.type"
        default:
            return tool
        }
    }

    private static func policyInput(
        tool: String,
        arguments: [String: LocalModelJSONValue],
        task: AgentTask
    ) -> [String: Any] {
        var input: [String: Any] = ["local_tool": tool]
        if tool == "shell.exec" {
            let command = arguments["command"]?.stringValue ?? ""
            input["command"] = command
            input["summary"] = command
            if let cwd = arguments["cwd"]?.stringValue {
                input["cwd"] = cwd
            }
            return input
        }
        if tool == "network.fetch" {
            let url = arguments["url"]?.stringValue ?? ""
            input["url"] = url
            input["summary"] = url
            return input
        }
        if isExplicitBrowserApprovalTool(tool) {
            let target = browserApprovalTarget(tool: tool, arguments: arguments) ?? argumentSummary(arguments)
            input["summary"] = target
            if tool == "browser.type" {
                input["text_chars"] = "\(firstStringArgument(["text"], in: arguments)?.count ?? 0)"
            }
            return input
        }
        if let path = arguments["path"]?.stringValue {
            let policyPath = tool == "task.read_output" || tool == "task.write_output"
                ? taskOutputPolicyPath(path, task: task)
                : path
            input["path"] = policyPath
            if tool == "workspace.write_file" {
                input["summary"] = workspaceWriteDiffPreview(path: path, content: arguments["content"]?.stringValue, task: task)
            } else {
                input["summary"] = policyPath
            }
        } else {
            input["summary"] = argumentSummary(arguments)
        }
        return input
    }

    private static func fallbackPermissionRequest(
        tool: String,
        arguments: [String: LocalModelJSONValue],
        task: AgentTask
    ) -> PermissionRequest {
        let policyTool = policyToolName(for: tool)
        if tool == "shell.exec" {
            return .shell(command: arguments["command"]?.stringValue ?? "", toolName: policyTool)
        }
        if tool == "network.fetch" {
            return .network(url: arguments["url"]?.stringValue ?? "", toolName: policyTool)
        }
        if isExplicitBrowserApprovalTool(tool) {
            return .tool(name: policyTool, context: browserApprovalTarget(tool: tool, arguments: arguments))
        }
        let context: String
        if let path = arguments["path"]?.stringValue {
            context = tool == "task.read_output" || tool == "task.write_output"
                ? taskOutputPolicyPath(path, task: task)
                : path
        } else {
            context = argumentSummary(arguments)
        }
        if tool == "task.write_output" || tool == "workspace.write_file" {
            return .fileWrite(path: context, toolName: policyTool)
        }
        return .tool(name: policyTool, context: context)
    }

    private static func workspaceWriteDiffPreview(path: String, content: String?, task: AgentTask) -> String {
        let proposed = content ?? ""
        guard let resolved = resolvedWorkspaceWritePreviewPath(path, task: task) else {
            return "Diff preview unavailable for disallowed workspace path `\(path)`."
        }
        let existingData = FileManager.default.contents(atPath: resolved.path)
        let existing = existingData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let existingPreview = String(existing.prefix(2_000))
        let proposedPreview = String(proposed.prefix(2_000))
        let existingSuffix = existing.count > existingPreview.count ? "\n... (current truncated)" : ""
        let proposedSuffix = proposed.count > proposedPreview.count ? "\n... (proposed truncated)" : ""
        return """
        Diff preview for \(resolved.relativeDisplayPath)
        --- current
        \(existingPreview)\(existingSuffix)
        +++ proposed
        \(proposedPreview)\(proposedSuffix)
        """
    }

    private static func resolvedWorkspaceWritePreviewPath(
        _ rawPath: String,
        task: AgentTask
    ) -> (path: String, relativeDisplayPath: String)? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("/") else { return nil }
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard !root.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
        guard candidate != root, candidate.hasPrefix(root + "/") else { return nil }
        let relative = localAgentRelativePath(candidate, root: root)
        guard localAgentWorkspaceWriteRelativePathIsAllowed(relative) else { return nil }
        guard localAgentWorkspaceWriteParentPathStillScoped(candidate, root: root) else { return nil }
        guard !localAgentWorkspaceWriteExistingDestinationIsSymlink(candidate) else { return nil }
        return (candidate, relative)
    }

    private static func approvalProviderDetail(
        tool: String,
        arguments: [String: LocalModelJSONValue],
        task: AgentTask,
        fallback: String?
    ) -> String? {
        if tool == "workspace.write_file",
           let path = arguments["path"]?.stringValue {
            return workspaceWriteDiffPreview(path: path, content: arguments["content"]?.stringValue, task: task)
        }
        if tool == "shell.exec" {
            return shellExecutionApprovalPreview(arguments: arguments, task: task)
        }
        if tool == "network.fetch" {
            return networkFetchApprovalPreview(arguments: arguments)
        }
        if tool == "browser.click" {
            return browserClickApprovalPreview(arguments: arguments)
        }
        if tool == "browser.type" {
            return browserTypeApprovalPreview(arguments: arguments)
        }
        return fallback
    }

    private static func shellExecutionApprovalPreview(arguments: [String: LocalModelJSONValue], task: AgentTask) -> String? {
        guard let command = arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        let cwd = arguments["cwd"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = cwd?.isEmpty == false ? cwd! : "."
        let timeout = min(max(arguments["timeout_seconds"]?.intValue ?? 20, 1), 60)
        let maxOutputBytes = min(max(arguments["max_output_bytes"]?.intValue ?? 12_000, 1), 50_000)
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        return """
        Shell command preview
        Working directory: \(workingDirectory)
        Workspace: \(workspacePath)
        Timeout: \(timeout)s
        Output cap: \(maxOutputBytes) bytes per stream
        Command:
        \(command)
        """
    }

    private static func networkFetchApprovalPreview(arguments: [String: LocalModelJSONValue]) -> String? {
        guard let url = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }
        let method = arguments["method"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "GET"
        let timeout = min(max(arguments["timeout_seconds"]?.intValue ?? 20, 1), 60)
        let maxResponseBytes = min(max(arguments["max_response_bytes"]?.intValue ?? 50_000, 1), 200_000)
        return """
        Network fetch preview
        Method: \(method)
        URL: \(url)
        Timeout: \(timeout)s
        Response cap: \(maxResponseBytes) bytes
        """
    }

    private static func browserClickApprovalPreview(arguments: [String: LocalModelJSONValue]) -> String? {
        guard let target = browserClickApprovalTarget(arguments: arguments) else {
            return nil
        }
        let role = firstStringArgument(["role"], in: arguments)
        return """
        Browser click preview
        Target: \(target)
        Role: \(role ?? "unspecified")
        Dangerous confirmations: disabled
        """
    }

    private static func browserTypeApprovalPreview(arguments: [String: LocalModelJSONValue]) -> String? {
        guard let target = browserInputApprovalTarget(arguments: arguments),
              let text = firstStringArgument(["text"], in: arguments) else {
            return nil
        }
        let clear = boolArgumentValue(arguments["clear"], default: true)
        return """
        Browser typing preview
        Target: \(target)
        Text length: \(text.count) characters
        Clear field first: \(clear ? "yes" : "no")
        Dangerous confirmations: disabled
        """
    }

    private static func browserClickApprovalTarget(arguments: [String: LocalModelJSONValue]) -> String? {
        browserActionApprovalTarget(arguments: arguments, allowPoint: true)
    }

    private static func browserInputApprovalTarget(arguments: [String: LocalModelJSONValue]) -> String? {
        browserActionApprovalTarget(arguments: arguments, allowPoint: false)
    }

    private static func browserApprovalTarget(tool: String, arguments: [String: LocalModelJSONValue]) -> String? {
        tool == "browser.type"
            ? browserInputApprovalTarget(arguments: arguments)
            : browserClickApprovalTarget(arguments: arguments)
    }

    private static func browserActionApprovalTarget(
        arguments: [String: LocalModelJSONValue],
        allowPoint: Bool
    ) -> String? {
        let analysisID = firstStringArgument(["analysisID", "analysis_id"], in: arguments)
        let controlID = firstStringArgument(["controlID", "control_id"], in: arguments)
        if let analysisID, let controlID {
            return "analysis:\(analysisID)#\(controlID)"
        }
        if let selector = firstStringArgument(["selector"], in: arguments) {
            return "selector:\(selector)"
        }
        if let label = firstStringArgument(["label", "name"], in: arguments) {
            if let role = firstStringArgument(["role"], in: arguments) {
                return "label:\(label) role:\(role)"
            }
            return "label:\(label)"
        }
        if let placeholder = firstStringArgument(["placeholder"], in: arguments) {
            return "placeholder:\(placeholder)"
        }
        if let testID = firstStringArgument(["testID", "test_id", "testid"], in: arguments) {
            return "testid:\(testID)"
        }
        if allowPoint,
           let x = arguments["x"]?.numberValue,
           let y = arguments["y"]?.numberValue {
            return "point:\(x),\(y)"
        }
        return nil
    }

    private static func isExplicitBrowserApprovalTool(_ tool: String) -> Bool {
        switch tool {
        case "browser.click", "browser.type":
            return true
        default:
            return false
        }
    }

    private static func boolArgumentValue(_ value: LocalModelJSONValue?, default defaultValue: Bool = false) -> Bool {
        switch value {
        case .bool(let flag):
            return flag
        case .string(let text):
            return ["1", "true", "yes"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return defaultValue
        }
    }

    private static func firstStringArgument(_ keys: [String], in arguments: [String: LocalModelJSONValue]) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func localAgentExplicitApprovalRequest(
        tool: String,
        arguments: [String: LocalModelJSONValue],
        task: AgentTask
    ) -> PermissionRequest? {
        switch tool {
        case "shell.exec":
            guard let command = arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                return nil
            }
            return .shell(command: command, toolName: policyToolName(for: tool))
        case "network.fetch":
            guard let url = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                return nil
            }
            return .network(url: url, toolName: policyToolName(for: tool))
        case "browser.click", "browser.type":
            guard let target = browserApprovalTarget(tool: tool, arguments: arguments) else {
                return nil
            }
            return .tool(name: policyToolName(for: tool), context: target)
        case "task.write_output":
            guard let path = arguments["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return .fileWrite(path: taskOutputPolicyPath(path, task: task), toolName: policyToolName(for: tool))
        case "workspace.write_file":
            guard let path = arguments["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return .fileWrite(path: path, toolName: policyToolName(for: tool))
        default:
            return nil
        }
    }

    private static func localAgentExplicitApprovalName(tool: String) -> String {
        switch tool {
        case "shell.exec":
            return "shell execution"
        case "network.fetch":
            return "network fetch"
        case "browser.click":
            return "browser click"
        case "browser.type":
            return "browser typing"
        case "task.write_output":
            return "task output write"
        case "workspace.write_file":
            return "workspace file write"
        default:
            return "tool execution"
        }
    }

    private static func localAgentExplicitApprovalDetail(
        tool: String,
        arguments: [String: LocalModelJSONValue]
    ) -> String? {
        switch tool {
        case "shell.exec":
            return arguments["command"]?.stringValue
        case "network.fetch":
            return arguments["url"]?.stringValue
        case "browser.click", "browser.type":
            return browserApprovalTarget(tool: tool, arguments: arguments)
        case "task.write_output", "workspace.write_file":
            return arguments["path"]?.stringValue
        default:
            return nil
        }
    }

    private static func taskOutputPolicyPath(_ path: String, task: AgentTask) -> String {
        guard !path.hasPrefix("/") else { return path }
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return path }
        return URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

    private static func policyStopResult(
        violation: AgentRuntimePolicyViolation,
        fallbackRequest: PermissionRequest,
        callID: String,
        tool: String,
        arguments: [String: LocalModelJSONValue],
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) -> AgentProcessResult {
        let request = violation.permissionRequest ?? fallbackRequest
        let grants = violation.approvalGrants.isEmpty
            ? PermissionBroker.approvalGrants(for: request)
            : violation.approvalGrants
        let providerDetail = approvalProviderDetail(
            tool: tool,
            arguments: arguments,
            task: task,
            fallback: violation.detail
        )
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .localMLX,
            request: request,
            reason: violation.reason,
            providerDetail: providerDetail,
            grants: grants
        )
        let eventType = violation.requiresApproval ? "local_agent.policy_approval_required" : "permission.denied"
        let eventPayload = violation.requiresApproval ? payload : violation.userMessage
        recordLocalAgentEvent(
            type: "local_agent.policy_decision",
            fields: [
                "status": violation.requiresApproval ? "approval_required" : "denied",
                "call_id": callID,
                "tool": tool,
                "policy_tool": policyToolName(for: tool),
                "reason": violation.reason
            ],
            task: task,
            run: run,
            modelContext: modelContext
        )
        modelContext.insert(TaskEvent(task: task, type: eventType, payload: eventPayload, run: run))
        recordLocalAgentEvent(
            type: "local_agent.blocked",
            fields: [
                "reason": violation.requiresApproval ? "policy_approval_required" : "policy_violation",
                "call_id": callID,
                "tool": tool
            ],
            task: task,
            run: run,
            modelContext: modelContext
        )

        if violation.requiresApproval {
            return AgentProcessResult(
                exitCode: -1,
                policyApprovalRequired: true,
                policyApprovalMessage: payload
            )
        }
        return AgentProcessResult(
            exitCode: -1,
            policyViolation: true,
            policyViolationMessage: violation.userMessage
        )
    }

    private static func requiresToolObservationBeforeFinal(task: AgentTask, prompt: String) -> Bool {
        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: prompt)
        let text = [
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.constraints.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " "),
            prompt
        ].joined(separator: " ")
        return TextOnlyRuntimeGuard.requestRequiresAction(text, scope: scope)
    }

    private static func localMemoryDiagnostics(from events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            guard case .diagnostic(let kind, let message) = event,
                  kind == "local_model.memory" else {
                return nil
            }
            return message
        }
    }

    private static func memoryDiagnosticLooksPressured(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("memory pressure") || lower.contains("out of memory") || lower.contains("oom") {
            return true
        }
        return lower.contains("memory limit") && (lower.contains("exceeded") || lower.contains("failed"))
    }

    @MainActor
    private static func recordBlockedPlanStepIfApplicable(
        actionID: String?,
        reason: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard let actionID else { return }
        let state = TaskPlanService.reconstruct(for: task)
        guard let plan = state.plan,
              let step = plan.steps.first(where: { $0.id == actionID }) else {
            return
        }
        TaskPlanService.recordStepProgress(
            type: TaskPlanEventTypes.stepBlocked,
            planID: plan.planID,
            stepID: step.id,
            status: .blocked,
            task: task,
            modelContext: modelContext,
            run: run,
            title: step.title,
            detail: reason,
            reason: reason
        )
    }

    private static func shouldReportToolWatchdog(
        observation: LocalAgentToolObservation,
        durationMs: Int,
        timeoutSeconds: Int
    ) -> Bool {
        if durationMs >= timeoutSeconds * 1_000 {
            return true
        }
        guard observation.status.lowercased() == "error" else {
            return false
        }
        let lower = observation.content.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("cancelled")
    }

    private static func bridgeResponseOK(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return true
        }
        return ok
    }

    nonisolated static func systemPrompt(capabilities: LocalAgentToolCapabilities = .current()) -> String {
        var actionExamples = [
            #"{"type":"tool_call","id":"stable-id","tool":"workspace.read_file","arguments":{"path":"relative/path.txt"}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"workspace.list_files","arguments":{"path":".","max_results":50}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"workspace.search","arguments":{"query":"needle","path":".","max_results":20}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"task.list_outputs","arguments":{"max_results":50}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"task.read_output","arguments":{"path":"outputs/turn_001.md","max_bytes":12000}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"browser.read_page","arguments":{"format":"markdown","limit":20000}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"browser.analyze","arguments":{"query":"Save","limit":20}}"#
        ]
        if capabilities.contains(.taskOutputWrite) {
            actionExamples.append(#"{"type":"tool_call","id":"stable-id","tool":"task.write_output","arguments":{"path":"report.md","content":"Task output content","overwrite":false}}"#)
        }
        if capabilities.contains(.workspaceWrite) {
            actionExamples.append(#"{"type":"tool_call","id":"stable-id","tool":"workspace.write_file","arguments":{"path":"relative/path.txt","content":"Full replacement file content","overwrite":true}}"#)
        }
        if capabilities.contains(.shellExecution) {
            actionExamples.append(#"{"type":"tool_call","id":"stable-id","tool":"shell.exec","arguments":{"command":"git status --short","cwd":".","timeout_seconds":20,"max_output_bytes":12000}}"#)
        }
        if capabilities.contains(.networkFetch) {
            actionExamples.append(#"{"type":"tool_call","id":"stable-id","tool":"network.fetch","arguments":{"url":"https://example.com/data.json","method":"GET","timeout_seconds":20,"max_response_bytes":50000}}"#)
        }
        if capabilities.contains(.browserClick) {
            actionExamples.append(#"{"type":"tool_call","id":"stable-id","tool":"browser.click","arguments":{"analysisID":"ana_...","controlID":"ctl_..."}}"#)
        }
        if capabilities.contains(.browserType) {
            actionExamples.append(#"{"type":"tool_call","id":"stable-id","tool":"browser.type","arguments":{"analysisID":"ana_...","controlID":"ctl_...","text":"search text","clear":true}}"#)
        }
        actionExamples.append(contentsOf: [
            #"{"type":"tool_call","id":"stable-id","tool":"jira.search","arguments":{"jql":"project = STAR ORDER BY updated DESC","max_results":10}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"github.search","arguments":{"query":"local mlx","repo":"susom/astra","type":"issue","state":"open","max_results":10}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"google_drive.search","arguments":{"query":"project plan","max_results":10}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"google_drive.read","arguments":{"file_id":"drive-file-id","max_bytes":4000}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"gmail.search","arguments":{"query":"from:person@example.com subject:invoice","max_results":5}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"gmail.read","arguments":{"message_id":"gmail-message-id","max_bytes":4000}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"slack.search","arguments":{"query":"release notes","max_results":5}}"#,
            #"{"type":"tool_call","id":"stable-id","tool":"slack.thread","arguments":{"channel_id":"C123","thread_ts":"1716920000.000100","max_results":10}}"#,
            #"{"type":"final","answer":"Answer grounded in tool observations."}"#,
            #"{"type":"ask_user","question":"Specific question needed to continue."}"#,
            #"{"type":"blocked","reason":"Specific blocker that requires user action."}"#,
            #"{"type":"cancelled","reason":"Cancellation reason."}"#,
            #"{"type":"plan","steps":["short step"]}"#
        ])

        var rules = [
            "Use `workspace.list_files` before reading an unknown path.",
            "Use `workspace.read_file` for file contents.",
            "Use `workspace.search` to find files or text before reading.",
            "Use `task.list_outputs` and `task.read_output` for current task output files.",
            "Use `browser.read_page` and `browser.analyze` for read-only inspection of ASTRA's current Shelf browser session.",
            "Browser changes in Local Agent beta are limited to `browser.click` and `browser.type`; do not request navigation, submit, upload, drag, keypress, script, download, or other browser mutation tools.",
            "Use `jira.search` for Jira issue lookup when the task asks about Jira.",
            "Use `github.search` for GitHub issue and pull request lookup when a GitHub connector is configured.",
            "Use `google_drive.search` for Google Drive file lookup and `google_drive.read` for bounded text summaries.",
            "Use `gmail.search` for Gmail message lookup and `gmail.read` for bounded message summaries.",
            "Use `slack.search` for Slack message lookup and `slack.thread` for bounded thread summaries."
        ]
        if capabilities.contains(.taskOutputWrite) {
            rules.append("Use `task.write_output` only for new standalone artifacts in the current task output folder.")
        }
        if capabilities.contains(.workspaceWrite) {
            rules.append("Use `workspace.write_file` only after ASTRA asks for and receives user approval. It replaces or creates a normal workspace file, records rollback evidence, and cannot write hidden or ASTRA metadata paths.")
        }
        if capabilities.contains(.shellExecution) {
            rules.append("Use `shell.exec` only after ASTRA asks for and receives user approval. Shell commands run in a scoped working directory with timeout and output caps.")
        }
        if capabilities.contains(.networkFetch) {
            rules.append("Use `network.fetch` only after ASTRA asks for and receives user approval. Fetches are GET/HEAD only, URL-scoped, timed, and response-capped.")
        }
        if capabilities.contains(.browserClick) {
            rules.append("Use `browser.click` only after ASTRA asks for and receives user approval. Prefer analysisID/controlID returned by `browser.analyze`; dangerous confirmations remain disabled.")
        }
        if capabilities.contains(.browserType) {
            rules.append("Use `browser.type` only after ASTRA asks for and receives user approval. Prefer analysisID/controlID returned by `browser.analyze`; dangerous confirmations remain disabled.")
        }
        let disabled = LocalAgentBetaToolSurface.highRiskCapabilities.filter { !capabilities.contains($0) }
        if !disabled.isEmpty {
            rules.append("Do not request disabled Local Agent capabilities: \(disabled.map(\.displayName).joined(separator: ", ")).")
        }
        rules.append(contentsOf: [
            "Never invent tool results. Only use observations returned by ASTRA.",
            "If a tool returns an error, repair the call or ask the user.",
            "Use `blocked` only when no ASTRA tool can make progress and user action is required.",
            "Use `cancelled` only when cancellation was requested or continuing would ignore cancellation."
        ])

        return """
        You are ASTRA Local Agent. You can reason locally, but ASTRA executes all tools.

        Return exactly one JSON object and no markdown.

        Local Agent Action Protocol:
        \(actionExamples.joined(separator: "\n"))

        Rules:
        \(rules.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}

enum LocalAgentRecoverySuggestions {
    static func suggestion(for reason: String) -> String? {
        switch reason {
        case "memory_pressure":
            return "Open Runtime settings, lower the Local MLX context limit, or install a smaller local model before retrying."
        case "invalid_action_repair_budget_exhausted":
            return "Retry with a narrower task, or switch to a provider CLI for action-heavy work until Local Agent reliability improves."
        case "missing_tool_observation_repair_budget_exhausted":
            return "Retry in Local Agent mode with a concrete tool-backed request, or use a provider CLI if the task must perform actions now."
        default:
            return nil
        }
    }
}

private extension JSONEncoder {
    static var sortedLocalAgentEventEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

final class LocalAgentCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: URLSessionTask] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let activeTasks: [URLSessionTask]
        lock.lock()
        cancelled = true
        activeTasks = Array(tasks.values)
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }

    func register(_ task: URLSessionTask) -> UUID {
        let id = UUID()
        let shouldCancel: Bool
        lock.lock()
        shouldCancel = cancelled
        tasks[id] = task
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }
}

enum LocalAgentCancellableDataLoader {
    static func data(
        for request: URLRequest,
        cancellationToken: LocalAgentCancellationToken?
    ) async throws -> (Data, URLResponse) {
        if cancellationToken?.isCancelled == true {
            throw CancellationError()
        }
        let state = URLSessionTaskCancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = URLSession.shared.dataTask(with: request) { data, response, error in
                    state.unregister()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                let registrationID = cancellationToken?.register(dataTask)
                state.set(task: dataTask, token: cancellationToken, registrationID: registrationID)
                dataTask.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }

    static func boundedData(
        for request: URLRequest,
        maxBytes: Int,
        cancellationToken: LocalAgentCancellationToken?
    ) async throws -> LocalAgentBoundedDataLoadResult {
        if cancellationToken?.isCancelled == true {
            throw CancellationError()
        }
        let loader = LocalAgentBoundedDataLoader(
            request: request,
            maxBytes: max(1, maxBytes),
            cancellationToken: cancellationToken
        )
        return try await loader.start()
    }
}

struct LocalAgentBoundedDataLoadResult: Sendable {
    var data: Data
    var response: URLResponse
    var truncated: Bool
}

enum LocalAgentNetworkFetchError: LocalizedError {
    case redirectDenied(URL)
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .redirectDenied(let url):
            return "Redirects are not allowed for Local Agent network.fetch: \(url.absoluteString)"
        case .missingResponse:
            return "The server did not return a response."
        }
    }
}

private final class LocalAgentBoundedDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let maxBytes: Int
    private let cancellationToken: LocalAgentCancellationToken?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalAgentBoundedDataLoadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var registrationID: UUID?
    private var response: URLResponse?
    private var data = Data()
    private var finished = false

    init(
        request: URLRequest,
        maxBytes: Int,
        cancellationToken: LocalAgentCancellationToken?
    ) {
        self.request = request
        self.maxBytes = maxBytes
        self.cancellationToken = cancellationToken
    }

    func start() async throws -> LocalAgentBoundedDataLoadResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let registrationID = cancellationToken?.register(task)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                self.registrationID = registrationID
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        let deniedURL = request.url ?? response.url ?? self.request.url ?? URL(fileURLWithPath: "/")
        finish(.failure(LocalAgentNetworkFetchError.redirectDenied(deniedURL)), cancelTask: true)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if !finished {
            self.response = response
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        var result: LocalAgentBoundedDataLoadResult?

        lock.lock()
        if !finished {
            let remaining = maxBytes - data.count
            if chunk.count > remaining {
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                if let response {
                    result = LocalAgentBoundedDataLoadResult(data: data, response: response, truncated: true)
                }
            } else {
                data.append(chunk)
            }
        }
        lock.unlock()

        if let result {
            finish(.success(result), cancelTask: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error), cancelTask: false)
            return
        }

        let result: Result<LocalAgentBoundedDataLoadResult, Error>
        lock.lock()
        if let response {
            result = .success(LocalAgentBoundedDataLoadResult(data: data, response: response, truncated: false))
        } else {
            result = .failure(LocalAgentNetworkFetchError.missingResponse)
        }
        lock.unlock()
        finish(result, cancelTask: false)
    }

    private func cancel() {
        finish(.failure(CancellationError()), cancelTask: true)
    }

    private func finish(_ result: Result<LocalAgentBoundedDataLoadResult, Error>, cancelTask: Bool) {
        let continuation: CheckedContinuation<LocalAgentBoundedDataLoadResult, Error>?
        let session: URLSession?
        let task: URLSessionDataTask?
        let registrationID: UUID?

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        session = self.session
        task = self.task
        registrationID = self.registrationID
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.registrationID = nil
        lock.unlock()

        if let registrationID {
            cancellationToken?.unregister(registrationID)
        }
        if cancelTask {
            task?.cancel()
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation?.resume(with: result)
    }
}

private final class URLSessionTaskCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var token: LocalAgentCancellationToken?
    private var registrationID: UUID?

    func set(
        task: URLSessionTask,
        token: LocalAgentCancellationToken?,
        registrationID: UUID?
    ) {
        lock.lock()
        self.task = task
        self.token = token
        self.registrationID = registrationID
        lock.unlock()
    }

    func cancel() {
        let task: URLSessionTask?
        lock.lock()
        task = self.task
        lock.unlock()
        task?.cancel()
    }

    func unregister() {
        let token: LocalAgentCancellationToken?
        let registrationID: UUID?
        lock.lock()
        token = self.token
        registrationID = self.registrationID
        self.task = nil
        self.token = nil
        self.registrationID = nil
        lock.unlock()
        if let token, let registrationID {
            token.unregister(registrationID)
        }
    }
}

struct LocalAgentToolObservation: Sendable, Equatable {
    private static let maxModelVisibleContentCharacters = 12_000

    var status: String
    var content: String
    var eventFields: [String: String] = [:]

    var modelVisibleContent: String {
        let payload: [String: String] = [
            "status": status,
            "content": modelVisibleContentBody
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "\(status): \(modelVisibleContentBody)"
        }
        return text
    }

    private var modelVisibleContentBody: String {
        guard content.count > Self.maxModelVisibleContentCharacters else {
            return content
        }
        return String(content.prefix(Self.maxModelVisibleContentCharacters))
            + "\n... (tool observation truncated to \(Self.maxModelVisibleContentCharacters) characters)"
    }
}

@MainActor
struct LocalAgentToolExecutor {
    nonisolated static let browserRequestTimeout: TimeInterval = 15

    let task: AgentTask
    let workspacePath: String
    let fileManager: FileManager = .default
    let secretStore: SecretStore
    let connectorTransport: any ConnectorHTTPTransport
    let requestTimeout: TimeInterval
    let capabilities: LocalAgentToolCapabilities
    let cancellationToken: LocalAgentCancellationToken?

    init(
        task: AgentTask,
        workspacePath: String,
        secretStore: SecretStore = KeychainSecretStore(),
        connectorTransport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport(),
        requestTimeout: TimeInterval = LocalAgentToolExecutor.browserRequestTimeout,
        capabilities: LocalAgentToolCapabilities = .current(),
        cancellationToken: LocalAgentCancellationToken? = nil
    ) {
        self.task = task
        self.workspacePath = workspacePath
        self.secretStore = secretStore
        self.connectorTransport = connectorTransport
        self.requestTimeout = requestTimeout
        self.capabilities = capabilities
        self.cancellationToken = cancellationToken
    }

    private static func browserClickApprovalTarget(arguments: [String: LocalModelJSONValue]) -> String? {
        browserActionApprovalTarget(arguments: arguments, allowPoint: true)
    }

    private static func browserInputApprovalTarget(arguments: [String: LocalModelJSONValue]) -> String? {
        browserActionApprovalTarget(arguments: arguments, allowPoint: false)
    }

    private static func browserActionApprovalTarget(
        arguments: [String: LocalModelJSONValue],
        allowPoint: Bool
    ) -> String? {
        let analysisID = firstStringArgument(["analysisID", "analysis_id"], in: arguments)
        let controlID = firstStringArgument(["controlID", "control_id"], in: arguments)
        if let analysisID, let controlID {
            return "analysis:\(analysisID)#\(controlID)"
        }
        if let selector = firstStringArgument(["selector"], in: arguments) {
            return "selector:\(selector)"
        }
        if let label = firstStringArgument(["label", "name"], in: arguments) {
            if let role = firstStringArgument(["role"], in: arguments) {
                return "label:\(label) role:\(role)"
            }
            return "label:\(label)"
        }
        if let placeholder = firstStringArgument(["placeholder"], in: arguments) {
            return "placeholder:\(placeholder)"
        }
        if let testID = firstStringArgument(["testID", "test_id", "testid"], in: arguments) {
            return "testid:\(testID)"
        }
        if allowPoint,
           let x = arguments["x"]?.numberValue,
           let y = arguments["y"]?.numberValue {
            return "point:\(x),\(y)"
        }
        return nil
    }

    private static func firstStringArgument(_ keys: [String], in arguments: [String: LocalModelJSONValue]) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func bridgeResponseOK(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return true
        }
        return ok
    }

    func execute(
        callID _: String,
        tool: String,
        arguments: [String: LocalModelJSONValue]
    ) async -> LocalAgentToolObservation {
        guard cancellationToken?.isCancelled != true else {
            return .init(status: "error", content: "Local Agent tool execution was cancelled before `\(tool)` started.")
        }
        if let disabledCapability = capabilities.disabledCapability(for: tool) {
            return .init(
                status: "error",
                content: "Local Agent capability '\(disabledCapability.displayName)' is disabled in Runtime settings."
            )
        }
        switch tool {
        case "workspace.read_file":
            return readFile(arguments: arguments)
        case "workspace.list_files":
            return listFiles(arguments: arguments)
        case "workspace.search":
            return searchWorkspace(arguments: arguments)
        case "workspace.write_file":
            return writeWorkspaceFile(arguments: arguments)
        case "shell.exec":
            return await executeShell(arguments: arguments)
        case "network.fetch":
            return await fetchNetwork(arguments: arguments)
        case "task.list_outputs":
            return listTaskOutputs(arguments: arguments)
        case "task.read_output":
            return readTaskOutput(arguments: arguments)
        case "task.write_output":
            return writeTaskOutput(arguments: arguments)
        case "browser.read_page":
            return await readBrowserPage(arguments: arguments)
        case "browser.analyze":
            return await analyzeBrowser(arguments: arguments)
        case "browser.click":
            return await clickBrowser(arguments: arguments)
        case "browser.type":
            return await typeBrowser(arguments: arguments)
        case "jira.search":
            let service = JiraConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.search(arguments: arguments)
            return JiraConnectorSearchService.observation(from: result)
        case "github.search":
            let service = GitHubConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.search(arguments: arguments)
            return GitHubConnectorSearchService.observation(from: result)
        case "google_drive.search":
            let service = GoogleDriveConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.search(arguments: arguments)
            return GoogleDriveConnectorSearchService.searchObservation(from: result)
        case "google_drive.read":
            let service = GoogleDriveConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.read(arguments: arguments)
            return GoogleDriveConnectorSearchService.readObservation(from: result)
        case "gmail.search":
            let service = GmailConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.search(arguments: arguments)
            return GmailConnectorSearchService.searchObservation(from: result)
        case "gmail.read":
            let service = GmailConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.read(arguments: arguments)
            return GmailConnectorSearchService.readObservation(from: result)
        case "slack.search":
            let service = SlackConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.search(arguments: arguments)
            return SlackConnectorSearchService.searchObservation(from: result)
        case "slack.thread":
            let service = SlackConnectorSearchService(
                connectors: TaskCapabilityResolver(task: task).allConnectors,
                contextText: [task.title, task.goal].joined(separator: "\n"),
                store: secretStore,
                transport: connectorTransport,
                cancellationToken: cancellationToken,
                requestTimeout: requestTimeout
            )
            let result = await service.thread(arguments: arguments)
            return SlackConnectorSearchService.threadObservation(from: result)
        default:
            return .init(
                status: "error",
                content: "Unsupported Local Agent tool `\(tool)`. Supported tools: \(capabilities.supportedToolNames.joined(separator: ", "))."
            )
        }
    }

    private func readFile(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        guard let path = arguments["path"]?.stringValue,
              let resolved = resolveAllowedPath(path, mustExist: true) else {
            return .init(status: "error", content: "Missing or disallowed `path` for workspace.read_file.")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .init(status: "error", content: "`\(path)` is not a readable file.")
        }
        let maxBytes = min(max(arguments["max_bytes"]?.intValue ?? 12_000, 1), 50_000)
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolved.path)) else {
            return .init(status: "error", content: "Could not read `\(path)`.")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else {
            return .init(status: "error", content: "Could not read `\(path)`.")
        }
        let clipped = Data(data.prefix(maxBytes))
        let text = String(data: clipped, encoding: .utf8) ?? clipped.map { String(format: "%02x", $0) }.joined()
        let suffix = data.count > maxBytes ? "\n... (truncated to \(maxBytes) bytes)" : ""
        return .init(status: "ok", content: "File: \(resolved.relativeDisplayPath)\n\(text)\(suffix)")
    }

    private func listFiles(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        let rawPath = arguments["path"]?.stringValue ?? "."
        guard let resolved = resolveAllowedPath(rawPath, mustExist: true) else {
            return .init(status: "error", content: "Missing or disallowed `path` for workspace.list_files.")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init(status: "error", content: "`\(rawPath)` is not a directory.")
        }
        let maxResults = min(max(arguments["max_results"]?.intValue ?? 50, 1), 200)
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: resolved.path, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .init(status: "error", content: "Could not list `\(rawPath)`.")
        }

        var rows: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let kind = values?.isDirectory == true ? "dir" : "file"
            let relative = localAgentRelativePath(url.path, root: resolved.path)
            rows.append("- [\(kind)] \(relative)")
            if rows.count >= maxResults { break }
        }
        return .init(
            status: "ok",
            content: rows.isEmpty ? "No files found in \(resolved.relativeDisplayPath)." : rows.joined(separator: "\n")
        )
    }

    private func searchWorkspace(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .init(status: "error", content: "Missing `query` for workspace.search.")
        }
        let rawPath = arguments["path"]?.stringValue ?? "."
        guard let resolved = resolveAllowedPath(rawPath, mustExist: true) else {
            return .init(status: "error", content: "Missing or disallowed `path` for workspace.search.")
        }

        let maxResults = min(max(arguments["max_results"]?.intValue ?? 20, 1), 100)
        let maxFiles = min(max(arguments["max_files"]?.intValue ?? 1_000, 1), 5_000)
        let matches = searchFiles(
            root: resolved,
            query: query,
            maxResults: maxResults,
            maxFiles: maxFiles
        )
        if matches.isEmpty {
            return .init(status: "ok", content: "No matches found for `\(query)` in \(resolved.relativeDisplayPath).")
        }
        return .init(status: "ok", content: matches.joined(separator: "\n"))
    }

    private func writeWorkspaceFile(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        guard let content = arguments["content"]?.stringValue else {
            return .init(status: "error", content: "Missing `content` for workspace.write_file.")
        }
        guard let path = arguments["path"]?.stringValue,
              let resolved = resolveWorkspaceWritePath(path) else {
            return .init(status: "error", content: "Missing or disallowed `path` for workspace.write_file.")
        }
        let data = Data(content.utf8)
        guard data.count <= 1_000_000 else {
            return .init(status: "error", content: "`content` exceeds the 1 MB workspace.write_file limit.")
        }

        let overwrite = boolArgument(arguments["overwrite"])
        let existed = fileManager.fileExists(atPath: resolved.path)
        if existed, !overwrite {
            return .init(status: "error", content: "`\(resolved.relativeDisplayPath)` already exists. Set `overwrite` to true to replace it.")
        }

        do {
            let parent = (resolved.path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            guard workspaceWriteDestinationStillScoped(resolved.path) else {
                return .init(status: "error", content: "Disallowed workspace path `\(resolved.relativeDisplayPath)`.")
            }
            let rollback = try writeWorkspaceRollbackEvidence(
                target: resolved,
                proposedContent: content,
                existed: existed
            )
            try data.write(to: URL(fileURLWithPath: resolved.path), options: .atomic)
            let action = existed ? "Updated" : "Created"
            return .init(
                status: "ok",
                content: """
                \(action) workspace file: \(resolved.relativeDisplayPath) (\(data.count) bytes)
                Rollback evidence: \(rollback.relativeDisplayPath)
                """,
                eventFields: [
                    "artifact": "workspace_file_edit",
                    "target_path": resolved.relativeDisplayPath,
                    "rollback_path": rollback.relativeDisplayPath,
                    "bytes": "\(data.count)",
                    "existed_before_write": String(existed)
                ]
            )
        } catch {
            return .init(
                status: "error",
                content: "Could not write workspace file `\(resolved.relativeDisplayPath)`: \(error.localizedDescription)"
            )
        }
    }

    private func executeShell(arguments: [String: LocalModelJSONValue]) async -> LocalAgentToolObservation {
        guard let command = arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .init(status: "error", content: "Missing `command` for shell.exec.")
        }
        guard command.count <= 8_000, !command.contains("\0") else {
            return .init(status: "error", content: "`command` is too long or contains invalid characters.")
        }
        guard let workingDirectory = resolveShellWorkingDirectory(arguments["cwd"]?.stringValue) else {
            return .init(status: "error", content: "Missing or disallowed `cwd` for shell.exec.")
        }

        let timeoutSeconds = min(max(arguments["timeout_seconds"]?.intValue ?? 20, 1), 60)
        let maxOutputBytes = min(max(arguments["max_output_bytes"]?.intValue ?? 12_000, 1), 50_000)
        let startedAt = Date()
        let result = await runShellProcess(
            command: command,
            workingDirectory: workingDirectory.path,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            maxOutputBytes: maxOutputBytes
        )
        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let status = result.timedOut || result.exitCode != 0 ? "error" : "ok"
        var sections = [
            "Shell command \(status == "ok" ? "finished" : "failed") with exit code \(result.exitCode) in \(durationMs)ms.",
            "Working directory: \(workingDirectory.relativeDisplayPath)",
            "Command: \(command)"
        ]
        if result.timedOut {
            sections.append("Timed out after \(timeoutSeconds)s.")
        }
        if !result.stdout.isEmpty {
            sections.append("stdout:\n\(result.stdout)")
        }
        if result.stdoutTruncated {
            sections.append("stdout truncated at \(maxOutputBytes) bytes.")
        }
        if !result.stderr.isEmpty {
            sections.append("stderr:\n\(result.stderr)")
        }
        if result.stderrTruncated {
            sections.append("stderr truncated at \(maxOutputBytes) bytes.")
        }
        return .init(
            status: status,
            content: sections.joined(separator: "\n"),
            eventFields: [
                "artifact": "shell_execution",
                "command": command,
                "working_directory": workingDirectory.relativeDisplayPath,
                "exit_code": "\(result.exitCode)",
                "duration_ms": "\(durationMs)",
                "timeout_seconds": "\(timeoutSeconds)",
                "timed_out": String(result.timedOut),
                "stdout_bytes": "\(result.stdoutBytes)",
                "stderr_bytes": "\(result.stderrBytes)",
                "stdout_truncated": String(result.stdoutTruncated),
                "stderr_truncated": String(result.stderrTruncated)
            ]
        )
    }

    private func fetchNetwork(arguments: [String: LocalModelJSONValue]) async -> LocalAgentToolObservation {
        guard let rawURL = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return .init(status: "error", content: "Missing or disallowed `url` for network.fetch.")
        }
        let method = arguments["method"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "GET"
        guard ["GET", "HEAD"].contains(method) else {
            return .init(status: "error", content: "`network.fetch` supports GET and HEAD only.")
        }
        let timeoutSeconds = min(max(arguments["timeout_seconds"]?.intValue ?? 20, 1), 60)
        let maxResponseBytes = min(max(arguments["max_response_bytes"]?.intValue ?? 50_000, 1), 200_000)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("text/plain, application/json;q=0.9, text/html;q=0.8, */*;q=0.1", forHTTPHeaderField: "Accept")

        let startedAt = Date()
        do {
            let result = try await LocalAgentCancellableDataLoader.boundedData(
                for: request,
                maxBytes: maxResponseBytes,
                cancellationToken: cancellationToken
            )
            let data = result.data
            let response = result.response
            guard cancellationToken?.isCancelled != true else {
                return .init(status: "error", content: "network.fetch cancelled.")
            }
            let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            let body = String(decoding: data, as: UTF8.self)
            let truncated = result.truncated
            let status = (200..<300).contains(statusCode) ? "ok" : "error"
            var sections = [
                "Network fetch \(status == "ok" ? "completed" : "failed") with HTTP \(statusCode) in \(durationMs)ms.",
                "URL: \(url.absoluteString)",
                "Method: \(method)",
                "Content-Type: \(contentType)",
                "Response bytes: \(data.count)"
            ]
            if !body.isEmpty {
                sections.append("Body:\n\(body)")
            }
            if truncated {
                sections.append("Body truncated at \(maxResponseBytes) bytes.")
            }
            return .init(
                status: status,
                content: sections.joined(separator: "\n"),
                eventFields: [
                    "artifact": "network_fetch",
                    "url": url.absoluteString,
                    "method": method,
                    "status_code": "\(statusCode)",
                    "duration_ms": "\(durationMs)",
                    "response_bytes": "\(data.count)",
                    "response_truncated": String(truncated),
                    "content_type": contentType
                ]
            )
        } catch {
            let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            return .init(
                status: "error",
                content: "network.fetch failed for \(url.absoluteString): \(error.localizedDescription)",
                eventFields: [
                    "artifact": "network_fetch",
                    "url": url.absoluteString,
                    "method": method,
                    "status_code": "error",
                    "duration_ms": "\(durationMs)",
                    "response_bytes": "0",
                    "response_truncated": "false",
                    "content_type": "unknown",
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func listTaskOutputs(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        let maxResults = min(max(arguments["max_results"]?.intValue ?? 50, 1), 200)
        let files = taskOutputFiles(maxResults: maxResults)
        guard !files.isEmpty else {
            return .init(status: "ok", content: "No current task output files found.")
        }
        let rows = files.map { file in
            "- \(file.relativePath) (\(file.size) bytes)"
        }
        return .init(status: "ok", content: rows.joined(separator: "\n"))
    }

    private func readTaskOutput(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        guard let path = arguments["path"]?.stringValue,
              let resolved = resolveTaskOutputPath(path) else {
            return .init(status: "error", content: "Missing or disallowed `path` for task.read_output.")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .init(status: "error", content: "`\(path)` is not a readable task output file.")
        }
        let maxBytes = min(max(arguments["max_bytes"]?.intValue ?? 12_000, 1), 50_000)
        guard let data = fileManager.contents(atPath: resolved.path) else {
            return .init(status: "error", content: "Could not read task output `\(path)`.")
        }
        let clipped = data.prefix(maxBytes)
        let text = String(data: clipped, encoding: .utf8) ?? clipped.map { String(format: "%02x", $0) }.joined()
        let suffix = data.count > maxBytes ? "\n... (truncated to \(maxBytes) bytes)" : ""
        return .init(status: "ok", content: "Task output: \(resolved.relativeDisplayPath)\n\(text)\(suffix)")
    }

    private func writeTaskOutput(arguments: [String: LocalModelJSONValue]) -> LocalAgentToolObservation {
        guard let content = arguments["content"]?.stringValue else {
            return .init(status: "error", content: "Missing `content` for task.write_output.")
        }
        guard let path = arguments["path"]?.stringValue,
              let resolved = resolveTaskOutputWritePath(path) else {
            return .init(status: "error", content: "Missing or disallowed `path` for task.write_output.")
        }
        let data = Data(content.utf8)
        guard data.count <= 1_000_000 else {
            return .init(status: "error", content: "`content` exceeds the 1 MB task.write_output limit.")
        }
        let overwrite = boolArgument(arguments["overwrite"])
        if fileManager.fileExists(atPath: resolved.path), !overwrite {
            return .init(status: "error", content: "`\(resolved.relativeDisplayPath)` already exists. Set `overwrite` to true to replace it.")
        }

        do {
            try fileManager.createDirectory(
                atPath: (resolved.path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            guard taskOutputWriteDestinationStillScoped(resolved.path) else {
                return .init(status: "error", content: "Disallowed task output path `\(resolved.relativeDisplayPath)`.")
            }
            try data.write(to: URL(fileURLWithPath: resolved.path), options: .atomic)
            return .init(
                status: "ok",
                content: "Wrote task output: \(resolved.relativeDisplayPath) (\(data.count) bytes)"
            )
        } catch {
            return .init(
                status: "error",
                content: "Could not write task output `\(resolved.relativeDisplayPath)`: \(error.localizedDescription)"
            )
        }
    }

    private func readBrowserPage(arguments: [String: LocalModelJSONValue]) async -> LocalAgentToolObservation {
        let format = arguments["format"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFormat = ["text", "markdown", "json"].contains(format ?? "") ? format! : "markdown"
        let limit = min(max(arguments["limit"]?.intValue ?? 20_000, 1), 50_000)
        return await requestBrowserBridge(
            path: "/readPage",
            queryItems: [
                URLQueryItem(name: "format", value: normalizedFormat),
                URLQueryItem(name: "limit", value: String(limit))
            ],
            label: "browser.read_page"
        )
    }

    private func analyzeBrowser(arguments: [String: LocalModelJSONValue]) async -> LocalAgentToolObservation {
        var items = [
            URLQueryItem(name: "v2", value: "true")
        ]
        if let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }
        if let limit = arguments["limit"]?.intValue {
            items.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))))
        }
        if boolArgument(arguments["full"]) {
            items.append(URLQueryItem(name: "full", value: "true"))
        }
        return await requestBrowserBridge(path: "/analyze", queryItems: items, label: "browser.analyze")
    }

    private func clickBrowser(arguments: [String: LocalModelJSONValue]) async -> LocalAgentToolObservation {
        guard let target = Self.browserClickApprovalTarget(arguments: arguments),
              let object = browserClickRequestObject(arguments: arguments) else {
            return .init(status: "error", content: "Missing target for browser.click.")
        }
        return await requestBrowserBridgeJSON(
            path: "/click",
            object: object,
            label: "browser.click",
            eventFields: [
                "artifact": "browser_mutation",
                "action": "click",
                "target": target,
                "endpoint": "/click"
            ]
        )
    }

    private func typeBrowser(arguments: [String: LocalModelJSONValue]) async -> LocalAgentToolObservation {
        guard let target = Self.browserInputApprovalTarget(arguments: arguments),
              let object = browserTypeRequestObject(arguments: arguments) else {
            return .init(status: "error", content: "Missing target or text for browser.type.")
        }
        let textChars = Self.firstStringArgument(["text"], in: arguments)?.count ?? 0
        return await requestBrowserBridgeJSON(
            path: "/type",
            object: object,
            label: "browser.type",
            eventFields: [
                "artifact": "browser_mutation",
                "action": "type",
                "target": target,
                "endpoint": "/type",
                "text_chars": "\(textChars)"
            ]
        )
    }

    private func requestBrowserBridge(
        path: String,
        queryItems: [URLQueryItem],
        label: String
    ) async -> LocalAgentToolObservation {
        let environment = ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id)
        guard let endpoint = environment["ASTRA_BROWSER_URL"],
              let baseURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .init(status: "error", content: "No active ASTRA Shelf browser bridge is available for this task.")
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        ) else {
            return .init(status: "error", content: "Invalid ASTRA Shelf browser bridge endpoint.")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            return .init(status: "error", content: "Invalid ASTRA Shelf browser bridge request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = environment["ASTRA_BROWSER_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let debugCapture = environment[BrowserFailureDebugCapture.environmentVariable], !debugCapture.isEmpty {
            request.setValue(debugCapture, forHTTPHeaderField: "X-ASTRA-Browser-Debug-Capture")
        }

        do {
            let (data, response) = try await LocalAgentCancellableDataLoader.data(
                for: request,
                cancellationToken: cancellationToken
            )
            guard cancellationToken?.isCancelled != true else {
                return .init(status: "error", content: "\(label) cancelled.")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .init(
                    status: "error",
                    content: "\(label) returned HTTP \(http.statusCode): \(String(body.prefix(1_000)))"
                )
            }
            return .init(status: "ok", content: "\(label):\n\(body)")
        } catch {
            return .init(status: "error", content: "\(label) failed: \(error.localizedDescription)")
        }
    }

    private func requestBrowserBridgeJSON(
        path: String,
        object: [String: Any],
        label: String,
        eventFields: [String: String]
    ) async -> LocalAgentToolObservation {
        let environment = ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id)
        guard let endpoint = environment["ASTRA_BROWSER_URL"],
              let baseURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .init(status: "error", content: "No active ASTRA Shelf browser bridge is available for this task.")
        }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .init(status: "error", content: "Invalid \(label) request body.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = environment["ASTRA_BROWSER_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let debugCapture = environment[BrowserFailureDebugCapture.environmentVariable], !debugCapture.isEmpty {
            request.setValue(debugCapture, forHTTPHeaderField: "X-ASTRA-Browser-Debug-Capture")
        }

        do {
            let (data, response) = try await LocalAgentCancellableDataLoader.data(
                for: request,
                cancellationToken: cancellationToken
            )
            guard cancellationToken?.isCancelled != true else {
                return .init(status: "error", content: "\(label) cancelled.")
            }
            let responseText = String(data: data, encoding: .utf8) ?? ""
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bridgeOK = Self.bridgeResponseOK(data)
            let status = (200..<300).contains(httpStatus) && bridgeOK ? "ok" : "error"
            var fields = eventFields
            fields["http_status"] = "\(httpStatus)"
            fields["bridge_ok"] = String(bridgeOK)
            fields["response_chars"] = "\(responseText.count)"
            return .init(
                status: status,
                content: "\(label) HTTP \(httpStatus):\n\(String(responseText.prefix(50_000)))",
                eventFields: fields
            )
        } catch {
            var fields = eventFields
            fields["http_status"] = "error"
            fields["bridge_ok"] = "false"
            fields["response_chars"] = "0"
            fields["error"] = error.localizedDescription
            return .init(
                status: "error",
                content: "\(label) failed: \(error.localizedDescription)",
                eventFields: fields
            )
        }
    }

    private func browserClickRequestObject(arguments: [String: LocalModelJSONValue]) -> [String: Any]? {
        var object: [String: Any] = ["allowDangerous": false]
        if let analysisID = Self.firstStringArgument(["analysisID", "analysis_id"], in: arguments) {
            object["analysisID"] = analysisID
        }
        if let controlID = Self.firstStringArgument(["controlID", "control_id"], in: arguments) {
            object["controlID"] = controlID
        }
        if let selector = Self.firstStringArgument(["selector"], in: arguments) {
            object["selector"] = selector
        }
        if let label = Self.firstStringArgument(["label", "name"], in: arguments) {
            object["label"] = label
        }
        if let role = Self.firstStringArgument(["role"], in: arguments) {
            object["role"] = role
        }
        if let text = Self.firstStringArgument(["text"], in: arguments) {
            object["text"] = text
        }
        if let placeholder = Self.firstStringArgument(["placeholder"], in: arguments) {
            object["placeholder"] = placeholder
        }
        if let testID = Self.firstStringArgument(["testID", "test_id", "testid"], in: arguments) {
            object["testID"] = testID
        }
        if let x = arguments["x"]?.numberValue {
            object["x"] = x
        }
        if let y = arguments["y"]?.numberValue {
            object["y"] = y
        }
        return object.count > 1 ? object : nil
    }

    private func browserTypeRequestObject(arguments: [String: LocalModelJSONValue]) -> [String: Any]? {
        guard let text = Self.firstStringArgument(["text"], in: arguments) else {
            return nil
        }
        var object: [String: Any] = [
            "text": text,
            "allowDangerous": false
        ]
        if let analysisID = Self.firstStringArgument(["analysisID", "analysis_id"], in: arguments) {
            object["analysisID"] = analysisID
        }
        if let controlID = Self.firstStringArgument(["controlID", "control_id"], in: arguments) {
            object["controlID"] = controlID
        }
        if let selector = Self.firstStringArgument(["selector"], in: arguments) {
            object["selector"] = selector
        }
        if let label = Self.firstStringArgument(["label", "name"], in: arguments) {
            object["label"] = label
        }
        if let role = Self.firstStringArgument(["role"], in: arguments) {
            object["role"] = role
        }
        if let placeholder = Self.firstStringArgument(["placeholder"], in: arguments) {
            object["placeholder"] = placeholder
        }
        if let testID = Self.firstStringArgument(["testID", "test_id", "testid"], in: arguments) {
            object["testID"] = testID
        }
        guard object.keys.contains(where: { $0 != "text" && $0 != "allowDangerous" && $0 != "clear" }) else {
            return nil
        }
        object["text"] = text
        object["clear"] = arguments["clear"].map(boolArgument) ?? true
        return object
    }

    private func boolArgument(_ value: LocalModelJSONValue?) -> Bool {
        switch value {
        case .bool(let flag):
            return flag
        case .string(let text):
            return ["1", "true", "yes"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }

    private struct ShellExecutionResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var stdoutBytes: Int
        var stderrBytes: Int
        var stdoutTruncated: Bool
        var stderrTruncated: Bool
        var timedOut: Bool
    }

    private final class CappedOutputBuffer: @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var text = ""
        private var totalBytes = 0
        private var truncated = false

        init(maxBytes: Int) {
            self.maxBytes = max(0, maxBytes)
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            totalBytes += data.count
            let remaining = maxBytes - text.utf8.count
            guard remaining > 0 else {
                truncated = true
                return
            }
            if data.count > remaining {
                text += String(decoding: data.prefix(remaining), as: UTF8.self)
                truncated = true
            } else {
                text += String(decoding: data, as: UTF8.self)
            }
        }

        func snapshot() -> (text: String, totalBytes: Int, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (text, totalBytes, truncated)
        }
    }

    private func resolveShellWorkingDirectory(_ rawPath: String?) -> ResolvedPath? {
        let requested = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = resolveAllowedPath(requested?.isEmpty == false ? requested! : ".", mustExist: true) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    private func runShellProcess(
        command: String,
        workingDirectory: String,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int
    ) async -> ShellExecutionResult {
        let environment = shellExecutionEnvironment()
        return await withCheckedContinuation { continuation in
            let process = AgentExecutionScopedProcess(
                executablePath: "/bin/zsh",
                arguments: ["-lc", command],
                currentDirectory: workingDirectory,
                environment: environment
            )
            let stdout = CappedOutputBuffer(maxBytes: maxOutputBytes)
            let stderr = CappedOutputBuffer(maxBytes: maxOutputBytes)
            let lock = NSLock()
            var didResume = false
            var didTimeout = false

            func finish(exitCode: Int32, drainHandles: Bool = true) {
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                let timedOut = didTimeout
                lock.unlock()

                process.stdoutFileHandle.readabilityHandler = nil
                process.stderrFileHandle.readabilityHandler = nil
                if drainHandles {
                    stdout.append(process.stdoutFileHandle.readDataToEndOfFile())
                    stderr.append(process.stderrFileHandle.readDataToEndOfFile())
                }
                let stdoutSnapshot = stdout.snapshot()
                let stderrSnapshot = stderr.snapshot()
                continuation.resume(returning: ShellExecutionResult(
                    exitCode: exitCode,
                    stdout: stdoutSnapshot.text,
                    stderr: stderrSnapshot.text,
                    stdoutBytes: stdoutSnapshot.totalBytes,
                    stderrBytes: stderrSnapshot.totalBytes,
                    stdoutTruncated: stdoutSnapshot.truncated,
                    stderrTruncated: stderrSnapshot.truncated,
                    timedOut: timedOut
                ))
            }

            process.stdoutFileHandle.readabilityHandler = { handle in
                stdout.append(handle.availableData)
            }
            process.stderrFileHandle.readabilityHandler = { handle in
                stderr.append(handle.availableData)
            }
            process.terminationHandler = { process in
                finish(exitCode: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                stderr.append(Data(error.localizedDescription.utf8))
                finish(exitCode: -1, drainHandles: false)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                guard process.isRunning else { return }
                lock.lock()
                didTimeout = true
                lock.unlock()
                process.requestCancellation(reason: "local_agent_shell_timeout")
            }
        }
    }

    private func shellExecutionEnvironment() -> [String: String] {
        var environment = AgentRuntimeProcessRunner.environment(
            phase: "local-agent-shell",
            task: task,
            taskEnv: AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task),
            includeClaudeTeamFlag: false
        )
        environment["HOME"] = NSHomeDirectory()
        return environment
    }

    private func searchFiles(
        root: ResolvedPath,
        query: String,
        maxResults: Int,
        maxFiles: Int
    ) -> [String] {
        let normalizedQuery = query.lowercased()
        let rootURL = URL(fileURLWithPath: root.path)
        var isDirectory: ObjCBool = false
        let rootIsDirectory = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
        var rows: [String] = []
        var scannedFiles = 0

        func scan(_ url: URL, enumerator: FileManager.DirectoryEnumerator?) -> Bool {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if shouldSkipSearchDirectory(name: name) {
                    enumerator?.skipDescendants()
                }
                return false
            }
            guard values?.isRegularFile == true || !rootIsDirectory else { return false }
            scannedFiles += 1
            if scannedFiles > maxFiles { return true }

            let display = displayPath(url.standardizedFileURL.path, roots: allowedRootsForDisplay())
            if name.lowercased().contains(normalizedQuery) {
                rows.append("- \(display): filename match")
            } else if let snippet = firstTextMatchSnippet(url: url, query: query) {
                rows.append("- \(display): \(snippet)")
            }
            return rows.count >= maxResults
        }

        if rootIsDirectory,
           let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
           ) {
            for case let url as URL in enumerator {
                if scan(url, enumerator: enumerator) { break }
            }
        } else {
            _ = scan(rootURL, enumerator: nil)
        }

        if scannedFiles >= maxFiles, rows.count < maxResults {
            rows.append("... (search stopped after \(maxFiles) files)")
        }
        return rows
    }

    private func firstTextMatchSnippet(url: URL, query: String) -> String? {
        let maxBytes = 200_000
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let context = 80
        let lower = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldSkipSearchDirectory(name: String) -> Bool {
        let ignored: Set<String> = [".git", ".hg", ".svn", ".build", ".swiftpm", ".runtime-bin", ".local-agent", "DerivedData", "node_modules"]
        return ignored.contains(name)
    }

    private struct TaskOutputFile {
        var path: String
        var relativePath: String
        var size: Int64
    }

    private func taskOutputFiles(maxResults: Int) -> [TaskOutputFile] {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty,
              let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: taskFolder, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var files: [TaskOutputFile] = []
        for case let url as URL in enumerator {
            let relative = localAgentRelativePath(url.standardizedFileURL.path, root: taskFolder)
            if shouldSkipTaskOutputRelativePath(relative) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files.append(TaskOutputFile(
                path: url.standardizedFileURL.path,
                relativePath: relative,
                size: Int64(values?.fileSize ?? 0)
            ))
            if files.count >= maxResults { break }
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func resolveTaskOutputPath(_ rawPath: String) -> ResolvedPath? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("/") else { return nil }
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return nil }

        let root = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let candidate = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard candidate == root || candidate.hasPrefix(root + "/") else { return nil }
        let relative = localAgentRelativePath(candidate, root: root)
        guard !shouldSkipTaskOutputRelativePath(relative) else { return nil }
        return ResolvedPath(path: candidate, relativeDisplayPath: relative)
    }

    private func resolveTaskOutputWritePath(_ rawPath: String) -> ResolvedPath? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("/") else { return nil }
        guard let root = taskOutputRootPath() else { return nil }
        let candidate = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
        guard candidate != root, candidate.hasPrefix(root + "/") else { return nil }
        guard taskOutputParentPathStillScoped(candidate, root: root) else { return nil }
        guard !taskOutputExistingDestinationIsSymlink(candidate) else { return nil }
        let relative = localAgentRelativePath(candidate, root: root)
        guard !shouldSkipTaskOutputRelativePath(relative) else { return nil }
        return ResolvedPath(path: candidate, relativeDisplayPath: relative)
    }

    private func taskOutputWriteDestinationStillScoped(_ path: String) -> Bool {
        guard let root = taskOutputRootPath() else { return false }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate != root, candidate.hasPrefix(root + "/") else { return false }
        guard taskOutputParentPathStillScoped(candidate, root: root) else { return false }
        return !taskOutputExistingDestinationIsSymlink(candidate)
    }

    private func taskOutputParentPathStillScoped(_ path: String, root: String) -> Bool {
        let parent = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return parent == root || parent.hasPrefix(root + "/")
    }

    private func taskOutputExistingDestinationIsSymlink(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func taskOutputRootPath() -> String? {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return nil }
        return URL(fileURLWithPath: taskFolder, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func shouldSkipTaskOutputRelativePath(_ relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard normalized != ".", !normalized.isEmpty else { return false }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = components.first else { return false }
        if first.hasPrefix(".") {
            return true
        }
        if !TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: normalized) {
            return true
        }
        return false
    }

    private struct ResolvedPath {
        var path: String
        var relativeDisplayPath: String
    }

    private func resolveAllowedPath(_ rawPath: String, mustExist: Bool) -> ResolvedPath? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }

        let base = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : base.appendingPathComponent(trimmed)
        let standardized = candidate.standardizedFileURL
        let resolvedPath = (mustExist ? standardized.resolvingSymlinksInPath() : standardized).path

        let roots = allowedRoots().map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        guard roots.contains(where: { root in
            resolvedPath == root || resolvedPath.hasPrefix(root + "/")
        }) else {
            return nil
        }
        return ResolvedPath(path: resolvedPath, relativeDisplayPath: displayPath(resolvedPath, roots: roots))
    }

    private func resolveWorkspaceWritePath(_ rawPath: String) -> ResolvedPath? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard !root.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
        guard candidate != root, candidate.hasPrefix(root + "/") else { return nil }
        let relative = localAgentRelativePath(candidate, root: root)
        guard localAgentWorkspaceWriteRelativePathIsAllowed(relative) else { return nil }
        guard localAgentWorkspaceWriteParentPathStillScoped(candidate, root: root) else { return nil }
        guard !localAgentWorkspaceWriteExistingDestinationIsSymlink(candidate) else { return nil }
        return ResolvedPath(path: candidate, relativeDisplayPath: relative)
    }

    private func workspaceWriteDestinationStillScoped(_ path: String) -> Bool {
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate != root, candidate.hasPrefix(root + "/") else { return false }
        let relative = localAgentRelativePath(candidate, root: root)
        guard localAgentWorkspaceWriteRelativePathIsAllowed(relative) else { return false }
        guard localAgentWorkspaceWriteParentPathStillScoped(candidate, root: root) else { return false }
        return !localAgentWorkspaceWriteExistingDestinationIsSymlink(candidate)
    }

    private func writeWorkspaceRollbackEvidence(
        target: ResolvedPath,
        proposedContent: String,
        existed: Bool
    ) throws -> ResolvedPath {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rollbackRoot = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent(".local-agent", isDirectory: true)
            .appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: rollbackRoot, withIntermediateDirectories: true, attributes: nil)
        let safeName = target.relativeDisplayPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let rollbackURL = rollbackRoot
            .appendingPathComponent("\(UUID().uuidString)-\(safeName).rollback.txt")

        let previousContent: String
        if existed, let data = fileManager.contents(atPath: target.path) {
            previousContent = String(data: data, encoding: .utf8)
                ?? data.map { String(format: "%02x", $0) }.joined()
        } else {
            previousContent = "<file did not exist before workspace.write_file>"
        }
        let evidence = """
        Workspace write rollback evidence
        Target: \(target.relativeDisplayPath)
        Existed before write: \(existed)
        Previous bytes: \(Data(previousContent.utf8).count)
        Proposed bytes: \(Data(proposedContent.utf8).count)

        Previous content:
        \(previousContent)
        """
        try evidence.write(to: rollbackURL, atomically: true, encoding: .utf8)
        let root = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let path = rollbackURL.standardizedFileURL.path
        return ResolvedPath(path: path, relativeDisplayPath: localAgentRelativePath(path, root: root))
    }

    private func allowedRootsForDisplay() -> [String] {
        allowedRoots().map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
    }

    private func allowedRoots() -> [String] {
        var roots = [workspacePath, TaskWorkspaceAccess(task: task).taskFolder]
        roots.append(contentsOf: TaskWorkspaceAccess(task: task).runtimeAdditionalPaths)
        var seen = Set<String>()
        return roots
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func displayPath(_ path: String, roots: [String]) -> String {
        for root in roots.sorted(by: { $0.count > $1.count }) {
            if path == root { return "." }
            if path.hasPrefix(root + "/") {
                return String(path.dropFirst(root.count + 1))
            }
        }
        return path
    }

}

private func localAgentRelativePath(_ path: String, root: String) -> String {
    if path == root { return "." }
    if path.hasPrefix(root + "/") {
        return String(path.dropFirst(root.count + 1))
    }
    return path
}

private func localAgentWorkspaceWriteParentPathStillScoped(_ path: String, root: String) -> Bool {
    let parent = URL(fileURLWithPath: path)
        .deletingLastPathComponent()
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    return parent == root || parent.hasPrefix(root + "/")
}

private func localAgentWorkspaceWriteExistingDestinationIsSymlink(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
}

private func localAgentWorkspaceWriteRelativePathIsAllowed(_ relativePath: String) -> Bool {
    let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
    guard normalized != ".", !normalized.isEmpty else { return false }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let first = components.first else { return false }
    if first == ".git" || first == ".astra" || first == ".agentflow" || first == ".runtime-bin" || first == ".local-agent" {
        return false
    }
    return components.allSatisfy { !$0.hasPrefix(".") }
}

@MainActor
final class LocalAgentInferenceClient {
    private var activeProcess: AgentExecutionScopedProcess?
    // The persistent-session machinery runs on background threads (event reader, timers,
    // termination handler), so it is nonisolated and synchronized by `sessionLock` + the
    // session's own lock rather than by the class's @MainActor isolation.
    private nonisolated let sessionLock = NSLock()
    private nonisolated(unsafe) var session: LocalAgentPersistentSession?

    func cancel() {
        activeProcess?.requestCancellation(reason: "cancelled_by_user")
        activeProcess = nil
        shutdownSession()
    }

    /// Tears down the persistent `serve` helper, if one is running. Safe to call when none
    /// exists. The orchestrator calls this once its run finishes (and on cancellation).
    func shutdown() {
        shutdownSession()
    }

    func generate(
        messages: [LocalModelChatMessage],
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        model: String,
        modelDirectory: String,
        permissionPolicy: PermissionPolicy,
        timeoutSeconds: TimeInterval
    ) async -> LocalAgentModelTurnResult {
        let requestDirectory = (TaskWorkspaceAccess(task: task).taskFolder as NSString)
            .appendingPathComponent(".local-agent")
        try? FileManager.default.createDirectory(atPath: requestDirectory, withIntermediateDirectories: true)
        let requestPath = (requestDirectory as NSString).appendingPathComponent("request-\(UUID().uuidString).json")
        let requestMessages = LocalModelInputMedia.attachingImages(from: task.inputs, to: messages)
        let request = LocalModelRunRequest(
            prompt: requestMessages.last?.content ?? "",
            messages: requestMessages,
            model: model,
            modelDirectory: modelDirectory.isEmpty ? nil : modelDirectory,
            permissionMode: permissionPolicy.rawValue,
            experimentalToolsEnabled: false,
            maxContextTokens: LocalModelSettingsStore.maxContextTokens(),
            maxOutputTokens: LocalModelSettingsStore.maxOutputTokens(),
            memoryBudgetBytes: LocalModelRunBudgetResolver.memoryBudgetBytes(modelDirectory: modelDirectory),
            cacheLimitBytes: LocalModelRunBudgetResolver.cacheLimitBytes(modelDirectory: modelDirectory),
            keepWarmTTLSeconds: LocalModelSettingsStore.keepWarmTTLSeconds()
        )
        if let data = try? JSONEncoder().encode(request) {
            try? data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
        }

        var environment = AgentRuntimeProcessRunner.environment(
            phase: "local-agent",
            task: task,
            taskEnv: AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task).merging([
                "ASTRA_LOCAL_MODEL_PROTOCOL_FD": String(LocalMLXRuntime.protocolFileDescriptor),
                "ASTRA_LOCAL_MODEL_CONTROL_FD": String(LocalMLXRuntime.controlFileDescriptor),
                "ASTRA_LOCAL_MODEL_PROVIDER_ENABLED": LocalModelSettingsStore.providerEnabled() ? "1" : "0",
                "ASTRA_LOCAL_MODEL_EXPERIMENTAL_TOOLS": "0"
            ], uniquingKeysWith: { _, new in new }),
            includeClaudeTeamFlag: false
        )
        environment["HOME"] = NSHomeDirectory()

        if LocalModelSettingsStore.persistentHelperEnabled() {
            return await generatePersistent(
                executablePath: executablePath,
                requestPath: requestPath,
                currentDirectory: workspacePath,
                environment: environment,
                timeoutSeconds: timeoutSeconds
            )
        }

        return await runProcess(
            executablePath: executablePath,
            arguments: ["run", "--request-file", requestPath],
            currentDirectory: workspacePath,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> LocalAgentModelTurnResult {
        await withCheckedContinuation { continuation in
            let process = AgentExecutionScopedProcess(
                executablePath: executablePath,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment,
                dedicatedEventFileDescriptor: LocalMLXRuntime.protocolFileDescriptor,
                dedicatedControlFileDescriptor: LocalMLXRuntime.controlFileDescriptor
            )
            activeProcess = process

            let lineBuffer = AgentLockedBuffer()
            let errorOutput = AgentLockedBuffer()
            let state = LocalAgentInferenceState()

            let handleLine: (String) -> Void = { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                state.recordEnvelopeTelemetry(line: trimmed)
                for event in LocalModelProtocolParser.agentEvents(from: line) {
                    state.record(event)
                }
            }

            process.eventFileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }
                lineBuffer.appendAndProcessLines(chunk, handleLine)
            }
            process.stderrFileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }
                errorOutput.append(chunk)
            }

            let resumeLock = NSLock()
            var didResume = false
            let resumeOnce: (LocalAgentModelTurnResult) -> Void = { result in
                resumeLock.lock()
                guard !didResume else {
                    resumeLock.unlock()
                    return
                }
                didResume = true
                resumeLock.unlock()
                continuation.resume(returning: result)
            }

            let timeoutWorkItem = DispatchWorkItem { [weak process, weak state] in
                guard process?.isRunning == true else { return }
                state?.markTimedOut()
                process?.requestCancellation(reason: "local_agent_timeout")
            }

            process.terminationHandler = { [weak self] proc in
                timeoutWorkItem.cancel()
                proc.stdoutFileHandle.readabilityHandler = nil
                proc.stderrFileHandle.readabilityHandler = nil
                proc.eventFileHandle.readabilityHandler = nil
                if let chunk = String(data: proc.eventFileHandle.readDataToEndOfFile(), encoding: .utf8),
                   !chunk.isEmpty {
                    lineBuffer.appendAndProcessLines(chunk, handleLine)
                }
                if let chunk = String(data: proc.stderrFileHandle.readDataToEndOfFile(), encoding: .utf8),
                   !chunk.isEmpty {
                    errorOutput.append(chunk)
                }
                handleLine(lineBuffer.drainRemaining())
                Task { @MainActor in
                    if self?.activeProcess === proc {
                        self?.activeProcess = nil
                    }
                }
                resumeOnce(state.result(
                    exitCode: Int(proc.terminationStatus),
                    fallbackError: errorOutput.value.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            do {
                try process.run()
            } catch {
                timeoutWorkItem.cancel()
                activeProcess = nil
                resumeOnce(LocalAgentModelTurnResult(
                    exitCode: -1,
                    text: "",
                    error: error.localizedDescription,
                    inputTokens: 0,
                    outputTokens: 0,
                    durationMs: nil,
                    benchmark: LocalAgentInferenceBenchmark(),
                    events: [],
                    timedOut: false
                ))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(1, timeoutSeconds),
                execute: timeoutWorkItem
            )
        }
    }

    // MARK: - Persistent serve session (model resident across turns)

    /// Runs one turn against a long-lived `serve` helper, spawning it lazily on first use and
    /// reusing it (model resident) for subsequent turns. Resolves when the helper emits this
    /// turn's terminal envelope (`completed`/`failed`/`cancelled`), on timeout, or on crash.
    private nonisolated func generatePersistent(
        executablePath: String,
        requestPath: String,
        currentDirectory: String,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> LocalAgentModelTurnResult {
        let requestID = UUID().uuidString
        return await withCheckedContinuation { continuation in
            let session: LocalAgentPersistentSession
            do {
                session = try ensureSession(
                    executablePath: executablePath,
                    currentDirectory: currentDirectory,
                    environment: environment
                )
            } catch {
                continuation.resume(returning: LocalAgentModelTurnResult(
                    exitCode: -1,
                    text: "",
                    error: error.localizedDescription,
                    inputTokens: 0,
                    outputTokens: 0,
                    durationMs: nil,
                    benchmark: LocalAgentInferenceBenchmark(),
                    events: [],
                    timedOut: false
                ))
                return
            }

            let turn = LocalAgentInFlightTurn(
                requestID: requestID,
                state: LocalAgentInferenceState(),
                resume: { result in continuation.resume(returning: result) }
            )

            // Timeout cancels the in-flight generation (NOT the process), so the warm model
            // survives for the next turn; a short backstop resolves the turn if the helper
            // never acknowledges the cancel.
            let timeoutWorkItem = DispatchWorkItem { [weak self, weak session, weak turn] in
                guard let self, let session, let turn else { return }
                turn.state.markTimedOut()
                session.process.sendControl(.cancel(reason: "local_agent_timeout"))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.resolveTurn(session: session, turn: turn, exitCode: 130, fallbackError: nil)
                }
            }
            turn.timeoutWorkItem = timeoutWorkItem

            session.lock.lock()
            session.current = turn
            session.lock.unlock()

            let sent = session.process.sendControl(.run(requestID: requestID, requestFile: requestPath))
            guard sent else {
                dropSession(session)
                resolveTurn(
                    session: session,
                    turn: turn,
                    exitCode: -1,
                    fallbackError: "Local MLX serve helper is unavailable."
                )
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(1, timeoutSeconds),
                execute: timeoutWorkItem
            )
        }
    }

    private nonisolated func ensureSession(
        executablePath: String,
        currentDirectory: String,
        environment: [String: String]
    ) throws -> LocalAgentPersistentSession {
        sessionLock.lock()
        if let session, session.process.isRunning {
            sessionLock.unlock()
            return session
        }
        sessionLock.unlock()

        let process = AgentExecutionScopedProcess(
            executablePath: executablePath,
            arguments: ["serve", "--idle-ttl-seconds", "300"],
            currentDirectory: currentDirectory,
            environment: environment,
            dedicatedEventFileDescriptor: LocalMLXRuntime.protocolFileDescriptor,
            dedicatedControlFileDescriptor: LocalMLXRuntime.controlFileDescriptor
        )
        let session = LocalAgentPersistentSession(process: process)
        installReaders(on: session)
        process.terminationHandler = { [weak self] proc in
            self?.handleSessionTermination(session: session, process: proc)
        }
        try process.run()

        sessionLock.lock()
        self.session = session
        sessionLock.unlock()
        return session
    }

    private nonisolated func installReaders(on session: LocalAgentPersistentSession) {
        session.process.eventFileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            session.lineBuffer.appendAndProcessLines(chunk) { line in
                self?.handleEventLine(line, session: session)
            }
        }
        session.process.stderrFileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            session.errorOutput.append(chunk)
        }
    }

    /// Routes one helper event line to the current turn and resolves it on a terminal envelope.
    private nonisolated func handleEventLine(_ line: String, session: LocalAgentPersistentSession) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(LocalModelProtocolEnvelope.self, from: data) else {
            return
        }
        session.lock.lock()
        let turn = session.current
        session.lock.unlock()
        guard let turn else { return }
        if let requestID = envelope.requestID, requestID != turn.requestID {
            return // stale event from a previous turn
        }

        turn.state.recordEnvelopeTelemetry(line: trimmed)
        for event in LocalModelProtocolParser.agentEvents(from: trimmed) {
            turn.state.record(event)
        }

        switch envelope.type {
        case "completed", "done":
            resolveTurn(session: session, turn: turn, exitCode: 0, fallbackError: nil)
        case "failed", "error":
            resolveTurn(
                session: session,
                turn: turn,
                exitCode: 1,
                fallbackError: envelope.message ?? envelope.summary ?? "Local MLX serve helper failed."
            )
        case "cancelled", "canceled":
            resolveTurn(session: session, turn: turn, exitCode: 130, fallbackError: nil)
        default:
            break
        }
    }

    private nonisolated func resolveTurn(
        session: LocalAgentPersistentSession,
        turn: LocalAgentInFlightTurn,
        exitCode: Int,
        fallbackError: String?
    ) {
        session.lock.lock()
        if turn.resolved {
            session.lock.unlock()
            return
        }
        turn.resolved = true
        if session.current === turn {
            session.current = nil
        }
        let bufferedError = session.errorOutput.value.trimmingCharacters(in: .whitespacesAndNewlines)
        session.errorOutput.value = ""
        session.lock.unlock()

        turn.timeoutWorkItem?.cancel()
        let error = fallbackError ?? bufferedError
        turn.resume(turn.state.result(exitCode: exitCode, fallbackError: error))
    }

    private nonisolated func handleSessionTermination(
        session: LocalAgentPersistentSession,
        process proc: AgentExecutionScopedProcess
    ) {
        proc.stdoutFileHandle.readabilityHandler = nil
        proc.stderrFileHandle.readabilityHandler = nil
        proc.eventFileHandle.readabilityHandler = nil

        if let chunk = String(data: proc.eventFileHandle.readDataToEndOfFile(), encoding: .utf8),
           !chunk.isEmpty {
            session.lineBuffer.appendAndProcessLines(chunk) { [weak self] line in
                self?.handleEventLine(line, session: session)
            }
        }
        if let chunk = String(data: proc.stderrFileHandle.readDataToEndOfFile(), encoding: .utf8),
           !chunk.isEmpty {
            session.errorOutput.append(chunk)
        }

        session.lock.lock()
        let turn = session.current
        session.lock.unlock()
        if let turn, !turn.resolved {
            let code = Int(proc.terminationStatus)
            let bufferedError = session.errorOutput.value.trimmingCharacters(in: .whitespacesAndNewlines)
            resolveTurn(
                session: session,
                turn: turn,
                exitCode: code == 0 ? -1 : code,
                fallbackError: bufferedError.isEmpty
                    ? "Local MLX serve helper exited unexpectedly."
                    : bufferedError
            )
        }

        dropSession(session)
        proc.terminationHandler = nil // break the process <-> session reference cycle
    }

    private nonisolated func dropSession(_ session: LocalAgentPersistentSession) {
        sessionLock.lock()
        if self.session === session {
            self.session = nil
        }
        sessionLock.unlock()
    }

    private nonisolated func shutdownSession() {
        sessionLock.lock()
        let session = self.session
        self.session = nil
        sessionLock.unlock()
        guard let session else { return }

        session.lock.lock()
        session.terminated = true
        session.lock.unlock()

        session.process.sendControl(.shutdown())
        session.process.closeControl()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak session] in
            session?.process.terminate()
        }
    }
}

private final class LocalAgentPersistentSession: @unchecked Sendable {
    let process: AgentExecutionScopedProcess
    let lineBuffer = AgentLockedBuffer()
    let errorOutput = AgentLockedBuffer()
    let lock = NSLock()
    var current: LocalAgentInFlightTurn?
    var terminated = false

    init(process: AgentExecutionScopedProcess) {
        self.process = process
    }
}

private final class LocalAgentInFlightTurn: @unchecked Sendable {
    let requestID: String
    let state: LocalAgentInferenceState
    let resume: (LocalAgentModelTurnResult) -> Void
    var timeoutWorkItem: DispatchWorkItem?
    var resolved = false

    init(
        requestID: String,
        state: LocalAgentInferenceState,
        resume: @escaping (LocalAgentModelTurnResult) -> Void
    ) {
        self.requestID = requestID
        self.state = state
        self.resume = resume
    }
}

private final class LocalAgentInferenceState: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var events: [AgentEvent] = []
    private var inputTokens = 0
    private var outputTokens = 0
    private var durationMs: Int?
    private var benchmark = LocalAgentInferenceBenchmark()
    private var loadStartedAt: Date?
    private var generateStartedAt: Date?
    private var timedOut = false

    func recordEnvelopeTelemetry(line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(LocalModelProtocolEnvelope.self, from: data) else {
            return
        }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        switch envelope.type {
        case "phase", "progress":
            switch envelope.phase {
            case "load_model":
                if loadStartedAt == nil {
                    loadStartedAt = now
                }
            case "generate":
                if generateStartedAt == nil {
                    generateStartedAt = now
                }
            default:
                break
            }
        case "memory", "memory_telemetry":
            if envelope.phase == "after_load",
               benchmark.modelLoadMs == nil,
               let loadStartedAt {
                benchmark.modelLoadMs = max(0, Int(now.timeIntervalSince(loadStartedAt) * 1_000))
            }
            benchmark.activeMemoryBytes = envelope.activeMemoryBytes ?? benchmark.activeMemoryBytes
            benchmark.cacheMemoryBytes = envelope.cacheMemoryBytes ?? benchmark.cacheMemoryBytes
            benchmark.memoryLimitBytes = envelope.memoryLimitBytes ?? benchmark.memoryLimitBytes
            benchmark.cacheLimitBytes = envelope.cacheLimitBytes ?? benchmark.cacheLimitBytes
            benchmark.memoryBudgetBytes = envelope.memoryBudgetBytes ?? benchmark.memoryBudgetBytes
            if let peak = envelope.peakMemoryBytes {
                benchmark.peakMemoryBytes = max(benchmark.peakMemoryBytes ?? 0, peak)
            }
        case "stats", "usage":
            benchmark.helperDurationMs = envelope.durationMs ?? benchmark.helperDurationMs
            benchmark.firstTokenLatencyMs = envelope.firstTokenLatencyMs ?? benchmark.firstTokenLatencyMs
            benchmark.tokensPerSecond = envelope.tokensPerSecond ?? benchmark.tokensPerSecond
            benchmark.promptTokensPerSecond = envelope.promptTokensPerSecond ?? benchmark.promptTokensPerSecond
        case "text", "text_delta", "message_delta":
            if benchmark.firstTokenLatencyMs == nil,
               let generateStartedAt {
                benchmark.firstTokenLatencyMs = max(0, Int(now.timeIntervalSince(generateStartedAt) * 1_000))
            }
        default:
            break
        }
    }

    func record(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        switch event {
        case .text(let chunk):
            text += chunk
        case .completed(let summary):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let summary {
                text += summary
            }
        case .stats(let input, let output, _, let duration, _):
            inputTokens = input
            outputTokens = output
            durationMs = duration
            benchmark.helperDurationMs = duration ?? benchmark.helperDurationMs
        default:
            break
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func result(exitCode: Int, fallbackError: String) -> LocalAgentModelTurnResult {
        lock.lock()
        defer { lock.unlock() }
        return LocalAgentModelTurnResult(
            exitCode: exitCode,
            text: text,
            error: fallbackError.isEmpty ? nil : fallbackError,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            durationMs: durationMs,
            benchmark: benchmark,
            events: events,
            timedOut: timedOut
        )
    }
}
