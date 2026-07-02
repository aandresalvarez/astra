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
        // task may have been deleted from the UI while this was in flight, or
        // the user may have disabled the opt-in setting since this was
        // scheduled (adversarial finding: without this, a call already in
        // flight when the setting is turned off can still persist its
        // verdict, silently reintroducing `objectiveAssessment` after the
        // off-path cleanup already removed it).
        guard !task.isDeleted, task.modelContext != nil,
              UserDefaults.standard.bool(forKey: AppStorageKeys.objectiveDriftDetectionEnabled) else { return }

        guard result.exitCode == 0 else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "provider_error",
                "exit_code": String(result.exitCode)
            ], level: .warning)
            discardAssessmentIfStaleAfterFailedReassessment(
                task: task,
                folder: folder,
                fallbackVerificationStatus: verificationStatus
            )
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
            discardAssessmentIfStaleAfterFailedReassessment(
                task: task,
                folder: folder,
                fallbackVerificationStatus: verificationStatus
            )
            return
        }

        guard var stateToSave = TaskContextStateManager.load(taskFolder: folder) ?? existingState else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "missing_state"
            ], level: .warning)
            return
        }

        // Two turns can each schedule an unawaited assessment before either
        // resolves; re-loading `stateToSave` above already picks up whatever
        // is freshest on disk for every OTHER field, but the assessment
        // itself must also be ordered explicitly -- otherwise a call started
        // at an earlier turn that simply takes longer to return can overwrite
        // a newer turn's already-persisted verdict with stale, out-of-order
        // input (adversarial finding). `assessedAtTurn` is a stable ordering
        // key regardless of which call actually finishes first.
        if let alreadyPersisted = stateToSave.objectiveAssessment,
           alreadyPersisted.assessedAtTurn > parsed.assessedAtTurn {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "discarded_stale_race",
                "attempted_turn": String(parsed.assessedAtTurn),
                "already_persisted_turn": String(alreadyPersisted.assessedAtTurn)
            ], level: .debug)
            return
        }

        // A slower call can also lose the race without anything newer having
        // been PERSISTED yet: turn N starts this call, turn N+1 records a new
        // user message (changing the true current input hash) before N+1's
        // own assessment lands or even runs, and N's now-stale result would
        // otherwise be saved as if it reflected N+1's message (adversarial
        // finding). Recomputing the hash fresh, right before writing, catches
        // this regardless of whether anything else has been persisted yet.
        guard currentAssessmentInputHash(
            for: task,
            folder: folder,
            fallbackVerificationStatus: verificationStatus
        ) == inputHash else {
            AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
                "operation": "objective_assessment",
                "result": "discarded_stale_inputs"
            ], level: .debug)
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

    // MARK: - Freshness

    /// Recomputes the input hash from `task`'s CURRENT events/state, not from
    /// values captured earlier in a possibly long-running call -- the single
    /// source of truth for "does what's persisted still reflect reality right
    /// now," used both to gate a successful save and to decide whether a
    /// failed reassessment should discard a now-stale persisted verdict.
    @MainActor
    private static func currentAssessmentInputHash(
        for task: AgentTask,
        folder: String,
        fallbackVerificationStatus: String
    ) -> String {
        let freshVerificationStatus = TaskContextStateManager.load(taskFolder: folder)?.verification.status
            ?? fallbackVerificationStatus
        return ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: task.goal,
            recentUserMessages: assessmentRecentUserMessages(for: task),
            verificationStatus: freshVerificationStatus
        )
    }

    /// Called when a reassessment attempt fails (provider error or parse
    /// failure): if the persisted `objectiveAssessment`'s own `inputHash` no
    /// longer matches what's freshly computed right now, it no longer
    /// reflects the current inputs -- e.g. a later, substantive user message
    /// arrived after the stale verdict was recorded -- so it's discarded
    /// rather than left to keep applying an old pivot indefinitely
    /// (adversarial finding). A still-fresh persisted assessment (its own
    /// `inputHash` already matches, whether from this call's original
    /// computation or a faster parallel call that already landed) is left
    /// untouched.
    @MainActor
    private static func discardAssessmentIfStaleAfterFailedReassessment(
        task: AgentTask,
        folder: String,
        fallbackVerificationStatus: String
    ) {
        guard var state = TaskContextStateManager.load(taskFolder: folder),
              let assessment = state.objectiveAssessment else {
            return
        }
        let fresh = currentAssessmentInputHash(
            for: task,
            folder: folder,
            fallbackVerificationStatus: fallbackVerificationStatus
        )
        guard assessment.inputHash != fresh else { return }
        state.objectiveAssessment = nil
        TaskContextStateManager.saveState(state, taskFolder: folder, taskID: task.id)
        AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: task.id, fields: [
            "operation": "objective_assessment",
            "result": "discarded_stale_after_failed_reassessment"
        ], level: .debug)
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
        // Falls back to the same literal default SettingsView's Utility Model
        // control and `TaskLifecycleCoordinator
        // .backfillGeneratedThreadTitles` use for this exact key, NOT
        // `TaskExecutionDefaults.model` (the larger, general task-execution
        // model) -- on a fresh install, before Settings has ever been opened,
        // this key is absent from `UserDefaults` and the fallback is what
        // actually runs (adversarial finding: using the task model here
        // defeats the point of a cheap/fast "Utility Model" for this
        // background check).
        let model = defaults.string(forKey: AppStorageKeys.validationModel) ?? "claude-haiku-4-5-20251001"
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

    /// Recent, substantive (non-filler) user follow-up messages, excluding any
    /// message that just restates the original goal verbatim.
    ///
    /// This does NOT drop the first `user.message`/planning-chat event by
    /// position (unlike `TaskActiveObjectiveResolver.swift`'s
    /// `latestObjectiveOverride`, a pre-existing, out-of-scope-for-this-PR
    /// helper that assumes it): an initial provider run logs its start as a
    /// `task.started` event, not `user.message` (see
    /// `AgentRuntimeWorker.executeRuntimeSession`'s default `startEventType`),
    /// so in the common case the FIRST `user.message` event is already the
    /// user's first genuine follow-up, not a restatement of `task.goal` --
    /// dropping it by position silently discarded exactly the first
    /// substantive pivot after a long initial run (adversarial finding).
    /// Excluding by exact content match instead correctly skips a
    /// restatement wherever one actually occurs (e.g. a planning-chat flow
    /// that does log the original ask as a `user.message`-typed event) while
    /// never discarding real follow-up content.
    ///
    /// Kept private/local rather than reusing
    /// `TaskActiveObjectiveResolver.swift`'s private helpers, matching the
    /// established pattern of defining independent file-scope helpers with
    /// distinct names to avoid cross-file collisions.
    @MainActor
    private static func assessmentRecentUserMessages(for task: AgentTask, limit: Int = 4) -> [String] {
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessages = task.events
            .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
            .sorted { $0.timestamp < $1.timestamp }

        let candidates = userMessages.compactMap { event -> String? in
            let text = assessmentBoundedInline(event.payload, maxCharacters: 400)
            guard !text.isEmpty,
                  !(!goal.isEmpty && text.caseInsensitiveCompare(goal) == .orderedSame),
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
