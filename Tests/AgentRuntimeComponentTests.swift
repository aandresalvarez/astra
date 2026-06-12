import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

private func makeRuntimeComponentContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private actor RuntimeComponentCompletionRecorder {
    private var completed: Set<Int> = []

    func record(_ value: Int) {
        completed.insert(value)
    }

    func snapshot() -> Set<Int> {
        completed
    }
}

@Suite("Agent Runtime Async Work")
@MainActor
struct AgentRuntimeAsyncWorkTests {
    @Test("Ordered main actor queue preserves enqueue order")
    func orderedMainActorQueuePreservesOrder() async {
        let queue = OrderedMainActorTaskQueue()
        var values: [Int] = []

        queue.add { values.append(1) }
        queue.add { values.append(2) }
        queue.add { values.append(3) }

        await queue.drainAll()

        #expect(values == [1, 2, 3])
        #expect(queue.count == 3)
    }

    @Test("Pending task collector drains all submitted tasks")
    func pendingTaskCollectorDrainsTasks() async {
        let collector = PendingTaskCollector()
        let recorder = RuntimeComponentCompletionRecorder()

        for index in 0..<4 {
            collector.add(Task {
                await recorder.record(index)
            })
        }

        await collector.drainAll()

        #expect(await recorder.snapshot() == Set(0..<4))
        #expect(collector.count == 4)
    }
}

@Suite("Agent Runtime Launch Preflight")
@MainActor
struct AgentRuntimeLaunchPreflightTests {
    @Test("Prepare task folder creates canonical output directories")
    func prepareTaskFolderCreatesDirectories() throws {
        let root = NSTemporaryDirectory() + "runtime-preflight-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Preflight", primaryPath: root)
        let task = AgentTask(title: "Task", goal: "Goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let result = AgentRuntimeLaunchPreflight.prepareTaskFolderForLaunchResult(
            task,
            modelContext: context,
            phase: "run"
        )

        #expect(result.status == .taskFolderPrepared)
        #expect(result.didPass)
        #expect(result.auditFields["result"] == "taskFolderPrepared")
        #expect(FileManager.default.fileExists(atPath: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(FileManager.default.fileExists(atPath: (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent("outputs")))
        #expect(task.status == .draft)
        #expect(task.unreadAt == nil)
    }

    @Test("Artifact preflight prepares task-output parents from structured, validation, and legacy paths")
    func artifactPreflightPreparesTaskOutputParents() throws {
        let root = NSTemporaryDirectory() + "runtime-artifact-preflight-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Preflight", primaryPath: root)
        let task = AgentTask(title: "Task", goal: "Goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Nested artifacts",
            goal: "Write files",
            steps: [
                TaskPlanPayloadStep(
                    id: "requirements",
                    title: "Gather requirements",
                    detail: "Create content/content.md and assets/ placeholders.",
                    likelyTools: ["Write"],
                    doneSignal: "docs/requirements.md created",
                    outputs: [
                        TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "docs/requirements.md")
                    ]
                )
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "homepage",
                    description: "Homepage exists",
                    method: .artifact,
                    path: "public/index.html"
                ),
                TaskValidationAssertion(
                    id: "about-text",
                    description: "About page names Med13",
                    method: .textContains,
                    path: "pages/about/index.html",
                    evidenceQuery: "Med13"
                )
            ])
        )

        let prepared = TaskExecutionArtifactPreparer.prepareTaskOutputArtifacts(
            task: task,
            plan: plan,
            step: plan.steps.first,
            modelContext: context,
            phase: "approved_plan"
        )

        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        #expect(prepared)
        #expect(FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("docs")))
        #expect(FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("content")))
        #expect(FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("assets")))
        #expect(FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("public")))
        #expect(FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("pages/about")))
        #expect(!FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("docs/requirements.md")))
        #expect(task.events.contains { $0.type == "astra.artifact_preflight" && $0.payload.contains("preparedDirectories") })
    }

    @Test("Artifact preflight rejects unsafe task-output paths without creating outside directories")
    func artifactPreflightRejectsUnsafeTaskOutputPaths() throws {
        let root = NSTemporaryDirectory() + "runtime-artifact-preflight-reject-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Preflight", primaryPath: root)
        let task = AgentTask(title: "Task", goal: "Goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Unsafe artifacts",
            goal: "Write files",
            steps: [
                TaskPlanPayloadStep(
                    id: "unsafe",
                    title: "Unsafe",
                    outputs: [
                        TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "../escape/result.md"),
                        TaskPlanStepOutput(kind: .file, scope: .workspace, path: "docs/workspace.md")
                    ]
                )
            ]
        )

        let prepared = TaskExecutionArtifactPreparer.prepareTaskOutputArtifacts(
            task: task,
            plan: plan,
            step: plan.steps.first,
            modelContext: context,
            phase: "approved_plan"
        )

        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        #expect(prepared)
        #expect(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("escape")))
        #expect(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("docs")))
        #expect(!FileManager.default.fileExists(atPath: (taskFolder as NSString).appendingPathComponent("docs")))
        let event = try #require(task.events.first { $0.type == "astra.artifact_preflight" })
        switch event.decodePayload(
            as: TaskArtifactPreflightEventPayload.self,
            expecting: TaskEventTypes.System.astraArtifactPreflight
        ) {
        case .success(let payload):
            #expect(payload.rejectedPaths.contains("../escape/result.md"))
            #expect(payload.skippedPaths.contains("docs/workspace.md"))
        case .failure(let error):
            Issue.record("Expected typed artifact preflight payload, got \(error)")
        }
    }

    @Test("Prepare task folder failure marks task failed before provider launch")
    func prepareTaskFolderFailureMarksTaskFailed() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Invalid", primaryPath: "/dev/null")
        let task = AgentTask(title: "Task", goal: "Goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let result = AgentRuntimeLaunchPreflight.prepareTaskFolderForLaunchResult(
            task,
            modelContext: context,
            phase: "run"
        )

        #expect(result.status == .taskFolderCreateFailed)
        #expect(!result.didPass)
        #expect(result.reason == "task_folder_create_failed")
        #expect(result.auditFields["result"] == "taskFolderCreateFailed")
        #expect(task.status == .failed)
        #expect(task.completedAt != nil)
        #expect(task.unreadAt != nil)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("could not create") })
    }

    @Test("Pre-launch failure marks run and task failed with stop reason")
    func finishPreLaunchFailurePersistsFailure() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Task", goal: "Goal")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        AgentRuntimeLaunchPreflight.finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: context,
            reason: "connector_preflight_failed",
            payload: "Connector failed"
        )

        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "connector_preflight_failed")
        #expect(run.completedAt != nil)
        #expect(task.unreadAt != nil)
        #expect(task.events.contains { $0.type == "error" && $0.run?.id == run.id && $0.payload == "Connector failed" })
    }

    @Test("Runtime readiness preflight surfaces provider authentication remediation")
    func runtimeReadinessPreflightSurfacesAuthRemediation() async throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Provider Auth", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(
            title: "Who are you",
            goal: "who are you?",
            workspace: workspace,
            runtime: .openCodeCLI
        )
        task.status = .running
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let blockedReport = RuntimeReadinessReport(checks: [
            RuntimeReadinessCheck(
                id: "opencode-account",
                title: "OpenCode account",
                detail: "No OpenCode credentials are configured.",
                state: .blocked,
                remediation: "Run `opencode auth login`, then retry."
            )
        ])

        let result = AgentRuntimeLaunchPreflight.preflightRuntimeReadinessBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "run",
            report: blockedReport
        )

        #expect(!result.didPass)
        #expect(result.status == .runtimeReadinessFailed)
        #expect(result.reason == "runtime_readiness_failed")
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "runtime_readiness_failed")
        #expect(task.events.contains {
            $0.type == "error" &&
                $0.run?.id == run.id &&
                $0.payload.contains("OpenCode account check failed before the agent ran") &&
                $0.payload.contains("No OpenCode credentials are configured.") &&
                $0.payload.contains("opencode auth login")
        })
    }

    @Test("Capability preflight blocks selected package skill without required connector")
    func capabilityPreflightBlocksSelectedPackageSkillWithoutConnector() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Legacy Jira", primaryPath: NSTemporaryDirectory())
        let jiraSkill = Skill(name: "Jira Agent", allowedTools: ["Read", "Bash"])
        jiraSkill.workspace = workspace
        let task = AgentTask(title: "Use Jira", goal: "List Jira tickets", workspace: workspace)
        task.skills = [jiraSkill]
        task.status = .running
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(jiraSkill)
        context.insert(task)
        context.insert(run)

        let result = AgentRuntimeLaunchPreflight.preflightCapabilitiesBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        #expect(result.status == .capabilityRuntimeResourcesMissing)
        #expect(!result.didPass)
        #expect(result.reason == "capability_runtime_resources_missing")
        #expect(result.auditFields["diagnostic_result"] == "capabilityRuntimeResourcesMissing")
        #expect(task.status == .failed)
        #expect(run.stopReason == "capability_runtime_resources_missing")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("Jira") && $0.payload.contains("connector") })
    }

    @Test("Capability preflight ignores stale package skill snapshots")
    func capabilityPreflightIgnoresStalePackageSkillSnapshots() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Email", primaryPath: NSTemporaryDirectory())
        let jiraSkill = Skill(name: "Jira Agent", allowedTools: ["Read", "Bash"])
        jiraSkill.workspace = workspace

        let jiraConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://example.atlassian.net",
            authMethod: "none"
        )
        jiraConnector.workspace = workspace
        jiraConnector.skill = jiraSkill

        let task = AgentTask(
            title: "Summarize email",
            goal: "Summarize my emails from today",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        task.skillSnapshots = [
            SkillSnapshotConfig(
                id: UUID().uuidString,
                name: "GitHub Agent",
                icon: "chevron.left.forwardslash.chevron.right",
                description: "Stale GitHub capability snapshot",
                allowedTools: ["Read", "Bash"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use GitHub CLI for GitHub work.",
                environmentKeys: [],
                environmentValues: [],
                isGlobal: false,
                connectorIDs: nil,
                localToolIDs: nil,
                connectorSnapshots: nil,
                localToolSnapshots: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]
        task.status = .running
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(jiraSkill)
        context.insert(jiraConnector)
        context.insert(task)
        context.insert(run)
        try context.save()

        let result = AgentRuntimeLaunchPreflight.preflightCapabilitiesBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "resume"
        )

        #expect(result.status == .capabilityRuntimeResourcesPassed)
        #expect(result.didPass)
        #expect(result.auditFields["diagnostic_result"] == "capabilityRuntimeResourcesPassed")
        #expect(task.status == .running)
        #expect(run.status == .running)
        #expect(run.stopReason.isEmpty)
        #expect(!task.events.contains { $0.type == "error" && $0.payload.contains("GitHub") })
    }
}

@Suite("Agent Runtime Run Persistence")
@MainActor
struct AgentRuntimeRunPersistenceTests {
    @Test("Fields summarize only events for the persisted run")
    func fieldsSummarizeRunScopedEvents() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Task", goal: "Goal")
        let run = TaskRun(task: task)
        let otherRun = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.exitCode = 0
        run.output = "done"
        run.inputTokens = 7
        run.outputTokens = 11
        run.providerVersion = "test-provider"
        run.appendFileChange(StoredFileChange(from: FileChange(
            path: "/tmp/result.txt",
            changeType: .write,
            content: "done",
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )))
        context.insert(task)
        context.insert(run)
        context.insert(otherRun)
        context.insert(TaskEvent(task: task, type: "agent.response", payload: "A", run: run))
        context.insert(TaskEvent(task: task, type: "agent.thinking", payload: "B", run: run))
        context.insert(TaskEvent(task: task, type: "tool.use", payload: "C", run: run))
        context.insert(TaskEvent(task: task, type: "tool.result", payload: "D", run: run))
        context.insert(TaskEvent(task: task, type: "error", payload: "E", run: run))
        context.insert(TaskEvent(task: task, type: "agent.response", payload: "Other", run: otherRun))

        let fields = AgentRuntimeRunPersistence.fields(task: task, run: run, phase: "run")

        #expect(fields["phase"] == "run")
        #expect(fields["run_status"] == "completed")
        #expect(fields["run_stop_reason"] == "completed")
        #expect(fields["exit_code"] == "0")
        #expect(fields["run_output_chars"] == "4")
        #expect(fields["response_event_count"] == "1")
        #expect(fields["thinking_event_count"] == "1")
        #expect(fields["tool_use_event_count"] == "1")
        #expect(fields["tool_result_event_count"] == "1")
        #expect(fields["error_event_count"] == "1")
        #expect(fields["run_event_count"] == "5")
        #expect(fields["file_changes"] == "1")
        #expect(fields["tokens_input"] == "7")
        #expect(fields["tokens_output"] == "11")
        #expect(fields["provider_version"] == "test-provider")
    }

    @Test("Finalize records terminal completion and unread state")
    func finalizePersistsTerminalState() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Task", goal: "Goal")
        let run = TaskRun(task: task)
        task.status = .completed
        run.status = .completed
        context.insert(task)
        context.insert(run)

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        #expect(task.completedAt != nil)
        #expect(task.unreadAt != nil)
        #expect(task.updatedAt <= Date())
    }

    @Test("Record session turn writes session history in task folder")
    func recordSessionTurnWritesHistory() throws {
        let root = NSTemporaryDirectory() + "runtime-history-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "History", primaryPath: root)
        let task = AgentTask(title: "History Task", goal: "Goal", workspace: workspace)
        let run = TaskRun(task: task)
        run.output = "assistant output"
        run.tokensUsed = 12
        run.costUSD = 0.25
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "user message"
        )

        let historyPath = SessionHistoryManager.historyPath(taskFolder: TaskWorkspaceAccess(task: task).taskFolder)
        let history = try String(contentsOfFile: historyPath, encoding: .utf8)
        #expect(history.contains("History Task"))
        #expect(history.contains("user message"))
        #expect(history.contains("assistant output"))
    }
}

@Suite("Agent Runtime Budget Policy")
@MainActor
struct AgentRuntimeBudgetPolicyTests {
    @Test("Hard stop prompt budget failure prevents launch")
    func hardStopPromptBudgetFailurePreventsLaunch() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Budget", goal: "Goal", tokenBudget: 1)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let allowed = AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: "small",
            task: task,
            run: run,
            modelContext: context,
            phase: "run",
            runtime: .claudeCode,
            budgetEnforcementMode: .hardStop
        )

        #expect(!allowed)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(run.completedAt != nil)
        #expect(task.unreadAt != nil)
        #expect(task.events.contains { $0.type == "budget.exceeded" && $0.run?.id == run.id })
    }

    @Test("Warning prompt budget records warning and allows launch")
    func warningPromptBudgetRecordsWarningAndAllowsLaunch() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Budget", goal: "Goal", tokenBudget: 1)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let allowed = AgentRuntimeBudgetPolicy.enforcePromptBudgetIfNeeded(
            prompt: "small",
            task: task,
            run: run,
            modelContext: context,
            phase: "run",
            runtime: .claudeCode,
            budgetEnforcementMode: .warning
        )

        #expect(allowed)
        #expect(task.status == .draft)
        #expect(run.status == .running)
        #expect(task.events.contains { $0.type == "budget.warning" && $0.run?.id == run.id })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Reported usage above budget is enforced only in hard stop mode")
    func reportedUsageAboveBudgetFollowsEnforcementMode() {
        let task = AgentTask(title: "Budget", goal: "Goal", tokenBudget: 10)
        task.tokensUsed = 11
        let result = AgentProcessResult(exitCode: 0)

        #expect(AgentRuntimeBudgetPolicy.hasReportedTokensAboveBudget(task: task))
        #expect(AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: .hardStop
        ))
        #expect(!AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            task: task,
            budgetEnforcementMode: .warning
        ))
    }

    @Test("Final warning records budget warning event")
    func finalWarningRecordsBudgetWarningEvent() throws {
        let container = try makeRuntimeComponentContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Budget", goal: "Goal", tokenBudget: 10)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        AgentRuntimeBudgetPolicy.recordFinalBudgetWarningIfNeeded(
            result: AgentProcessResult(exitCode: 0, budgetWarning: true),
            task: task,
            run: run,
            modelContext: context,
            phase: "run",
            budgetEnforcementMode: .warning
        )

        #expect(task.events.contains { $0.type == "budget.warning" && $0.run?.id == run.id })
    }
}

@Suite("Agent Runtime Stream Diagnostics")
@MainActor
struct AgentRuntimeStreamDiagnosticsTests {
    @Test("Unknown event shape fields summarize JSON shape")
    func unknownEventShapeFieldsSummarizeJSONShape() {
        let fields = AgentRuntimeStreamDiagnostics.unknownEventShapeFields(
            raw: #"{"type":"mystery","data":{"alpha":1,"beta":2},"payload":{"message":"hello"}}"#
        )

        #expect(fields["type_field"] == "mystery")
        #expect(fields["top_level_keys"] == "data,payload,type")
        #expect(fields["data_keys"] == "alpha,beta")
        #expect(fields["payload_keys"] == "message")
    }

    @Test("Unknown event shape fields fallback to raw length for non JSON")
    func unknownEventShapeFieldsFallbackToRawLength() {
        let fields = AgentRuntimeStreamDiagnostics.unknownEventShapeFields(raw: "not-json")

        #expect(fields["raw_length"] == "8")
        #expect(fields["decode_error"] == "data_corrupted")
        #expect(fields["top_level_keys"] == nil)
    }

    @Test("Unknown event shape fields report malformed top-level payload")
    func unknownEventShapeFieldsReportMalformedTopLevelPayload() {
        let fields = AgentRuntimeStreamDiagnostics.unknownEventShapeFields(raw: #"["event"]"#)

        #expect(fields["raw_length"] == "9")
        #expect(fields["decode_error"] == "type_mismatch")
        #expect(fields["top_level_keys"] == nil)
    }
}

@Suite("Agent Runtime Failure Payload")
@MainActor
struct AgentRuntimeFailurePayloadTests {
    @Test("Command not found failures include install guidance and raw tail")
    func commandNotFoundFailureIncludesInstallGuidance() {
        let task = AgentTask(title: "Failure", goal: "Goal")
        let payload = AgentRuntimeFailurePayload.enriched(
            prefix: "Agent exited with code 127.",
            rawError: "zsh: command not found: gcloud",
            task: task
        )

        #expect(payload.contains("Agent exited with code 127."))
        #expect(payload.contains("gcloud"))
        #expect(payload.contains("PATH"))
        #expect(payload.contains("Raw error:"))
    }

    @Test("Unrecognized failures keep prefix and raw error")
    func unrecognizedFailureKeepsRawError() {
        let task = AgentTask(title: "Failure", goal: "Goal")
        let payload = AgentRuntimeFailurePayload.enriched(
            prefix: "Agent exited with code 1.",
            rawError: "plain stderr",
            task: task
        )

        #expect(payload == "Agent exited with code 1. plain stderr")
    }
}
