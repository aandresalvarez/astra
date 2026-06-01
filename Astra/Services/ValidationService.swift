import Foundation
import SwiftData

enum ValidationResult {
    case passed(details: String)
    case failed(details: String)
    case error(String)
}

struct TaskValidationContractEvaluation: Sendable, Equatable {
    var didRun: Bool
    var canComplete: Bool
    var summary: String
    var failedRequiredAssertionIDs: [String]

    static let notRequired = TaskValidationContractEvaluation(
        didRun: false,
        canComplete: true,
        summary: "No validation contract required.",
        failedRequiredAssertionIDs: []
    )
}

enum ValidationService {
    private static let maximumTextContainsBytes: UInt64 = 2 * 1024 * 1024

    /// Run tests in the task's workspace using the configured test command.
    static func runTests(task: AgentTask) async -> ValidationResult {
        let command = task.testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .error("No test command configured")
        }

        AppLogger.audit(.validationStarted, category: "Validation", taskID: task.id, fields: [
            "command_length": String(command.count),
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.shellPathSuffix)"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")

        if result.exitCode == 0 {
            AppLogger.audit(.validationPassed, category: "Validation", taskID: task.id, fields: [
                "exit_code": String(result.exitCode)
            ])
            return .passed(details: output.isEmpty ? "All tests passed" : String(output.suffix(500)))
        } else {
            AppLogger.audit(.validationFailed, category: "Validation", taskID: task.id, fields: [
                "exit_code": String(result.exitCode)
            ], level: .error)
            return .failed(details: String(output.suffix(1000)))
        }
    }

    /// AI self-check: ask the configured utility runtime to review the changes for correctness.
    static func aiCheck(
        task: AgentTask,
        claudePath: String,
        model: String = "claude-haiku-4-5-20251001",
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> ValidationResult {
        let utilityRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        guard let latestRun = task.runs.sorted(by: { $0.startedAt > $1.startedAt }).first else {
            return .error("No run to validate")
        }

        let changes = latestRun.fileChanges
        guard !changes.isEmpty else {
            return .error("No file changes to review")
        }

        var changeSummary = ""
        for change in changes.prefix(10) {
            changeSummary += "[\(change.changeType)] \(change.path)\n"
            if change.changeType == "Edit" {
                if let old = change.oldString { changeSummary += "- \(old.prefix(200))\n" }
                if let new = change.newString { changeSummary += "+ \(new.prefix(200))\n" }
            }
        }

        let prompt = """
        Review the agent's work for correctness. The task goal was: "\(task.goal)"

        Changes made:
        \(changeSummary)

        Agent's output: \(latestRun.output.prefix(500))

        Reply with ONLY "PASS" or "FAIL" on the first line, followed by a brief explanation.
        """

        AppLogger.audit(.validationStarted, category: "Validation", taskID: task.id, fields: [
            "mode": "ai_self_check",
            "changes_count": String(changes.count)
        ])

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            configuration: utilityRuntime
        )
        guard result.exitCode == 0 else {
            return .error("AI check provider failed: \(String(result.error.prefix(300)))")
        }
        let trimmed = result.output

        if trimmed.uppercased().hasPrefix("PASS") {
            AppLogger.audit(.validationPassed, category: "Validation", taskID: task.id, fields: [
                "mode": "ai_self_check"
            ])
            return .passed(details: trimmed)
        } else if trimmed.uppercased().hasPrefix("FAIL") {
            AppLogger.audit(.validationFailed, category: "Validation", taskID: task.id, fields: [
                "mode": "ai_self_check"
            ], level: .warning)
            return .failed(details: trimmed)
        } else {
            return .passed(details: "AI response: \(String(trimmed.prefix(300)))")
        }
    }

    @MainActor
    static func runContract(
        task: AgentTask,
        plan: TaskPlanPayload,
        run: TaskRun?,
        modelContext: ModelContext,
        verifierRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> TaskValidationContractEvaluation {
        guard let contract = plan.validationContract, !contract.assertions.isEmpty else {
            return .notRequired
        }

        AppLogger.audit(.validationStarted, category: "Validation", taskID: task.id, fields: [
            "mode": "validation_contract",
            "plan_id": plan.planID.uuidString,
            "assertion_count": String(contract.assertions.count),
            "run_id": run?.id.uuidString ?? "none"
        ])

        var finalPayloads: [TaskValidationAssertionEventPayload] = []
        finalPayloads.reserveCapacity(contract.assertions.count)

        for assertion in contract.assertions {
            recordAssertionEvent(
                type: TaskValidationEventTypes.assertionStarted,
                planID: plan.planID,
                assertion: assertion,
                status: "started",
                summary: "Started validation assertion: \(assertion.description)",
                task: task,
                run: run,
                modelContext: modelContext
            )

            let payload = await evaluate(
                assertion: assertion,
                plan: plan,
                task: task,
                run: run,
                modelContext: modelContext,
                verifierRuntime: verifierRuntime
            )
            finalPayloads.append(payload)
            let eventType = switch payload.status {
            case "passed": TaskValidationEventTypes.assertionPassed
            case "skipped": TaskValidationEventTypes.assertionSkipped
            default: TaskValidationEventTypes.assertionFailed
            }
            modelContext.insert(TaskEvent(task: task, type: eventType, payload: encode(payload), run: run))

            let auditEvent = switch payload.status {
            case "passed": AuditEvent.validationAssertionPassed
            case "skipped": AuditEvent.validationAssertionSkipped
            default: AuditEvent.validationAssertionFailed
            }
            AppLogger.audit(auditEvent, category: "Validation", taskID: task.id, fields: [
                "plan_id": plan.planID.uuidString,
                "assertion_id": assertion.id,
                "assertion_method": assertion.method.rawValue,
                "assertion_scope": assertion.scope.rawValue,
                "required": String(assertion.required),
                "run_id": run?.id.uuidString ?? "none",
                "exit_code": payload.exitCode.map(String.init) ?? "none",
                "path": payload.path ?? "none"
            ], level: payload.status == "failed" && assertion.required ? .warning : .info)
        }

        let requiredResults = finalPayloads.filter(\.required)
        let failedRequired = requiredResults.filter { $0.status != "passed" }
        let requiredPassed = requiredResults.count - failedRequired.count
        let canComplete = failedRequired.isEmpty
        let summary = canComplete
            ? "Validation contract passed: \(requiredPassed)/\(requiredResults.count) required assertions passed."
            : "Validation contract failed: \(failedRequired.count) required assertion\(failedRequired.count == 1 ? "" : "s") did not pass."

        let contractPayload = TaskValidationContractEventPayload(
            version: 1,
            planID: plan.planID,
            status: canComplete ? "passed" : "failed",
            requiredPassed: requiredPassed,
            requiredTotal: requiredResults.count,
            failedRequiredAssertionIDs: failedRequired.map(\.assertionID),
            summary: summary
        )
        let contractEventType = canComplete
            ? TaskValidationEventTypes.contractPassed
            : TaskValidationEventTypes.contractFailed
        modelContext.insert(TaskEvent(task: task, type: contractEventType, payload: encode(contractPayload), run: run))
        if !canComplete {
            recordCorrectiveSteps(
                failedAssertions: failedRequired,
                planID: plan.planID,
                task: task,
                run: run,
                modelContext: modelContext
            )
        }
        AppLogger.audit(
            canComplete ? .validationContractPassed : .validationContractFailed,
            category: "Validation",
            taskID: task.id,
            fields: [
                "plan_id": plan.planID.uuidString,
                "run_id": run?.id.uuidString ?? "none",
                "required_passed": String(requiredPassed),
                "required_total": String(requiredResults.count),
                "failed_required": failedRequired.map(\.assertionID).joined(separator: ",")
            ],
            level: canComplete ? .info : .warning
        )
        TaskContextStateManager.refresh(task: task)

        return TaskValidationContractEvaluation(
            didRun: true,
            canComplete: canComplete,
            summary: summary,
            failedRequiredAssertionIDs: failedRequired.map(\.assertionID)
        )
    }

    @MainActor
    private static func recordCorrectiveSteps(
        failedAssertions: [TaskValidationAssertionEventPayload],
        planID: UUID,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) {
        for failure in failedAssertions {
            TaskCorrectiveWorkService.recordProposedStep(
                planID: planID,
                sourceRunID: run?.id,
                failedAssertionID: failure.assertionID,
                failureSummary: failure.summary,
                suggestedRepair: suggestedRepair(for: failure),
                task: task,
                run: run,
                modelContext: modelContext
            )
        }
    }

    private static func suggestedRepair(for failure: TaskValidationAssertionEventPayload) -> String {
        switch failure.method {
        case .command:
            if failure.reason == "command_not_allowed" {
                return "Replace this command assertion with structured artifact, text_contains, browser_behavior, or verifier assertions; do not use shell composition."
            }
            let command = failure.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return command.isEmpty
                ? "Add or fix the missing validation command, then rerun validation."
                : "Fix the work until this command exits 0: \(command)"
        case .artifact:
            let path = failure.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty
                ? "Specify and create the required artifact, then rerun validation."
                : "Create or update the required artifact at \(path), then rerun validation."
        case .manual:
            return "Request the required manual review or change the contract if this proof is no longer required."
        case .textEvidence:
            return "Record structured validation evidence for this assertion, then rerun validation."
        case .textContains:
            let path = failure.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty
                ? "Add the expected text to the required artifact, then rerun validation."
                : "Update \(path) so it contains the expected text, then rerun validation."
        case .verifier:
            return "Address the verifier finding, then rerun the independent verifier assertion."
        case .browserBehavior:
            return "Fix the browser-visible behavior or update the expected evidence, then rerun validation."
        }
    }

    @MainActor
    private static func recordAssertionEvent(
        type: String,
        planID: UUID,
        assertion: TaskValidationAssertion,
        status: String,
        summary: String,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) {
        let payload = TaskValidationAssertionEventPayload(
            version: 1,
            planID: planID,
            assertionID: assertion.id,
            scope: assertion.scope,
            stepID: assertion.stepID,
            method: assertion.method,
            required: assertion.required,
            status: status,
            summary: summary,
            command: assertion.command,
            exitCode: nil,
            path: assertion.path,
            evidence: nil,
            reason: nil
        )
        modelContext.insert(TaskEvent(task: task, type: type, payload: encode(payload), run: run))
        AppLogger.audit(.validationAssertionStarted, category: "Validation", taskID: task.id, fields: [
            "plan_id": planID.uuidString,
            "assertion_id": assertion.id,
            "assertion_method": assertion.method.rawValue,
            "required": String(assertion.required)
        ])
    }

    @MainActor
    private static func evaluate(
        assertion: TaskValidationAssertion,
        plan: TaskPlanPayload,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext,
        verifierRuntime: AgentUtilityRuntimeConfiguration?
    ) async -> TaskValidationAssertionEventPayload {
        switch assertion.method {
        case .command:
            return await evaluateCommand(assertion: assertion, planID: plan.planID, task: task)
        case .artifact:
            return evaluateArtifact(assertion: assertion, planID: plan.planID, task: task)
        case .manual:
            return evaluateManual(assertion: assertion, planID: plan.planID, task: task)
        case .textEvidence:
            return evaluateTextEvidence(assertion: assertion, planID: plan.planID, task: task, run: run)
        case .textContains:
            return evaluateTextContains(assertion: assertion, planID: plan.planID, task: task)
        case .verifier:
            return await evaluateVerifier(
                assertion: assertion,
                plan: plan,
                task: task,
                run: run,
                modelContext: modelContext,
                verifierRuntime: verifierRuntime
            )
        case .browserBehavior:
            return evaluateBrowserBehavior(
                assertion: assertion,
                planID: plan.planID,
                task: task,
                run: run,
                modelContext: modelContext
            )
        }
    }

    private static func evaluateCommand(
        assertion: TaskValidationAssertion,
        planID: UUID,
        task: AgentTask
    ) async -> TaskValidationAssertionEventPayload {
        guard let command = assertion.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Command assertion is missing a command.",
                command: assertion.command,
                reason: "missing_command"
            )
        }
        guard isAllowedValidationCommand(command) else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Command assertion is outside ASTRA's validation command allowlist.",
                command: command,
                reason: "command_not_allowed"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.shellPathSuffix)"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        let output = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = result.exitCode == 0
            ? "Command passed."
            : "Command failed with exit code \(result.exitCode)."

        return assertionPayload(
            assertion: assertion,
            planID: planID,
            status: result.exitCode == 0 ? "passed" : "failed",
            summary: output.isEmpty ? summary : "\(summary) \(String(output.prefix(500)))",
            command: command,
            exitCode: result.exitCode,
            evidence: output.isEmpty ? nil : String(output.prefix(1000)),
            reason: result.exitCode == 0 ? nil : "command_failed"
        )
    }

    private static func evaluateArtifact(
        assertion: TaskValidationAssertion,
        planID: UUID,
        task: AgentTask
    ) -> TaskValidationAssertionEventPayload {
        guard let requestedPath = assertion.path?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedPath.isEmpty else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Artifact assertion is missing a path.",
                path: assertion.path,
                reason: "missing_path"
            )
        }
        guard isScopedValidationArtifactPath(requestedPath) else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Artifact assertion path must be relative to the task folder or workspace.",
                path: requestedPath,
                reason: "path_outside_scope"
            )
        }

        let scopedCandidate = scopedExistingArtifactPath(
            requestedPath,
            task: task,
            allowDirectory: artifactAssertionAllowsDirectory(assertion)
        )
        let existingPath = scopedCandidate.path
        if let existingPath {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "passed",
                summary: "Artifact exists at \(existingPath).",
                path: existingPath,
                evidence: existingPath
            )
        }
        if scopedCandidate.rejectedOutOfScope {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Artifact assertion resolved outside the task folder or workspace.",
                path: requestedPath,
                reason: "path_outside_scope"
            )
        }
        if scopedCandidate.rejectedDirectory {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Artifact assertion matched a directory, but this contract requires a file artifact.",
                path: requestedPath,
                reason: "artifact_directory_not_allowed"
            )
        }

        return assertionPayload(
            assertion: assertion,
            planID: planID,
            status: "failed",
            summary: "Artifact was not found. Checked: \(scopedCandidate.checked.joined(separator: ", ")).",
            path: requestedPath,
            reason: "artifact_missing"
        )
    }

    private static func evaluateManual(
        assertion: TaskValidationAssertion,
        planID: UUID,
        task: AgentTask
    ) -> TaskValidationAssertionEventPayload {
        if let event = latestPassingAssertionEvent(task: task, planID: planID, assertionID: assertion.id) {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "passed",
                summary: "Manual approval was already recorded.",
                evidence: event.id.uuidString
            )
        }
        return assertionPayload(
            assertion: assertion,
            planID: planID,
            status: assertion.required ? "failed" : "skipped",
            summary: assertion.required ? "Manual review is required before completion." : "Manual review was not required.",
            reason: assertion.required ? "manual_review_required" : "manual_review_optional"
        )
    }

    private static func evaluateTextEvidence(
        assertion: TaskValidationAssertion,
        planID: UUID,
        task: AgentTask,
        run: TaskRun?
    ) -> TaskValidationAssertionEventPayload {
        let query = firstNonEmpty(assertion.evidenceQuery, assertion.description)
        let evidenceEvents = task.events.filter { event in
            event.type == TaskValidationEventTypes.evidence &&
                (event.payload.localizedCaseInsensitiveContains(assertion.id) ||
                 (!query.isEmpty && event.payload.localizedCaseInsensitiveContains(query)))
        }
        if let event = evidenceEvents.sorted(by: { $0.timestamp > $1.timestamp }).first {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "passed",
                summary: "Structured text evidence was recorded.",
                evidence: event.id.uuidString
            )
        }

        if let run, run.output.localizedCaseInsensitiveContains("VALIDATION_EVIDENCE \(assertion.id)") {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "passed",
                summary: "Run output included a validation evidence marker.",
                evidence: run.id.uuidString
            )
        }

        return assertionPayload(
            assertion: assertion,
            planID: planID,
            status: assertion.required ? "failed" : "skipped",
            summary: assertion.required ? "No structured text evidence was recorded." : "Optional text evidence was not recorded.",
            reason: assertion.required ? "text_evidence_missing" : "text_evidence_optional"
        )
    }

    private static func evaluateTextContains(
        assertion: TaskValidationAssertion,
        planID: UUID,
        task: AgentTask
    ) -> TaskValidationAssertionEventPayload {
        guard let requestedPath = assertion.path?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedPath.isEmpty else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Text contains assertion is missing an artifact path.",
                path: assertion.path,
                reason: "missing_path"
            )
        }
        guard isScopedValidationArtifactPath(requestedPath) else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Text contains assertion path must be relative to the task folder or workspace.",
                path: requestedPath,
                reason: "path_outside_scope"
            )
        }

        let expected = firstNonEmpty(assertion.evidenceQuery, assertion.description)
        guard !expected.isEmpty else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Text contains assertion is missing expected text.",
                path: requestedPath,
                reason: "missing_expected_text"
            )
        }

        let scopedCandidate = scopedExistingArtifactPath(requestedPath, task: task, allowDirectory: false)
        guard let existingPath = scopedCandidate.path else {
            let reason: String
            let summary: String
            if scopedCandidate.rejectedOutOfScope {
                reason = "path_outside_scope"
                summary = "Text contains artifact resolved outside the task folder or workspace."
            } else if scopedCandidate.rejectedDirectory {
                reason = "artifact_directory_not_allowed"
                summary = "Text contains assertion matched a directory, but text validation requires a file artifact."
            } else {
                reason = "artifact_missing"
                summary = "Text contains artifact was not found. Checked: \(scopedCandidate.checked.joined(separator: ", "))."
            }
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: summary,
                path: requestedPath,
                reason: reason
            )
        }

        if let byteCount = fileSize(atPath: existingPath), byteCount > maximumTextContainsBytes {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Text contains artifact is too large to inspect safely.",
                path: existingPath,
                reason: "artifact_too_large"
            )
        }

        guard let content = try? String(contentsOfFile: existingPath, encoding: .utf8) else {
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: "failed",
                summary: "Text contains artifact could not be read as UTF-8 text.",
                path: existingPath,
                reason: "artifact_text_unreadable"
            )
        }

        let matched = content.localizedCaseInsensitiveContains(expected)
        let summary = matched
            ? "Artifact text contains expected text in \(existingPath)."
            : "Artifact text did not contain expected text: \(String(expected.prefix(160)))."
        return assertionPayload(
            assertion: assertion,
            planID: planID,
            status: matched ? "passed" : (assertion.required ? "failed" : "skipped"),
            summary: summary,
            path: existingPath,
            evidence: matched ? String(expected.prefix(500)) : nil,
            reason: matched ? nil : "expected_text_missing"
        )
    }

    @MainActor
    private static func evaluateBrowserBehavior(
        assertion: TaskValidationAssertion,
        planID: UUID,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) -> TaskValidationAssertionEventPayload {
        recordBehaviorEvent(
            type: TaskValidationBehaviorEventTypes.started,
            auditEvent: .validationBehaviorStarted,
            planID: planID,
            assertionID: assertion.id,
            path: assertion.path,
            summary: "Started browser behavior validation.",
            task: task,
            run: run,
            modelContext: modelContext
        )

        guard let requestedPath = assertion.path?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedPath.isEmpty else {
            let summary = "Browser behavior assertion is missing an artifact path."
            recordBehaviorEvent(
                type: TaskValidationBehaviorEventTypes.failed,
                auditEvent: .validationBehaviorFailed,
                planID: planID,
                assertionID: assertion.id,
                path: assertion.path,
                summary: summary,
                reason: "missing_path",
                task: task,
                run: run,
                modelContext: modelContext
            )
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: assertion.required ? "failed" : "skipped",
                summary: summary,
                reason: "missing_path"
            )
        }
        guard isScopedValidationArtifactPath(requestedPath) else {
            let summary = "Browser behavior artifact path must be relative to the task folder or workspace."
            recordBehaviorEvent(
                type: TaskValidationBehaviorEventTypes.failed,
                auditEvent: .validationBehaviorFailed,
                planID: planID,
                assertionID: assertion.id,
                path: requestedPath,
                summary: summary,
                reason: "path_outside_scope",
                task: task,
                run: run,
                modelContext: modelContext
            )
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: assertion.required ? "failed" : "skipped",
                summary: summary,
                path: requestedPath,
                reason: "path_outside_scope"
            )
        }

        let scopedCandidate = scopedExistingArtifactPath(requestedPath, task: task, allowDirectory: false)
        guard let existingPath = scopedCandidate.path else {
            let reason: String
            let summary: String
            if scopedCandidate.rejectedOutOfScope {
                reason = "path_outside_scope"
                summary = "Browser behavior artifact resolved outside the task folder or workspace."
            } else if scopedCandidate.rejectedDirectory {
                reason = "artifact_directory_not_allowed"
                summary = "Browser behavior artifact matched a directory, but browser behavior validation requires a file artifact."
            } else {
                reason = "artifact_missing"
                summary = "Browser behavior artifact was not found. Checked: \(scopedCandidate.checked.joined(separator: ", "))."
            }
            recordBehaviorEvent(
                type: TaskValidationBehaviorEventTypes.failed,
                auditEvent: .validationBehaviorFailed,
                planID: planID,
                assertionID: assertion.id,
                path: requestedPath,
                summary: summary,
                reason: reason,
                task: task,
                run: run,
                modelContext: modelContext
            )
            return assertionPayload(
                assertion: assertion,
                planID: planID,
                status: assertion.required ? "failed" : "skipped",
                summary: summary,
                path: requestedPath,
                reason: reason
            )
        }

        let content = (try? String(contentsOfFile: existingPath, encoding: .utf8)) ?? ""
        let renderedSummary = renderedTextSummary(from: content)
        let expected = firstNonEmpty(assertion.evidenceQuery, assertion.description)
        let matched = expected.isEmpty || renderedSummary.localizedCaseInsensitiveContains(expected)
        let evidencePath = writeBehaviorEvidence(
            assertionID: assertion.id,
            planID: planID,
            sourcePath: existingPath,
            expected: expected,
            matched: matched,
            renderedSummary: renderedSummary,
            task: task
        )
        if let evidencePath {
            recordBehaviorEvent(
                type: TaskValidationBehaviorEventTypes.evidenceAttached,
                auditEvent: .validationBehaviorEvidenceAttached,
                planID: planID,
                assertionID: assertion.id,
                path: existingPath,
                evidencePath: evidencePath,
                summary: "Attached browser behavior evidence.",
                task: task,
                run: run,
                modelContext: modelContext
            )
        }

        let summary = matched
            ? "Browser behavior evidence matched expected text in \(existingPath)."
            : "Browser behavior evidence did not contain expected text: \(expected)."
        recordBehaviorEvent(
            type: matched ? TaskValidationBehaviorEventTypes.passed : TaskValidationBehaviorEventTypes.failed,
            auditEvent: matched ? .validationBehaviorPassed : .validationBehaviorFailed,
            planID: planID,
            assertionID: assertion.id,
            path: existingPath,
            evidencePath: evidencePath,
            summary: summary,
            reason: matched ? nil : "expected_text_missing",
            task: task,
            run: run,
            modelContext: modelContext
        )

        return assertionPayload(
            assertion: assertion,
            planID: planID,
            status: matched ? "passed" : (assertion.required ? "failed" : "skipped"),
            summary: summary,
            path: existingPath,
            evidence: evidencePath ?? renderedSummary,
            reason: matched ? nil : "expected_text_missing"
        )
    }

    @MainActor
    private static func evaluateVerifier(
        assertion: TaskValidationAssertion,
        plan: TaskPlanPayload,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext,
        verifierRuntime: AgentUtilityRuntimeConfiguration?
    ) async -> TaskValidationAssertionEventPayload {
        let configuration = verifierRuntime ?? AgentUtilityRuntimeConfiguration(
            runtime: task.resolvedRuntimeID,
            model: task.model
        )
        let startedPayload = TaskVerifierEventPayload(
            version: 1,
            planID: plan.planID,
            assertionID: assertion.id,
            runtime: configuration.runtime.rawValue,
            model: configuration.model,
            result: "started",
            summary: "Verifier review started.",
            evidence: nil
        )
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskVerifierEventTypes.started,
            payload: encode(startedPayload),
            run: run
        ))
        AppLogger.audit(.verifierStarted, category: "Validation", taskID: task.id, fields: [
            "plan_id": plan.planID.uuidString,
            "assertion_id": assertion.id,
            "verifier_runtime": configuration.runtime.rawValue,
            "verifier_model": configuration.model,
            "worker_runtime": task.resolvedRuntimeID.rawValue
        ])

        let prompt = verifierPrompt(assertion: assertion, plan: plan, task: task, run: run)
        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            configuration: configuration,
            toolMode: .readOnly
        )
        guard result.exitCode == 0 else {
            let summary = "Verifier failed to run: \(String(result.error.prefix(500)))"
            recordVerifierResult(
                eventType: TaskVerifierEventTypes.failed,
                auditEvent: .verifierFailed,
                planID: plan.planID,
                assertionID: assertion.id,
                configuration: configuration,
                result: "failed",
                summary: summary,
                evidence: result.error,
                task: task,
                run: run,
                modelContext: modelContext
            )
            return assertionPayload(
                assertion: assertion,
                planID: plan.planID,
                status: assertion.required ? "failed" : "skipped",
                summary: summary,
                evidence: result.error,
                reason: "verifier_runtime_failed"
            )
        }

        let parsed = parseVerifierOutput(result.output)
        recordVerifierResult(
            eventType: TaskVerifierEventTypes.completed,
            auditEvent: .verifierCompleted,
            planID: plan.planID,
            assertionID: assertion.id,
            configuration: configuration,
            result: parsed.result,
            summary: parsed.summary,
            evidence: result.output,
            task: task,
            run: run,
            modelContext: modelContext
        )
        let assertionStatus: String
        let reason: String?
        switch parsed.result {
        case "pass":
            assertionStatus = "passed"
            reason = nil
        case "needs_manual_review":
            assertionStatus = assertion.required ? "failed" : "skipped"
            reason = "verifier_needs_manual_review"
        default:
            assertionStatus = assertion.required ? "failed" : "skipped"
            reason = "verifier_failed_assertion"
        }
        let assertionPayload = assertionPayload(
            assertion: assertion,
            planID: plan.planID,
            status: assertionStatus,
            summary: parsed.summary,
            evidence: String(result.output.prefix(1000)),
            reason: reason
        )
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskValidationEventTypes.assertionReviewed,
            payload: encode(assertionPayload),
            run: run
        ))
        AppLogger.audit(.validationAssertionReviewed, category: "Validation", taskID: task.id, fields: [
            "plan_id": plan.planID.uuidString,
            "assertion_id": assertion.id,
            "verifier_result": parsed.result,
            "status": assertionStatus,
            "verifier_runtime": configuration.runtime.rawValue,
            "verifier_model": configuration.model
        ], level: assertionStatus == "passed" ? .info : .warning)
        return assertionPayload
    }

    @MainActor
    private static func recordVerifierResult(
        eventType: String,
        auditEvent: AuditEvent,
        planID: UUID,
        assertionID: String,
        configuration: AgentUtilityRuntimeConfiguration,
        result: String,
        summary: String,
        evidence: String?,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) {
        let payload = TaskVerifierEventPayload(
            version: 1,
            planID: planID,
            assertionID: assertionID,
            runtime: configuration.runtime.rawValue,
            model: configuration.model,
            result: result,
            summary: summary,
            evidence: evidence.map { String($0.prefix(1000)) }
        )
        modelContext.insert(TaskEvent(task: task, type: eventType, payload: encode(payload), run: run))
        AppLogger.audit(auditEvent, category: "Validation", taskID: task.id, fields: [
            "plan_id": planID.uuidString,
            "assertion_id": assertionID,
            "verifier_runtime": configuration.runtime.rawValue,
            "verifier_model": configuration.model,
            "verifier_result": result
        ], level: result == "pass" ? .info : .warning)
    }

    @MainActor
    private static func verifierPrompt(
        assertion: TaskValidationAssertion,
        plan: TaskPlanPayload,
        task: AgentTask,
        run: TaskRun?
    ) -> String {
        let latestHandoff = TaskWorkerHandoffService.decode(
            task.events
                .filter { $0.type == TaskHandoffEventTypes.created || $0.type == TaskHandoffEventTypes.updated }
                .sorted { $0.timestamp > $1.timestamp }
                .first?.payload ?? ""
        )
        let fileChanges = (run?.fileChanges ?? task.runs.sorted { $0.startedAt < $1.startedAt }.flatMap(\.fileChanges))
            .suffix(20)
            .map { "- \($0.changeType): \($0.path)" }
            .joined(separator: "\n")
        let handoffSummary = latestHandoff.map { handoff in
            """
            Completed work: \(handoff.completedWork.joined(separator: "; "))
            Unfinished work: \(handoff.unfinishedWork.joined(separator: "; "))
            Blockers: \(handoff.blockers.joined(separator: "; "))
            Suggested next action: \(handoff.suggestedNextAction ?? "")
            """
        } ?? "No structured worker handoff recorded."
        return """
        You are ASTRA's independent verifier. Review the work as a read-only reviewer.

        Task goal:
        \(task.goal)

        Approved plan:
        \(plan.title)
        \(plan.goal)

        Assertion to review:
        ID: \(assertion.id)
        Required: \(assertion.required)
        Method: verifier
        Description: \(assertion.description)

        Worker handoff:
        \(handoffSummary)

        Changed files:
        \(fileChanges.isEmpty ? "No file changes recorded." : fileChanges)

        Latest run output:
        \(String((run?.output ?? "").prefix(3000)))

        Reply with one of these exact first-line results:
        PASS
        FAIL
        NEEDS_MANUAL_REVIEW

        After the first line, include a concise evidence summary and mention any assertion IDs you reviewed.
        """
    }

    private static func parseVerifierOutput(_ output: String) -> (result: String, summary: String) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_") ?? ""
        let result: String
        if firstLine.hasPrefix("pass") {
            result = "pass"
        } else if firstLine.hasPrefix("needs_manual_review") || firstLine.hasPrefix("manual") {
            result = "needs_manual_review"
        } else {
            result = "fail"
        }
        let summary = trimmed.isEmpty ? "Verifier returned no output." : String(trimmed.prefix(1000))
        return (result, summary)
    }

    @MainActor
    private static func recordBehaviorEvent(
        type: String,
        auditEvent: AuditEvent,
        planID: UUID,
        assertionID: String,
        path: String?,
        evidencePath: String? = nil,
        summary: String,
        reason: String? = nil,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) {
        let payload = TaskValidationBehaviorEventPayload(
            version: 1,
            planID: planID,
            assertionID: assertionID,
            path: path,
            url: path.map { URL(fileURLWithPath: $0).absoluteString },
            actionCount: 0,
            screenshotPath: nil,
            evidencePath: evidencePath,
            summary: summary,
            reason: reason
        )
        modelContext.insert(TaskEvent(task: task, type: type, payload: encode(payload), run: run))
        AppLogger.audit(auditEvent, category: "Validation", taskID: task.id, fields: [
            "plan_id": planID.uuidString,
            "assertion_id": assertionID,
            "path": path ?? "none",
            "url": payload.url ?? "none",
            "action_count": String(payload.actionCount),
            "screenshot_path": payload.screenshotPath ?? "none",
            "evidence_path": evidencePath ?? "none",
            "failure_reason": reason ?? "none"
        ], level: type == TaskValidationBehaviorEventTypes.failed ? .warning : .info)
    }

    private static func renderedTextSummary(from content: String) -> String {
        let withoutScripts = content.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: #"(?s)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return decoded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(4000)
            .description
    }

    private static func writeBehaviorEvidence(
        assertionID: String,
        planID: UUID,
        sourcePath: String,
        expected: String,
        matched: Bool,
        renderedSummary: String,
        task: AgentTask
    ) -> String? {
        let base = TaskWorkspaceAccess(task: task).taskFolder.isEmpty
            ? TaskWorkspaceAccess(task: task).effectiveWorkspacePath
            : TaskWorkspaceAccess(task: task).taskFolder
        guard !base.isEmpty else { return nil }
        let directory = (base as NSString).appendingPathComponent("validation-evidence")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let safeID = assertionID
            .map { character in character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-" }
            .reduce(into: "") { $0.append($1) }
        let path = (directory as NSString).appendingPathComponent("\(safeID)-behavior.json")
        let payload: [String: Any] = [
            "version": 1,
            "planID": planID.uuidString,
            "assertionID": assertionID,
            "sourcePath": sourcePath,
            "expected": expected,
            "matched": matched,
            "renderedSummary": renderedSummary
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            return path
        } catch {
            return nil
        }
    }

    private static func fileSize(atPath path: String) -> UInt64? {
        guard let value = try? FileManager.default.attributesOfItem(atPath: path)[.size] else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private static func artifactCandidatePaths(_ path: String, task: AgentTask) -> [String] {
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        var candidates: [String] = []
        if !taskFolder.isEmpty {
            candidates.append((taskFolder as NSString).appendingPathComponent(path))
        }
        if !workspacePath.isEmpty {
            candidates.append((workspacePath as NSString).appendingPathComponent(path))
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func scopedExistingArtifactPath(
        _ path: String,
        task: AgentTask,
        allowDirectory: Bool
    ) -> (path: String?, rejectedOutOfScope: Bool, rejectedDirectory: Bool, checked: [String]) {
        let candidates = artifactCandidatePaths(path, task: task)
        var rejectedOutOfScope = false
        var rejectedDirectory = false
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) else { continue }
            guard resolvedArtifactCandidateIsInScope(candidate, task: task) else {
                rejectedOutOfScope = true
                continue
            }
            if isDirectory.boolValue && !allowDirectory {
                rejectedDirectory = true
                continue
            }
            return (candidate, false, false, candidates)
        }
        return (nil, rejectedOutOfScope, rejectedDirectory, candidates)
    }

    private static func resolvedArtifactCandidateIsInScope(_ candidate: String, task: AgentTask) -> Bool {
        let resolvedCandidate = URL(fileURLWithPath: candidate)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return validationArtifactScopeRoots(task: task).contains { root in
            resolvedCandidate == root || resolvedCandidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private static func validationArtifactScopeRoots(task: AgentTask) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        let roots = [access.taskFolder, access.effectiveWorkspacePath]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
            }
        return Array(NSOrderedSet(array: roots)) as? [String] ?? roots
    }

    private static func isScopedValidationArtifactPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\0") else {
            return false
        }

        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    private static func artifactAssertionAllowsDirectory(_ assertion: TaskValidationAssertion) -> Bool {
        let expected = assertion.expectedArtifactType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") ?? ""
        return ["directory", "folder", "dir"].contains(expected)
    }

    private static func isAllowedValidationCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsShellComposition(trimmed),
              let root = shellRoot(trimmed)?.lowercased() else {
            return false
        }

        let allowedExactRoots: Set<String> = [
            "true",
            "false",
            "test",
            "[",
            "pytest",
            "npm",
            "yarn",
            "pnpm",
            "swift",
            "xcodebuild",
            "make"
        ]
        if allowedExactRoots.contains(root) {
            return commandArgumentsAreValidationOrBuildOnly(root: root, command: trimmed)
        }
        if root == "python" || root == "python3" {
            return pythonCommandRunsPytest(root: root, command: trimmed)
        }
        return false
    }

    private static func containsShellComposition(_ command: String) -> Bool {
        let disallowedFragments = ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n", "\r"]
        return disallowedFragments.contains { command.contains($0) }
    }

    private static func shellRoot(_ command: String) -> String? {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func shellTokens(_ command: String) -> [String] {
        command.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func pythonCommandRunsPytest(root: String, command: String) -> Bool {
        let tokens = shellTokens(command)
        guard tokens.count >= 3 else { return false }
        return tokens[0].lowercased() == root &&
            tokens[1] == "-m" &&
            tokens[2] == "pytest"
    }

    private static func commandArgumentsAreValidationOrBuildOnly(root: String, command: String) -> Bool {
        switch root {
        case "true", "false", "test", "[":
            return true
        case "swift":
            return command == "swift test" ||
                command.hasPrefix("swift test ") ||
                command == "swift build" ||
                command.hasPrefix("swift build ")
        case "xcodebuild":
            return command.contains(" test") || command.contains(" build")
        case "pytest":
            return true
        case "npm":
            return command == "npm test" ||
                command.hasPrefix("npm test ") ||
                command == "npm run test" ||
                command.hasPrefix("npm run test")
        case "yarn", "pnpm":
            return command == "\(root) test" ||
                command.hasPrefix("\(root) test ") ||
                command == "\(root) run test" ||
                command.hasPrefix("\(root) run test")
        case "make":
            return command == "make test" ||
                command.hasPrefix("make test ")
        default:
            return false
        }
    }

    private static func latestPassingAssertionEvent(
        task: AgentTask,
        planID: UUID,
        assertionID: String
    ) -> TaskEvent? {
        task.events
            .filter { $0.type == TaskValidationEventTypes.assertionPassed }
            .compactMap { event -> (TaskEvent, TaskValidationAssertionEventPayload)? in
                guard let payload = decodeAssertionPayload(event.payload),
                      payload.planID == planID,
                      payload.assertionID == assertionID else {
                    return nil
                }
                return (event, payload)
            }
            .sorted { $0.0.timestamp > $1.0.timestamp }
            .first?
            .0
    }

    private static func assertionPayload(
        assertion: TaskValidationAssertion,
        planID: UUID,
        status: String,
        summary: String,
        command: String? = nil,
        exitCode: Int? = nil,
        path: String? = nil,
        evidence: String? = nil,
        reason: String? = nil
    ) -> TaskValidationAssertionEventPayload {
        TaskValidationAssertionEventPayload(
            version: 1,
            planID: planID,
            assertionID: assertion.id,
            scope: assertion.scope,
            stepID: assertion.stepID,
            method: assertion.method,
            required: assertion.required,
            status: status,
            summary: summary,
            command: command ?? assertion.command,
            exitCode: exitCode,
            path: path ?? assertion.path,
            evidence: evidence,
            reason: reason
        )
    }

    private static func decodeAssertionPayload(_ payload: String) -> TaskValidationAssertionEventPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskValidationAssertionEventPayload.self, from: data)
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
