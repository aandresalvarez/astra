import Testing
import Foundation
@testable import ASTRA
import ASTRACore
import SwiftData

/// Phase 1 Functional Test — Single-Agent Baseline
/// Tests the full pipeline: Workspace → AgentTask → AgentRuntimeWorker → TaskEvents + Artifacts + Files

private func makeTestContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func findOutputFile(named name: String, workspacePath: String, task: AgentTask) -> String? {
    let fm = FileManager.default
    let directCandidates = [
        (workspacePath as NSString).appendingPathComponent(name),
        (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent(name),
        ((TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent("outputs") as NSString).appendingPathComponent(name)
    ].filter { !$0.isEmpty }

    if let direct = directCandidates.first(where: { fm.fileExists(atPath: $0) }) {
        return direct
    }

    guard let enumerator = fm.enumerator(atPath: workspacePath) else { return nil }
    for case let relativePath as String in enumerator {
        guard (relativePath as NSString).lastPathComponent == name else { continue }
        return (workspacePath as NSString).appendingPathComponent(relativePath)
    }
    return nil
}

private func workspaceFileListing(at workspacePath: String) -> String {
    guard let enumerator = FileManager.default.enumerator(atPath: workspacePath) else {
        return "<unreadable>"
    }
    let files = enumerator.compactMap { $0 as? String }.prefix(80)
    return files.isEmpty ? "<empty>" : files.joined(separator: ", ")
}

private func releaseCandidateValidationSample(
    mode: LocalModelReleaseCandidateValidationMode,
    runtimeCase: E2ETestSupport.RuntimeCase,
    worker: AgentRuntimeWorker,
    run: TaskRun,
    marker: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> LocalModelReleaseCandidateValidationSample {
    let buildIdentifier = environment["ASTRA_LOCAL_MLX_RELEASE_BUILD_ID"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return LocalModelReleaseCandidateValidationSample(
        recordedAt: Date(),
        buildIdentifier: buildIdentifier?.isEmpty == false ? buildIdentifier : nil,
        mode: mode,
        outcome: .passed,
        model: runtimeCase.model,
        modelDirectory: worker.homeDirectory(for: .localMLX),
        helperPath: worker.executablePath(for: .localMLX),
        inputTokens: run.inputTokens,
        outputTokens: run.outputTokens,
        stopReason: run.stopReason,
        marker: marker
    )
}

private func recordReleaseCandidateValidationSample(
    _ sample: LocalModelReleaseCandidateValidationSample,
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    let outputPath = environment["ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !outputPath.isEmpty {
        if FileManager.default.fileExists(atPath: outputPath),
           let existingPayload = try? String(contentsOfFile: outputPath, encoding: .utf8) {
            _ = try? LocalModelReleaseCandidateValidationStore.mergeEvidence(existingPayload, defaults: defaults)
        } else {
            LocalModelReleaseCandidateValidationStore.clear(defaults: defaults)
        }
    }

    LocalModelReleaseCandidateValidationStore.record(sample, defaults: defaults)

    guard !outputPath.isEmpty else { return }
    let payload = try LocalModelReleaseCandidateValidationStore.exportEvidence(defaults: defaults)
    try FileManager.default.createDirectory(
        atPath: (outputPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try payload.write(toFile: outputPath, atomically: true, encoding: .utf8)
}

private func exportHardwareValidationEvidence(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    let outputPath = environment[LocalModelHardwareValidationStore.evidenceOutputEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !outputPath.isEmpty,
       FileManager.default.fileExists(atPath: outputPath),
       let existingPayload = try? String(contentsOfFile: outputPath, encoding: .utf8) {
        _ = try? LocalModelHardwareValidationStore.mergeEvidence(existingPayload, defaults: defaults)
    }

    guard !outputPath.isEmpty else { return }
    let payload = try LocalModelHardwareValidationStore.exportEvidence(defaults: defaults)
    try FileManager.default.createDirectory(
        atPath: (outputPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try payload.write(toFile: outputPath, atomically: true, encoding: .utf8)
}

@Suite("Phase 1 Functional — Worker E2E", .tags(.integration))
struct Phase1FunctionalTest {

    // MARK: - Workspace guard

    @Test("Task without workspace fails gracefully")
    @MainActor
    func taskWithoutWorkspaceFails() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        // Create task with NO workspace — effectiveWorkspacePath will be ""
        let task = AgentTask(
            title: "No workspace test",
            goal: "This should fail because there is no workspace"
        )
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .failed, "Task without workspace should fail, got: \(task.status.rawValue)")

        let errorEvents = task.events.filter { $0.type == "error" }
        #expect(!errorEvents.isEmpty, "Should have an error event")
        #expect(errorEvents.first?.payload.contains("not found") == true,
                "Error should mention workspace not found")
    }

    @Test("Task with invalid workspace path fails gracefully")
    @MainActor
    func taskWithBadWorkspaceFails() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Bad", primaryPath: "/nonexistent/path/xyz123")
        context.insert(workspace)

        let task = AgentTask(
            title: "Bad workspace test",
            goal: "This should fail because workspace path doesn't exist",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .failed, "Task with bad workspace should fail, got: \(task.status.rawValue)")
    }

    // MARK: - Full E2E with workspace

    @Test(
        "Workspace → Task → Worker → Text response",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call live AI CLIs"),
        arguments: E2ETestSupport.runtimeCases
    )
    @MainActor
    func workerTextResponseEndToEnd(runtimeCase: E2ETestSupport.RuntimeCase) async throws {
        let testDir = "/tmp/phase1_\(runtimeCase.directoryNameComponent)_text_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }
        defer { try? FileManager.default.removeItem(atPath: E2ETestSupport.copilotHomePath(forTemporaryRootPath: testDir)) }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Text Test Workspace", primaryPath: testDir)
        context.insert(workspace)

        let task = AgentTask(
            title: "Provider text smoke",
            goal: "Reply with one short sentence that contains exactly this marker: ASTRA_E2E_TEXT_OK",
            workspace: workspace,
            tokenBudget: 250000,
            model: runtimeCase.model
        )
        task.runtimeID = runtimeCase.runtimeID.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        var receivedEvents: [ParsedEvent] = []

        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }
        }

        let run = try #require(task.runs.first)
        let eventTypes = Set(task.events.map(\.type))
        let output = run.output.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(task.status == .completed, "Task should complete, got: \(task.status.rawValue)")
        #expect(run.status == .completed, "Run should complete, got: \(run.status.rawValue)")
        #expect(run.runtimeID == runtimeCase.runtimeID.rawValue)
        #expect(run.exitCode == 0, "Exit code should be 0, got: \(run.exitCode)")
        #expect(!output.isEmpty, "Provider should produce visible text")
        if runtimeCase.runtimeID == .localMLX {
            #expect(output.contains("ASTRA_E2E_TEXT_OK"), "Local MLX release validation output must include the requested marker")
            try recordReleaseCandidateValidationSample(releaseCandidateValidationSample(
                mode: .localChat,
                runtimeCase: runtimeCase,
                worker: worker,
                run: run,
                marker: "ASTRA_E2E_TEXT_OK"
            ))
        }
        #expect(eventTypes.contains("task.started"), "Missing task.started")
        #expect(E2ETestSupport.hasProviderProgressEvent(eventTypes), "Missing provider progress/output event")
        #expect(eventTypes.contains("task.completed"), "Missing task.completed")
        if runtimeCase.expectsUsageStats {
            #expect(task.tokensUsed > 0, "Tokens used: \(task.tokensUsed)")
            #expect(eventTypes.contains("task.stats"), "Missing task.stats")
        }
        if runtimeCase.expectsSessionID {
            #expect(task.sessionId != nil, "Session ID should be captured")
        }
        if runtimeCase.expectsResultCallback {
            #expect(receivedEvents.contains {
                if case .result = $0 { return true }
                return false
            }, "Callback should include result")
        }
    }

    @Test(
        "Local MLX Agent → ASTRA-brokered read-only tool loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1 and RUN_E2E_LOCAL_MLX_AGENT=1 to run the live Local MLX Agent tool-loop test"
        )
    )
    @MainActor
    func localMLXAgentReadOnlyToolLoopEndToEnd() async throws {
        let testDir = "/tmp/phase1_local_mlx_agent_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let noteURL = URL(fileURLWithPath: testDir).appendingPathComponent("local_agent_note.txt")
        try "ASTRA_LOCAL_AGENT_LIVE_TOOL_OK".write(to: noteURL, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent Test Workspace", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let task = AgentTask(
            title: "Local Agent live read-only smoke",
            goal: """
            Use ASTRA-brokered workspace tools to read local_agent_note.txt.
            Final answer must include exactly this marker from the file: ASTRA_LOCAL_AGENT_LIVE_TOOL_OK.
            Do not answer from memory.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        var receivedEvents: [ParsedEvent] = []

        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }
        }

        let run = try #require(task.runs.first)
        let eventTypes = Set(task.events.map(\.type))
        let output = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")
        let debugSummary = """
        stopReason=\(run.stopReason)
        output=\(output)
        events:
        \(debugEvents)
        """

        #expect(task.status == .completed, "Task should complete, got: \(task.status.rawValue)\n\(debugSummary)")
        #expect(run.status == .completed, "Run should complete, got: \(run.status.rawValue)\n\(debugSummary)")
        #expect(run.runtimeID == AgentRuntimeID.localMLX.rawValue)
        #expect(output.contains("ASTRA_LOCAL_AGENT_LIVE_TOOL_OK"), "Missing marker.\n\(debugSummary)")
        #expect(eventTypes.contains("local_agent.turn"), "Missing Local Agent turn event.\n\(debugSummary)")
        #expect(eventTypes.contains("tool.use"), "Missing ASTRA-brokered tool call.\n\(debugSummary)")
        #expect(eventTypes.contains("tool.result"), "Missing ASTRA-brokered tool observation.\n\(debugSummary)")
        #expect(receivedEvents.contains {
            if case .toolUse = $0 { return true }
            return false
        }, "Callback should include Local Agent tool use")
        try recordReleaseCandidateValidationSample(releaseCandidateValidationSample(
            mode: .localAgentReadOnly,
            runtimeCase: runtimeCase,
            worker: worker,
            run: run,
            marker: "ASTRA_LOCAL_AGENT_LIVE_TOOL_OK"
        ))
    }

    @Test(
        "Local MLX → sustained hardware validation evidence",
        .enabled(
            if: E2ETestSupport.localMLXHardwareValidationE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1 and RUN_E2E_LOCAL_MLX_HARDWARE=1 to run live Local MLX sustained hardware validation"
        )
    )
    @MainActor
    func localMLXSustainedHardwareValidationEndToEnd() async throws {
        let testDir = "/tmp/phase1_local_mlx_hardware_validation_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousPreferredModel = defaults.object(forKey: LocalModelSettingsStore.preferredModelKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(runtimeCase.model, forKey: LocalModelSettingsStore.preferredModelKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousPreferredModel {
                defaults.set(previousPreferredModel, forKey: LocalModelSettingsStore.preferredModelKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.preferredModelKey)
            }
        }

        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(worker.executablePath(for: .localMLX), for: .localMLX)
        settings.setHomeDirectory(worker.homeDirectory(for: .localMLX), for: .localMLX)
        let configuration = RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        )

        let iterations = Int(ProcessInfo.processInfo.environment["RUN_E2E_LOCAL_MLX_HARDWARE_ITERATIONS"] ?? "") ?? 3
        let validation = await LocalModelSustainedValidationService().run(
            configuration: configuration,
            mode: .localAgentReadOnly,
            iterations: iterations,
            defaults: defaults
        )
        try exportHardwareValidationEvidence(defaults: defaults)

        let sample = try #require(LocalModelHardwareValidationStore.samples(defaults: defaults).last)
        let currentTier = LocalModelHardwareValidationMatrix.tier(for: LocalHardwareProfile.current())
        let sampleTier = LocalModelHardwareValidationMatrix.tier(for: sample.profile)
        let debugSummary = """
        check=\(validation.check.state.rawValue): \(validation.check.detail)
        remediation=\(validation.check.remediation ?? "none")
        sampleTier=\(sampleTier?.displayName ?? "unknown")
        currentTier=\(currentTier?.displayName ?? "unknown")
        outcome=\(sample.outcome.rawValue)
        iterations=\(sample.iterations)
        """

        #expect(validation.check.state != .blocked, "Hardware validation should not block on this configured Mac.\n\(debugSummary)")
        #expect(sample.mode == .localAgentReadOnly)
        #expect(sample.profile.model == runtimeCase.model)
        #expect(sample.profile.backend == "mlx")
        #expect(sampleTier == currentTier, "Sample should classify this Mac's tier.\n\(debugSummary)")
        if currentTier == .lowMemory8GB {
            #expect(sample.outcome == .blockedAsExpected, "Low-memory Macs should be recorded as expected blocks.\n\(debugSummary)")
        } else {
            #expect(sample.outcome == .passed, "Expected a passed sustained validation sample.\n\(debugSummary)")
            #expect(sample.iterations == max(1, min(iterations, 10)), "Unexpected iteration count.\n\(debugSummary)")
            #expect(sample.durationSeconds > 0, "Duration should be recorded.\n\(debugSummary)")
            #expect(sample.profile.tokensPerSecond != nil, "Throughput should be captured.\n\(debugSummary)")
        }
        if let currentTier {
            #expect(validation.hardwareReport.coveredTiers.contains(currentTier), "Hardware report should cover this Mac tier.\n\(debugSummary)")
        }
    }

    @Test(
        "Local MLX Agent → task output write approval loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentHighRiskE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1, RUN_E2E_LOCAL_MLX_AGENT=1, and RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1 to run live Local MLX Agent high-risk approval tests"
        )
    )
    @MainActor
    func localMLXAgentTaskOutputWriteApprovalEndToEnd() async throws {
        let testDir = "/tmp/phase1_local_mlx_agent_task_output_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousTaskOutputWrite = defaults.object(forKey: LocalAgentToolCapability.taskOutputWrite.settingsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.taskOutputWrite.settingsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousTaskOutputWrite {
                defaults.set(previousTaskOutputWrite, forKey: LocalAgentToolCapability.taskOutputWrite.settingsKey)
            } else {
                defaults.removeObject(forKey: LocalAgentToolCapability.taskOutputWrite.settingsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent High Risk Workspace", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let marker = "ASTRA_LOCAL_AGENT_HIGH_RISK_OUTPUT_OK"
        let outputRelativePath = "beta-soak/high-risk-task-output.md"
        let task = AgentTask(
            title: "Local Agent live task output approval smoke",
            goal: """
            Use exactly one ASTRA-brokered `task.write_output` tool call to create `\(outputRelativePath)`.
            The file content must be exactly:
            \(marker)

            This write requires ASTRA approval. First request the `task.write_output` tool call.
            After ASTRA approves and returns a tool observation, finish with one sentence that includes exactly this marker: \(marker).
            Do not use `workspace.write_file`, shell commands, browser tools, network tools, or connector tools.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.skipPermissions = false
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") ?? 180

        var receivedEvents: [ParsedEvent] = []
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }

            let firstRun = try #require(task.runs.first)
            let firstDebugEvents = task.events
                .map { "\($0.type): \($0.payload)" }
                .joined(separator: "\n")
            #expect(task.status == .pendingUser, "Task should pause for approval, got: \(task.status.rawValue)\n\(firstDebugEvents)")
            #expect(firstRun.status == .failed, "First run should stop before the write.\n\(firstDebugEvents)")
            #expect(firstRun.stopReason == "permission_approval_required", "Expected approval stop, got: \(firstRun.stopReason)\n\(firstDebugEvents)")

            let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
            let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
            #expect(approvalPayload.providerID == .localMLX)
            switch approvalPayload.request {
            case .fileWrite(let path, let toolName):
                #expect(path.hasSuffix(outputRelativePath), "Unexpected approval path: \(path)")
                #expect(toolName == "Write")
            default:
                Issue.record("Expected task.write_output to request a file-write approval.")
            }
            let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
            #expect(grants.contains(.providerTool(name: "Write")))
            #expect(grants.contains {
                if case .filePath(let path, let access) = $0 {
                    return access == "write" && path.hasSuffix(outputRelativePath)
                }
                return false
            })

            await worker.continueSession(
                task: task,
                message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
                modelContext: context,
                executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
            ) { event in
                receivedEvents.append(event)
            }
        }

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let finalRun = try #require(runs.last)
        let eventTypes = Set(task.events.map(\.type))
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")
        let outputURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(outputRelativePath)
        let fileContent = try String(contentsOf: outputURL, encoding: .utf8)

        #expect(runs.count == 2, "Approval flow should create exactly two runs.\n\(debugEvents)")
        #expect(task.status == .completed, "Task should complete after approval, got: \(task.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.status == .completed, "Final run should complete, got: \(finalRun.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.output.contains(marker), "Final answer missing marker.\n\(debugEvents)")
        #expect(fileContent.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
        #expect(eventTypes.contains("permission.approval.requested"), "Missing approval event.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("task.write_output")
        }, "Missing approved local policy replay.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains(outputRelativePath)
        }, "Missing task.write_output observation.\n\(debugEvents)")
        #expect(receivedEvents.contains {
            if case .toolUse(let name, _, _) = $0 { return name == "task.write_output" }
            return false
        }, "Callback should include task.write_output tool use")
    }

    @Test(
        "Local MLX Agent → workspace write approval loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentHighRiskE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1, RUN_E2E_LOCAL_MLX_AGENT=1, and RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1 to run live Local MLX Agent high-risk approval tests"
        )
    )
    @MainActor
    func localMLXAgentWorkspaceWriteApprovalEndToEnd() async throws {
        let testDir = "/tmp/phase1_local_mlx_agent_workspace_write_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousWorkspaceWrite = defaults.object(forKey: LocalAgentToolCapability.workspaceWrite.settingsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.workspaceWrite.settingsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousWorkspaceWrite {
                defaults.set(previousWorkspaceWrite, forKey: LocalAgentToolCapability.workspaceWrite.settingsKey)
            } else {
                defaults.removeObject(forKey: LocalAgentToolCapability.workspaceWrite.settingsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent Workspace Write", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let marker = "ASTRA_LOCAL_AGENT_HIGH_RISK_WORKSPACE_OK"
        let outputRelativePath = "beta-soak/high-risk-workspace.md"
        let outputURL = URL(fileURLWithPath: testDir).appendingPathComponent(outputRelativePath)
        let task = AgentTask(
            title: "Local Agent live workspace write approval smoke",
            goal: """
            Use exactly one ASTRA-brokered `workspace.write_file` tool call to create `\(outputRelativePath)`.
            The file content must be exactly:
            \(marker)

            This workspace edit requires ASTRA approval. First request the `workspace.write_file` tool call with `overwrite` set to false.
            After ASTRA approves and returns a tool observation, finish with one sentence that includes exactly this marker: \(marker).
            Do not use `task.write_output`, shell commands, browser tools, network tools, or connector tools.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.skipPermissions = false
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") ?? 180

        var receivedEvents: [ParsedEvent] = []
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }

            let firstRun = try #require(task.runs.first)
            let firstDebugEvents = task.events
                .map { "\($0.type): \($0.payload)" }
                .joined(separator: "\n")
            #expect(task.status == .pendingUser, "Task should pause for approval, got: \(task.status.rawValue)\n\(firstDebugEvents)")
            #expect(firstRun.status == .failed, "First run should stop before the write.\n\(firstDebugEvents)")
            #expect(firstRun.stopReason == "permission_approval_required", "Expected approval stop, got: \(firstRun.stopReason)\n\(firstDebugEvents)")
            #expect(!FileManager.default.fileExists(atPath: outputURL.path), "Workspace file should not exist before approval.")

            let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
            let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
            #expect(approvalPayload.providerID == .localMLX)
            #expect(approvalPayload.displayMessage.contains("Diff preview"))
            switch approvalPayload.request {
            case .fileWrite(let path, let toolName):
                #expect(path.hasSuffix(outputRelativePath), "Unexpected approval path: \(path)")
                #expect(toolName == "Write")
            default:
                Issue.record("Expected workspace.write_file to request a file-write approval.")
            }
            let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
            #expect(grants.contains(.providerTool(name: "Write")))
            #expect(grants.contains {
                if case .filePath(let path, let access) = $0 {
                    return access == "write" && path.hasSuffix(outputRelativePath)
                }
                return false
            })

            await worker.continueSession(
                task: task,
                message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
                modelContext: context,
                executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
            ) { event in
                receivedEvents.append(event)
            }
        }

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let finalRun = try #require(runs.last)
        let eventTypes = Set(task.events.map(\.type))
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")
        let fileContent = try String(contentsOf: outputURL, encoding: .utf8)

        #expect(runs.count == 2, "Approval flow should create exactly two runs.\n\(debugEvents)")
        #expect(task.status == .completed, "Task should complete after approval, got: \(task.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.status == .completed, "Final run should complete, got: \(finalRun.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.output.contains(marker), "Final answer missing marker.\n\(debugEvents)")
        #expect(fileContent.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
        #expect(eventTypes.contains("permission.approval.requested"), "Missing approval event.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("workspace.write_file")
        }, "Missing approved local policy replay.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.tool_artifact" && $0.payload.contains("workspace_file_edit")
        }, "Missing workspace rollback/audit artifact.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains(outputRelativePath)
        }, "Missing workspace.write_file observation.\n\(debugEvents)")
        #expect(receivedEvents.contains {
            if case .toolUse(let name, _, _) = $0 { return name == "workspace.write_file" }
            return false
        }, "Callback should include workspace.write_file tool use")
    }

    @Test(
        "Local MLX Agent → shell exec approval loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentHighRiskE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1, RUN_E2E_LOCAL_MLX_AGENT=1, and RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1 to run live Local MLX Agent high-risk approval tests"
        )
    )
    @MainActor
    func localMLXAgentShellExecApprovalEndToEnd() async throws {
        let testDir = "/tmp/phase1_local_mlx_agent_shell_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let marker = "ASTRA_LOCAL_AGENT_HIGH_RISK_SHELL_OK"
        let markerFileURL = URL(fileURLWithPath: testDir).appendingPathComponent("\(marker).txt")
        try "Shell-visible marker.\n".write(to: markerFileURL, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousShellExecution = defaults.object(forKey: LocalAgentToolCapability.shellExecution.settingsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.shellExecution.settingsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousShellExecution {
                defaults.set(previousShellExecution, forKey: LocalAgentToolCapability.shellExecution.settingsKey)
            } else {
                defaults.removeObject(forKey: LocalAgentToolCapability.shellExecution.settingsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent Shell", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let task = AgentTask(
            title: "Local Agent live shell approval smoke",
            goal: """
            Use exactly one ASTRA-brokered `shell.exec` tool call to list the workspace.
            The tool call arguments must use command exactly `/bin/ls -1`, cwd exactly `.`, timeout_seconds 10, and max_output_bytes 1000.

            This shell command requires ASTRA approval. First request the `shell.exec` tool call.
            After ASTRA approves and returns a tool observation, finish with one sentence that includes exactly this marker from the shell stdout: \(marker).
            Do not use file-write, browser, network, or connector tools.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.skipPermissions = false
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") ?? 180

        var receivedEvents: [ParsedEvent] = []
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }

            let firstRun = try #require(task.runs.first)
            let firstDebugEvents = task.events
                .map { "\($0.type): \($0.payload)" }
                .joined(separator: "\n")
            #expect(task.status == .pendingUser, "Task should pause for approval, got: \(task.status.rawValue)\n\(firstDebugEvents)")
            #expect(firstRun.status == .failed, "First run should stop before shell execution.\n\(firstDebugEvents)")
            #expect(firstRun.stopReason == "permission_approval_required", "Expected approval stop, got: \(firstRun.stopReason)\n\(firstDebugEvents)")

            let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
            let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
            #expect(approvalPayload.providerID == .localMLX)
            #expect(approvalPayload.displayMessage.contains("Shell command preview"))
            #expect(approvalPayload.displayMessage.contains("/bin/ls -1"))
            #expect(approvalPayload.displayMessage.contains("Output cap: 1000 bytes per stream"))
            switch approvalPayload.request {
            case .shell(let command, let toolName):
                #expect(command == "/bin/ls -1")
                #expect(toolName == "Bash")
            default:
                Issue.record("Expected shell.exec to request shell approval.")
            }
            let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
            #expect(grants.contains {
                if case .shellCommand(let executable, _) = $0 {
                    return executable == "ls"
                }
                return false
            })

            await worker.continueSession(
                task: task,
                message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
                modelContext: context,
                executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
            ) { event in
                receivedEvents.append(event)
            }
        }

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let finalRun = try #require(runs.last)
        let eventTypes = Set(task.events.map(\.type))
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")

        #expect(runs.count == 2, "Approval flow should create exactly two runs.\n\(debugEvents)")
        #expect(task.status == .completed, "Task should complete after approval, got: \(task.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.status == .completed, "Final run should complete, got: \(finalRun.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.output.contains(marker), "Final answer missing shell marker.\n\(debugEvents)")
        #expect(eventTypes.contains("permission.approval.requested"), "Missing approval event.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("shell.exec")
        }, "Missing approved local policy replay.\n\(debugEvents)")
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact" && $0.payload.contains("shell_execution")
        })
        #expect(
            artifactEvent.payload.contains(#""command":"\/bin\/ls -1""#)
                || artifactEvent.payload.contains(#""command":"/bin/ls -1""#),
            "Missing shell command artifact.\n\(artifactEvent.payload)"
        )
        #expect(artifactEvent.payload.contains(#""exit_code":"0""#), "Missing successful shell exit code.\n\(artifactEvent.payload)")
        #expect(artifactEvent.payload.contains(#""timed_out":"false""#), "Shell command should not time out.\n\(artifactEvent.payload)")
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("stdout") && $0.payload.contains(marker)
        }, "Missing shell stdout observation.\n\(debugEvents)")
        #expect(receivedEvents.contains {
            if case .toolUse(let name, _, _) = $0 { return name == "shell.exec" }
            return false
        }, "Callback should include shell.exec tool use")
    }

    @Test(
        "Local MLX Agent → network fetch approval loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentHighRiskE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1, RUN_E2E_LOCAL_MLX_AGENT=1, and RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1 to run live Local MLX Agent high-risk approval tests"
        )
    )
    @MainActor
    func localMLXAgentNetworkFetchApprovalEndToEnd() async throws {
        let marker = "ASTRA_LOCAL_AGENT_HIGH_RISK_NETWORK_OK"
        let server = PathRoutingHTTPTestServer(routes: [
            .init(
                requestContains: "/local-agent-network-live",
                responseBody: #"{"ok":true,"marker":"\#(marker)"}"#
            )
        ])
        let port = try server.start()
        defer { server.stop() }

        let testDir = "/tmp/phase1_local_mlx_agent_network_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousNetworkFetch = defaults.object(forKey: LocalAgentToolCapability.networkFetch.settingsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.networkFetch.settingsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousNetworkFetch {
                defaults.set(previousNetworkFetch, forKey: LocalAgentToolCapability.networkFetch.settingsKey)
            } else {
                defaults.removeObject(forKey: LocalAgentToolCapability.networkFetch.settingsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent Network", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let fetchURL = "http://127.0.0.1:\(port)/local-agent-network-live"
        let task = AgentTask(
            title: "Local Agent live network approval smoke",
            goal: """
            Use exactly one ASTRA-brokered `network.fetch` tool call to fetch this URL:
            \(fetchURL)

            The tool call arguments must use method exactly `GET`, timeout_seconds 10, and max_response_bytes 1000.
            This network fetch requires ASTRA approval. First request the `network.fetch` tool call.
            After ASTRA approves and returns a tool observation, finish with one sentence that includes exactly this marker from the response body: \(marker).
            Do not use file-write, shell, browser, or connector tools.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.skipPermissions = false
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") ?? 180

        var receivedEvents: [ParsedEvent] = []
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }

            let firstRun = try #require(task.runs.first)
            let firstDebugEvents = task.events
                .map { "\($0.type): \($0.payload)" }
                .joined(separator: "\n")
            #expect(task.status == .pendingUser, "Task should pause for approval, got: \(task.status.rawValue)\n\(firstDebugEvents)")
            #expect(firstRun.status == .failed, "First run should stop before network fetch.\n\(firstDebugEvents)")
            #expect(firstRun.stopReason == "permission_approval_required", "Expected approval stop, got: \(firstRun.stopReason)\n\(firstDebugEvents)")

            let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
            let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
            #expect(approvalPayload.providerID == .localMLX)
            #expect(approvalPayload.displayMessage.contains("Network fetch preview"))
            #expect(approvalPayload.displayMessage.contains(fetchURL))
            #expect(approvalPayload.displayMessage.contains("Response cap: 1000 bytes"))
            switch approvalPayload.request {
            case .network(let url, let toolName):
                #expect(url == fetchURL)
                #expect(toolName == "WebFetch")
            default:
                Issue.record("Expected network.fetch to request network approval.")
            }
            let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
            #expect(grants.contains(.networkPattern(pattern: fetchURL)))
            #expect(grants.contains(.providerTool(name: "WebFetch")))

            await worker.continueSession(
                task: task,
                message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
                modelContext: context,
                executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
            ) { event in
                receivedEvents.append(event)
            }
        }

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let finalRun = try #require(runs.last)
        let eventTypes = Set(task.events.map(\.type))
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")

        #expect(runs.count == 2, "Approval flow should create exactly two runs.\n\(debugEvents)")
        #expect(task.status == .completed, "Task should complete after approval, got: \(task.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.status == .completed, "Final run should complete, got: \(finalRun.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.output.contains(marker), "Final answer missing network marker.\n\(debugEvents)")
        #expect(eventTypes.contains("permission.approval.requested"), "Missing approval event.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("network.fetch")
        }, "Missing approved local policy replay.\n\(debugEvents)")
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact" && $0.payload.contains("network_fetch")
        })
        #expect(artifactEvent.payload.contains(#""status_code":"200""#), "Missing successful network status.\n\(artifactEvent.payload)")
        #expect(artifactEvent.payload.contains(#""response_truncated":"false""#), "Network response should not be truncated.\n\(artifactEvent.payload)")
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains(marker)
        }, "Missing network response observation.\n\(debugEvents)")
        #expect(receivedEvents.contains {
            if case .toolUse(let name, _, _) = $0 { return name == "network.fetch" }
            return false
        }, "Callback should include network.fetch tool use")
    }

    @Test(
        "Local MLX Agent → browser click approval loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentHighRiskE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1, RUN_E2E_LOCAL_MLX_AGENT=1, and RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1 to run live Local MLX Agent high-risk approval tests"
        )
    )
    @MainActor
    func localMLXAgentBrowserClickApprovalEndToEnd() async throws {
        let marker = "ASTRA_LOCAL_AGENT_HIGH_RISK_BROWSER_CLICK_OK"
        let testDir = "/tmp/phase1_local_mlx_agent_browser_click_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            try? FileManager.default.removeItem(atPath: testDir)
        }

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousBrowserClick = defaults.object(forKey: LocalAgentToolCapability.browserClick.settingsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.browserClick.settingsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousBrowserClick {
                defaults.set(previousBrowserClick, forKey: LocalAgentToolCapability.browserClick.settingsKey)
            } else {
                defaults.removeObject(forKey: LocalAgentToolCapability.browserClick.settingsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent Browser Click", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let task = AgentTask(
            title: "Local Agent live browser click approval smoke",
            goal: """
            Use exactly one ASTRA-brokered `browser.click` tool call.
            The tool call arguments must be exactly:
            {"analysisID":"ana_1","controlID":"save-button","role":"button"}

            This browser click requires ASTRA approval. First request the `browser.click` tool call.
            After ASTRA approves and returns a tool observation, finish with one sentence that includes exactly this marker from the browser response: \(marker).
            Do not use file-write, shell, network, or connector tools.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let endpoint = Phase1BrowserBridgeTestEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "browser-token", route: { request in
            switch (request.method, request.path) {
            case ("GET", "/analyze"):
                return .json([
                    "ok": true,
                    "analysisID": "ana_1",
                    "controls": [[
                        "id": "save-button",
                        "role": "button",
                        "name": "Save"
                    ]]
                ])
            case ("POST", "/click"):
                let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
                return .json([
                    "ok": object["analysisID"] as? String == "ana_1"
                        && object["controlID"] as? String == "save-button"
                        && object["allowDangerous"] as? Bool == false,
                    "clicked": true,
                    "summary": "Clicked Save",
                    "marker": marker
                ])
            default:
                return .json(["ok": false, "path": request.path], statusCode: 404)
            }
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }
        let bridgeURL = try await endpoint.waitForURL()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeURL.absoluteString,
            currentURL: "https://example.test/document",
            currentTitle: "Document",
            taskID: task.id,
            accessToken: "browser-token",
            isPresented: true,
            isEnabled: true
        )

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.skipPermissions = false
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") ?? 180

        var receivedEvents: [ParsedEvent] = []
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }

            let firstRun = try #require(task.runs.first)
            let firstDebugEvents = task.events
                .map { "\($0.type): \($0.payload)" }
                .joined(separator: "\n")
            #expect(task.status == .pendingUser, "Task should pause for approval, got: \(task.status.rawValue)\n\(firstDebugEvents)")
            #expect(firstRun.status == .failed, "First run should stop before browser click.\n\(firstDebugEvents)")
            #expect(firstRun.stopReason == "permission_approval_required", "Expected approval stop, got: \(firstRun.stopReason)\n\(firstDebugEvents)")

            let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
            let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
            #expect(approvalPayload.providerID == .localMLX)
            #expect(approvalPayload.displayMessage.contains("Browser click preview"))
            #expect(approvalPayload.displayMessage.contains("analysis:ana_1#save-button"))
            #expect(approvalPayload.displayMessage.contains("Dangerous confirmations: disabled"))
            let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
            #expect(grants == [.browserAction(action: "browser.click", target: "analysis:ana_1#save-button")])

            await worker.continueSession(
                task: task,
                message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
                modelContext: context,
                executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
            ) { event in
                receivedEvents.append(event)
            }
        }

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let finalRun = try #require(runs.last)
        let eventTypes = Set(task.events.map(\.type))
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")

        #expect(runs.count == 2, "Approval flow should create exactly two runs.\n\(debugEvents)")
        #expect(task.status == .completed, "Task should complete after approval, got: \(task.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.status == .completed, "Final run should complete, got: \(finalRun.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.output.contains(marker), "Final answer missing browser click marker.\n\(debugEvents)")
        #expect(eventTypes.contains("permission.approval.requested"), "Missing approval event.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("browser.click")
        }, "Missing approved local policy replay.\n\(debugEvents)")
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact" && $0.payload.contains("browser_mutation")
        })
        #expect(artifactEvent.payload.contains(#""action":"click""#), "Missing click artifact.\n\(artifactEvent.payload)")
        #expect(artifactEvent.payload.contains(#""target":"analysis:ana_1#save-button""#), "Missing click target.\n\(artifactEvent.payload)")
        #expect(artifactEvent.payload.contains(#""bridge_ok":"true""#), "Missing bridge success.\n\(artifactEvent.payload)")
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains(marker)
        }, "Missing browser click observation.\n\(debugEvents)")
        #expect(receivedEvents.contains {
            if case .toolUse(let name, _, _) = $0 { return name == "browser.click" }
            return false
        }, "Callback should include browser.click tool use")
    }

    @Test(
        "Local MLX Agent → browser type approval loop",
        .enabled(
            if: E2ETestSupport.localMLXAgentHighRiskE2EEnabled(environment: ProcessInfo.processInfo.environment),
            "Set RUN_E2E=1, RUN_E2E_LOCAL_MLX_AGENT=1, and RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1 to run live Local MLX Agent high-risk approval tests"
        )
    )
    @MainActor
    func localMLXAgentBrowserTypeApprovalEndToEnd() async throws {
        let marker = "ASTRA_LOCAL_AGENT_HIGH_RISK_BROWSER_TYPE_OK"
        let typedText = "Astra search"
        let testDir = "/tmp/phase1_local_mlx_agent_browser_type_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            try? FileManager.default.removeItem(atPath: testDir)
        }

        let defaults = UserDefaults.standard
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousExperimentalTools = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousBrowserType = defaults.object(forKey: LocalAgentToolCapability.browserType.settingsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.browserType.settingsKey)
        defer {
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousExperimentalTools {
                defaults.set(previousExperimentalTools, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousBrowserType {
                defaults.set(previousBrowserType, forKey: LocalAgentToolCapability.browserType.settingsKey)
            } else {
                defaults.removeObject(forKey: LocalAgentToolCapability.browserType.settingsKey)
            }
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Phase1 Local Agent Browser Type", primaryPath: testDir)
        context.insert(workspace)

        var environment = ProcessInfo.processInfo.environment
        environment["RUN_E2E_RUNTIME"] = "local_mlx"
        let runtimeCase = try #require(E2ETestSupport.runtimeCases(environment: environment).first {
            $0.runtimeID == .localMLX
        })

        let task = AgentTask(
            title: "Local Agent live browser type approval smoke",
            goal: """
            Use exactly one ASTRA-brokered `browser.type` tool call.
            The tool call arguments must be exactly:
            {"selector":"input[name=q]","text":"\(typedText)","clear":true}

            This browser typing requires ASTRA approval. First request the `browser.type` tool call.
            After ASTRA approves and returns a tool observation, finish with one sentence that includes exactly this marker from the browser response: \(marker).
            Do not use file-write, shell, network, or connector tools.
            """,
            workspace: workspace,
            tokenBudget: 250_000,
            model: runtimeCase.model
        )
        task.runtimeID = AgentRuntimeID.localMLX.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let endpoint = Phase1BrowserBridgeTestEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "browser-token", route: { request in
            switch (request.method, request.path) {
            case ("GET", "/analyze"):
                return .json([
                    "ok": true,
                    "analysisID": "ana_1",
                    "controls": [[
                        "selector": "input[name=q]",
                        "role": "textbox",
                        "name": "Search"
                    ]]
                ])
            case ("POST", "/type"):
                let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
                let hasValidSelector = object["selector"] as? String == "input[name=q]"
                let hasValidAnalysisTarget = (object["analysisID"] as? String)?.isEmpty == false
                    && (object["controlID"] as? String)?.isEmpty == false
                return .json([
                    "ok": (hasValidSelector || hasValidAnalysisTarget)
                        && object["text"] as? String == typedText
                        && object["clear"] as? Bool == true
                        && object["allowDangerous"] as? Bool == false,
                    "typed": true,
                    "summary": "Typed search text",
                    "marker": marker
                ])
            default:
                return .json(["ok": false, "path": request.path], statusCode: 404)
            }
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }
        let bridgeURL = try await endpoint.waitForURL()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeURL.absoluteString,
            currentURL: "https://example.test/search",
            currentTitle: "Search",
            taskID: task.id,
            accessToken: "browser-token",
            isPresented: true,
            isEnabled: true
        )

        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.skipPermissions = false
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") ?? 180

        var receivedEvents: [ParsedEvent] = []
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }

            let firstRun = try #require(task.runs.first)
            let firstDebugEvents = task.events
                .map { "\($0.type): \($0.payload)" }
                .joined(separator: "\n")
            #expect(task.status == .pendingUser, "Task should pause for approval, got: \(task.status.rawValue)\n\(firstDebugEvents)")
            #expect(firstRun.status == .failed, "First run should stop before browser typing.\n\(firstDebugEvents)")
            #expect(firstRun.stopReason == "permission_approval_required", "Expected approval stop, got: \(firstRun.stopReason)\n\(firstDebugEvents)")

            let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
            let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
            #expect(approvalPayload.providerID == .localMLX)
            #expect(approvalPayload.displayMessage.contains("Browser typing preview"))
            #expect(approvalPayload.displayMessage.contains("Text length: \(typedText.count) characters"))
            #expect(approvalPayload.displayMessage.contains("Dangerous confirmations: disabled"))
            let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
            let grant = try #require(grants.first {
                if case .browserAction(let action, _) = $0 {
                    return action == "browser.type"
                }
                return false
            })
            let approvedTarget: String
            if case .browserAction(_, let target) = grant {
                approvedTarget = target
            } else {
                Issue.record("Expected browser.type approval grant.")
                approvedTarget = ""
            }
            #expect(
                approvedTarget == "selector:input[name=q]" || approvedTarget.hasPrefix("analysis:"),
                "Unexpected browser.type approval target: \(approvedTarget)"
            )
            #expect(approvalPayload.displayMessage.contains(approvedTarget))

            await worker.continueSession(
                task: task,
                message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
                modelContext: context,
                executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
            ) { event in
                receivedEvents.append(event)
            }
        }

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let finalRun = try #require(runs.last)
        let eventTypes = Set(task.events.map(\.type))
        let debugEvents = task.events
            .map { "\($0.type): \($0.payload)" }
            .joined(separator: "\n")

        #expect(runs.count == 2, "Approval flow should create exactly two runs.\n\(debugEvents)")
        #expect(task.status == .completed, "Task should complete after approval, got: \(task.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.status == .completed, "Final run should complete, got: \(finalRun.status.rawValue)\n\(debugEvents)")
        #expect(finalRun.output.contains(marker), "Final answer missing browser type marker.\n\(debugEvents)")
        #expect(eventTypes.contains("permission.approval.requested"), "Missing approval event.\n\(debugEvents)")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("browser.type")
        }, "Missing approved local policy replay.\n\(debugEvents)")
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact" && $0.payload.contains("browser_mutation")
        })
        #expect(artifactEvent.payload.contains(#""action":"type""#), "Missing type artifact.\n\(artifactEvent.payload)")
        #expect(artifactEvent.payload.contains(#""text_chars":"\#(typedText.count)""#), "Missing typed character count.\n\(artifactEvent.payload)")
        #expect(artifactEvent.payload.contains(#""bridge_ok":"true""#), "Missing bridge success.\n\(artifactEvent.payload)")
        #expect(!artifactEvent.payload.contains(typedText), "Browser type artifact should not store typed text.\n\(artifactEvent.payload)")
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains(marker)
        }, "Missing browser type observation.\n\(debugEvents)")
        #expect(receivedEvents.contains {
            if case .toolUse(let name, _, _) = $0 { return name == "browser.type" }
            return false
        }, "Callback should include browser.type tool use")
    }

    @Test(
        "Workspace → Task → Worker → Events → Files",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call live AI CLIs"),
        arguments: E2ETestSupport.artifactRuntimeCases
    )
    @MainActor
    func workerEndToEnd(runtimeCase: E2ETestSupport.RuntimeCase) async throws {
        // 1. Create workspace directory
        let testDir = "/tmp/phase1_\(runtimeCase.directoryNameComponent)_worker_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }
        defer { try? FileManager.default.removeItem(atPath: E2ETestSupport.copilotHomePath(forTemporaryRootPath: testDir)) }

        // 2. Create SwiftData container and workspace
        let container = try makeTestContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Phase1 Test Workspace", primaryPath: testDir)
        context.insert(workspace)
        #expect(workspace.primaryPath == testDir)
        #expect(workspace.name == "Phase1 Test Workspace")

        // 3. Create task attached to workspace
        let task = AgentTask(
            title: "Word counter test",
            goal: """
            Complete this small filesystem task with minimal discussion and no subagents.
            Create these final deliverables in the current working directory:
            - ./word_counter.py: a Python script that takes one text file argument and prints the top 5 most frequent words.
            - ./sample.txt: three short paragraphs of dummy text.
            - ./results.txt: the captured output from running `python3 word_counter.py sample.txt`.
            Verify all three files exist before your final response.
            """,
            workspace: workspace,
            tokenBudget: 250000,
            model: runtimeCase.model
        )
        task.runtimeID = runtimeCase.runtimeID.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        #expect(task.workspace === workspace, "Task should be linked to workspace")
        #expect(TaskWorkspaceAccess(task: task).effectiveWorkspacePath == testDir, "Task workspace path should match")
        #expect(task.status == .queued, "Task should be explicitly queued before direct worker execution")
        #expect(workspace.tasks.contains(task), "Workspace should contain the task")

        // 4. Run through AgentRuntimeWorker (same code path as the app)
        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        var receivedEvents: [ParsedEvent] = []

        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }
        }

        // 5. Verify task lifecycle
        let isTerminal = task.isTerminal || task.status == .pendingUser
        #expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
        #expect(task.status != .failed, "Task should not have failed, status: \(task.status.rawValue)")
        if runtimeCase.expectsUsageStats {
            #expect(task.tokensUsed > 0, "Tokens used: \(task.tokensUsed)")
        }
        if runtimeCase.expectsCostUSD {
            #expect(task.costUSD > 0, "Cost: \(task.costUSD)")
        }
        if runtimeCase.expectsSessionID {
            #expect(task.sessionId != nil, "Session ID should be captured")
        }

        // 6. Verify TaskRun
        #expect(task.runs.count >= 1, "Should have at least 1 run")
        let run = task.runs.first!
        #expect(run.runtimeID == runtimeCase.runtimeID.rawValue)
        if runtimeCase.expectsUsageStats {
            #expect(run.tokensUsed > 0)
        }
        #expect(run.completedAt != nil)
        #expect(run.exitCode == 0, "Exit code should be 0, got: \(run.exitCode)")

        // 7. Verify TaskEvents in SwiftData (these are what the Activity tab renders)
        let allEvents = task.events
        let eventTypes = Set(allEvents.map(\.type))

        #expect(eventTypes.contains("task.started"), "Missing task.started")
        #expect(E2ETestSupport.hasProviderProgressEvent(eventTypes), "Missing provider progress/output event")
        if runtimeCase.expectsStructuredToolEvents {
            #expect(eventTypes.contains("tool.use"), "Missing tool.use")
        }
        if runtimeCase.expectsUsageStats {
            #expect(eventTypes.contains("task.stats"), "Missing task.stats")
        }
        #expect(eventTypes.contains("task.completed"), "Missing task.completed")

        // Verify Write and Bash tool usage recorded
        let toolPayloads = allEvents.filter { $0.type == "tool.use" }.map(\.payload)
        if runtimeCase.runtimeID == .claudeCode {
            #expect(toolPayloads.contains { $0.contains("Write") }, "Should record Write tool use")
            #expect(toolPayloads.contains { $0.contains("Bash") }, "Should record Bash tool use")
        } else {
            #expect(!run.fileChanges.isEmpty, "\(runtimeCase.runtimeID.displayName) should infer file changes")
        }

        // 8. Verify Artifacts (these are what the Artifacts tab renders)
        let artifacts = task.artifacts
        #expect(!artifacts.isEmpty, "Should have artifacts")
        let artifactPaths = artifacts.map(\.path)
        #expect(artifactPaths.contains { $0.hasSuffix("word_counter.py") }, "Missing word_counter.py artifact")
        #expect(artifactPaths.contains { $0.hasSuffix("sample.txt") }, "Missing sample.txt artifact")

        // 9. Verify files on disk
        let fm = FileManager.default
        let fileListing = workspaceFileListing(at: testDir)
        let wordCounterPath = try #require(
            findOutputFile(named: "word_counter.py", workspacePath: testDir, task: task),
            "word_counter.py missing from workspace or task output folder. Files: \(fileListing)"
        )
        let samplePath = try #require(
            findOutputFile(named: "sample.txt", workspacePath: testDir, task: task),
            "sample.txt missing from workspace or task output folder. Files: \(fileListing)"
        )
        let resultsPath = try #require(
            findOutputFile(named: "results.txt", workspacePath: testDir, task: task),
            "results.txt missing from workspace or task output folder. Files: \(fileListing)"
        )
        #expect(fm.fileExists(atPath: wordCounterPath), "word_counter.py missing from disk")
        #expect(fm.fileExists(atPath: samplePath), "sample.txt missing from disk")
        #expect(fm.fileExists(atPath: resultsPath), "results.txt missing from disk")

        let results = try String(contentsOfFile: resultsPath, encoding: .utf8)
        #expect(!results.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "results.txt should have content")

        // 10. Verify callback events match SwiftData events
        let parsedTypes = receivedEvents.map { "\($0)" }
        if runtimeCase.expectsSessionID {
            #expect(parsedTypes.contains { $0.hasPrefix("systemInit") }, "Callback should include systemInit")
        }
        if runtimeCase.expectsResultCallback {
            #expect(parsedTypes.contains { $0.hasPrefix("result") }, "Callback should include result")
        } else {
            #expect(!receivedEvents.isEmpty, "Callback should include provider output")
        }

        // Summary
        print("\n=== Phase 1 Worker E2E Results ===")
        print("Runtime: \(runtimeCase.runtimeID.displayName)")
        print("Workspace: \(workspace.name) → \(workspace.primaryPath)")
        print("Status: \(task.status.rawValue)")
        print("Tokens: \(task.tokensUsed) / \(task.tokenBudget)")
        print("Cost: $\(String(format: "%.4f", task.costUSD))")
        print("Session: \(task.sessionId ?? "nil")")
        print("Events: \(allEvents.count) (\(eventTypes.sorted().joined(separator: ", ")))")
        print("Artifacts: \(artifactPaths.joined(separator: ", "))")
        print("results.txt: \(results.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        print("=================================\n")
    }
}

private actor Phase1BrowserBridgeTestEndpoint {
    private var value: String?

    func set(_ nextValue: String?) {
        value = nextValue
    }

    func waitForURL() async throws -> URL {
        for _ in 0..<100 {
            if let value, let url = URL(string: value) {
                return url
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Phase1BrowserBridgeTestError.endpointUnavailable
    }
}

private enum Phase1BrowserBridgeTestError: Error {
    case endpointUnavailable
}
