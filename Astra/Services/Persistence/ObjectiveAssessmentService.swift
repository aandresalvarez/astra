import Foundation
import ASTRACore

/// Tier 2 (utility-model) objective re-assessment. Given the original goal, the
/// most recent substantive user messages, and the current verification status,
/// asks a fast/cheap utility model whether the task's active objective is still
/// the right one -- and, if not, what the current objective actually is.
///
/// This is intentionally decoupled from the render path (INVARIANTS #2): every
/// entry point here is `async` and MUST be invoked from an unawaited background
/// `Task`, never awaited inline from `refresh()` or `promptContext()`. Any
/// uncertainty -- timeout, malformed JSON, missing verdict, provider error --
/// fails safe by leaving whatever `objectiveAssessment` was already persisted
/// untouched (INVARIANTS #3). The original goal is never deleted; a
/// `superseded` verdict only ever demotes it to background framing
/// (INVARIANTS #5), and callers remain responsible for surfacing a divergence
/// note when a pivot changes what work happens next (INVARIANTS #1).
enum ObjectiveAssessmentService {
    /// Injectable so tests can substitute a fake utility runtime without
    /// spawning a real CLI process. Defaults to the real provider plumbing.
    typealias PromptRunner = (
        _ prompt: String,
        _ workspacePath: String,
        _ configuration: AgentUtilityRuntimeConfiguration
    ) async -> AgentUtilityRunResult

    private static let defaultRunner: PromptRunner = { prompt, workspacePath, configuration in
        await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: configuration,
            toolMode: .none
        )
    }

    /// Clears a previously-persisted `objectiveAssessment`, if any, when the
    /// opt-in "Objective Drift Detection" setting is off. Without this, turning
    /// the experimental setting off only stops scheduling new Tier 2 runs
    /// (`AgentRuntimeRunPersistence.recordSessionTurn`'s own gate) -- it never
    /// invalidates a verdict a prior, now-disabled run already wrote, so
    /// `FollowUpIntroSectionProvider` kept applying a stale `superseded` /
    /// `original_satisfied` framing indefinitely even after opt-out (adversarial
    /// finding). Safe to call on every turn regardless of whether an assessment
    /// exists: it is a cheap no-op write skip when `objectiveAssessment` is
    /// already `nil`.
    @MainActor
    static func clearAssessmentIfDriftDetectionDisabled(task: AgentTask) {
        guard !UserDefaults.standard.bool(forKey: AppStorageKeys.objectiveDriftDetectionEnabled) else { return }
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty,
              var state = TaskContextStateManager.load(taskFolder: folder),
              state.objectiveAssessment != nil else {
            return
        }
        state.objectiveAssessment = nil
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)
    }

    /// Runs the Tier 2 assessment for `task` if-and-only-if
    /// `ObjectiveAssessmentTrigger.shouldAssess` agrees it is warranted, then
    /// persists the result via `TaskContextStateManager.saveState`. Always
    /// fails safe: any failure leaves the previously persisted
    /// `objectiveAssessment` untouched and is only recorded via an audit log
    /// entry, never surfaced to the caller as an error.
    ///
    /// - Parameters:
    ///   - task: The task whose objective may need re-assessing.
    ///   - utilityRuntime: Resolved the same way
    ///     `TaskLifecycleCoordinator.backfillGeneratedThreadTitles` resolves
    ///     its utility runtime from user Settings. Pass `nil` to resolve from
    ///     `UserDefaults.standard` (the production path).
    ///   - runner: Test seam; defaults to the real utility-model plumbing.
    @MainActor
    static func assessIfNeeded(
        task: AgentTask,
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil,
        runner: PromptRunner? = nil
    ) async {
        // Guard against a faulted/deleted task before touching any of its
        // properties -- this runs from an unawaited background Task that can
        // be scheduled well after the user deletes the task (see
        // WorkspaceConfigManager.swift's `!workspace.isDeleted,
        // workspace.modelContext != nil` precedent for the same class of bug).
        guard !task.isDeleted, task.modelContext != nil else { return }

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return }

        let existingState = TaskContextStateManager.load(taskFolder: folder)
        let turnCount = existingState?.turns.count ?? 0
        // `existingState.turns` is capped to the most recent `maxTurns` entries
        // by `TaskContextStateManager.recordTurn`, so its `.count` plateaus once
        // a thread runs long -- but each retained `Turn` still carries its real,
        // uncapped `turn` number. Use the max of those (falling back to the
        // capped count for empty/never-recorded state) so the staleness gate
        // keeps advancing past the array cap instead of freezing at `maxTurns`.
        let currentTurn = existingState?.turns.map(\.turn).max() ?? turnCount
        let originalGoal = task.goal
        let recentMessages = assessmentRecentUserMessages(for: task)
        let verificationStatus = existingState?.verification.status ?? "unknown"
        let hasSubstantiveLaterUserMessage = !recentMessages.isEmpty
        let hasExplicitObjectiveMarker = TaskContextStateManager.activeObjectiveResolution(
            for: task,
            planState: TaskPlanService.reconstruct(for: task),
            startingRequest: originalGoal,
            approvedGoal: existingState?.approvedGoal
        ).supersedesOriginalGoal

        let inputHash = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: originalGoal,
            recentUserMessages: recentMessages,
            verificationStatus: verificationStatus
        )
        let previousAssessment = existingState?.objectiveAssessment

        let shouldAssess = ObjectiveAssessmentTrigger.shouldAssess(
            turnCount: turnCount,
            hasSubstantiveLaterUserMessage: hasSubstantiveLaterUserMessage,
            hasExplicitObjectiveMarker: hasExplicitObjectiveMarker,
            currentInputHash: inputHash,
            lastInputHash: previousAssessment?.inputHash,
            lastAssessedAtTurn: previousAssessment?.assessedAtTurn,
            currentTurn: currentTurn
        )

        guard shouldAssess else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "skipped_by_trigger"
            ], level: .debug)
            return
        }

        let configuration = utilityRuntime ?? resolvedUtilityRuntime()
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let prompt = assessmentPrompt(
            originalGoal: originalGoal,
            recentUserMessages: recentMessages,
            verificationStatus: verificationStatus
        )

        let promptRunner = runner ?? defaultRunner
        let result = await promptRunner(prompt, workspacePath, configuration)

        // Re-check after the (possibly long-running, up to 60s) await -- the
        // task may have been deleted from the UI while this was in flight.
        guard !task.isDeleted, task.modelContext != nil else { return }

        guard result.exitCode == 0 else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "provider_error",
                "exit_code": String(result.exitCode)
            ], level: .warning)
            return
        }

        guard let parsed = parseAssessment(
            result.output,
            assessedAtTurn: currentTurn,
            inputHash: inputHash
        ) else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "parse_failed"
            ], level: .warning)
            return
        }

        guard var stateToSave = TaskContextStateManager.load(taskFolder: folder) ?? existingState else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "missing_state"
            ], level: .warning)
            return
        }
        stateToSave.objectiveAssessment = parsed
        TaskContextStateManager.saveState(stateToSave, taskFolder: folder, taskID: task.id)

        AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
            "operation": "objective_assessment",
            "result": "assessed",
            "verdict": parsed.verdict
        ], level: .info)
    }

    // MARK: - Prompt

    private static func assessmentPrompt(
        originalGoal: String,
        recentUserMessages: [String],
        verificationStatus: String
    ) -> String {
        let messagesBlock = recentUserMessages.isEmpty
            ? "(none)"
            : recentUserMessages.map { "- \(assessmentBoundedInline($0, maxCharacters: 400))" }.joined(separator: "\n")
        return """
        You are checking whether a coding task's original goal is still the right thing to keep working on.
        Return STRICT JSON only. No markdown fences, no commentary, no other text.
        The JSON object must have exactly these keys:
        - "verdict": one of "original_active", "original_satisfied", "superseded"
        - "currentObjective": a string, present ONLY when verdict is "superseded" (describe the new objective)

        Original goal: \(assessmentBoundedInline(originalGoal, maxCharacters: 500))

        Most recent user messages (oldest first):
        \(messagesBlock)

        Current verification status: \(verificationStatus)

        Respond with STRICT JSON now.
        """
    }

    // MARK: - Parsing

    private static func parseAssessment(
        _ rawOutput: String,
        assessedAtTurn: Int,
        inputHash: String
    ) -> TaskContextState.ObjectiveAssessment? {
        let validVerdicts: Set<String> = ["original_active", "original_satisfied", "superseded"]
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonSubstring = assessmentExtractJSONObject(from: trimmed),
              let data = jsonSubstring.data(using: .utf8) else {
            return nil
        }

        struct Payload: Decodable {
            var verdict: String
            var currentObjective: String?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }

        let verdict = payload.verdict.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validVerdicts.contains(verdict) else { return nil }

        let currentObjective = payload.currentObjective?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard verdict != "superseded" || !(currentObjective ?? "").isEmpty else {
            // Superseded without a current objective is not actionable -- fail
            // safe rather than persist a pivot with nowhere to go.
            return nil
        }

        return TaskContextState.ObjectiveAssessment(
            verdict: verdict,
            currentObjective: verdict == "superseded" ? currentObjective : nil,
            assessedAtTurn: assessedAtTurn,
            inputHash: inputHash
        )
    }

    private static func assessmentExtractJSONObject(from text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}"),
              firstBrace < lastBrace else {
            return nil
        }
        return String(text[firstBrace...lastBrace])
    }

    // MARK: - Runtime resolution

    /// Mirrors how `TaskLifecycleCoordinator.backfillGeneratedThreadTitles`
    /// resolves its utility runtime from the user's configured Settings >
    /// Runtime Utility Model, reading the same `UserDefaults`-backed keys the
    /// Settings view writes via `@AppStorage`.
    private static func resolvedUtilityRuntime(defaults: UserDefaults = .standard) -> AgentUtilityRuntimeConfiguration {
        let defaultRuntimeID = defaults.string(forKey: AppStorageKeys.defaultRuntimeID) ?? TaskExecutionDefaults.runtime.rawValue
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        let model = defaults.string(forKey: AppStorageKeys.validationModel) ?? TaskExecutionDefaults.model
        var providerSettings = RuntimeProviderSettingsStore.settings(defaults: defaults)
        if providerSettings.executablePath(for: .claudeCode).isEmpty {
            providerSettings.setExecutablePath(RuntimePathResolver.detectClaudePath(), for: .claudeCode)
        }
        if providerSettings.executablePath(for: .copilotCLI).isEmpty {
            providerSettings.setExecutablePath(CopilotCLIRuntime.detectPath(), for: .copilotCLI)
        }
        if providerSettings.homeDirectory(for: .copilotCLI).isEmpty {
            providerSettings.setHomeDirectory(CopilotCLIRuntime.channelHome(), for: .copilotCLI)
        }
        return AgentUtilityRuntimeConfiguration(
            runtime: runtime,
            model: RuntimeModelAvailability.normalizedModel(model, for: runtime),
            providerSettings: providerSettings
        )
    }

    // MARK: - Recent user messages

    /// Recent, substantive (non-filler) user follow-up messages, excluding the
    /// very first conversation message (which is the original goal itself).
    /// Kept private/local rather than reusing
    /// `TaskActiveObjectiveResolver.swift`'s private helpers, matching the
    /// established pattern of defining independent file-scope helpers with
    /// distinct names to avoid cross-file collisions.
    @MainActor
    private static func assessmentRecentUserMessages(for task: AgentTask, limit: Int = 4) -> [String] {
        let userMessages = task.events
            .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
            .sorted { $0.timestamp < $1.timestamp }
        guard userMessages.count > 1 else { return [] }

        let candidates = userMessages
            .dropFirst()
            .compactMap { event -> String? in
                let text = assessmentBoundedInline(event.payload, maxCharacters: 400)
                guard !text.isEmpty,
                      !assessmentIsLowSignal(text),
                      !TaskContextStateManager.isGeneratedResumeInstruction(text) else {
                    return nil
                }
                return text
            }
        return Array(candidates.suffix(limit))
    }

    private static func assessmentIsLowSignal(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        let fillerWords: Set<String> = [
            "ok", "okay", "k", "kk", "thanks", "thank", "you", "ty",
            "proceed", "continue", "go", "ahead", "do", "it",
            "sure", "great", "perfect", "nice", "cool", "done", "lgtm", "please",
            "now", "then", "sounds", "good", "sg", "ack", "got", "fine"
        ]
        return tokens.allSatisfy { fillerWords.contains($0) }
    }

    private static func assessmentBoundedInline(_ value: String, maxCharacters: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "..."
    }
}
