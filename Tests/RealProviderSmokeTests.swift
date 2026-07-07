import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private let realProviderSmokeEnabled = ProcessInfo.processInfo.environment["RUN_REAL_PROVIDERS"] != nil

@Suite("Real Provider Smoke Tests", .serialized)
@MainActor
struct RealProviderSmokeTests {
    // Constructs ExecutionEnvironmentCredentialProjection.gcpADC below, which
    // reads the ExecutionPathSafety seam — see RuntimeSeamRegistration.swift.
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll()

    private static var liveConfig: LiveProviderTestConfiguration {
        LiveProviderTestConfiguration()
    }

    @Test(
        "Real GitHub CLI is authenticated",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realGitHubCLIAuthStatus() throws {
        let result = try Self.run(["gh", "auth", "status"])

        print("gh auth status exit=\(result.exitCode)")
        print(Self.redacted(result.output))

        #expect(result.exitCode == 0)
        #expect(result.output.localizedCaseInsensitiveContains("Logged in"))

        let repo = ProcessInfo.processInfo.environment["REAL_GITHUB_REPO"] ?? "susom/astra"
        let repoResult = try Self.run([
            "gh", "repo", "view", repo,
            "--json", "nameWithOwner,isPrivate,defaultBranchRef",
            "--jq", #"{nameWithOwner,isPrivate,defaultBranch:.defaultBranchRef.name}"#
        ])

        print("gh repo view \(repo) exit=\(repoResult.exitCode)")
        print(Self.redacted(repoResult.output))

        #expect(repoResult.exitCode == 0)
        #expect(repoResult.output.contains(repo))
    }

    @Test(
        "Real Claude CLI reports its model list via the initialize handshake",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeCLIModelDiscovery() async throws {
        let claudePath = try #require(Self.findExecutable("claude"))

        // Empty environment removes the ANTHROPIC_API_KEY fallback, so a
        // result here can only have come from the CLI's own login — the
        // exact scenario that used to dead-end on hardcoded defaults.
        let service = ClaudeModelAvailabilityService(environment: { [:] })
        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(
                provider: .anthropic,
                executablePath: claudePath
            )
        )

        guard case .available(let models) = result else {
            Issue.record("Expected CLI-reported models, got \(result)")
            return
        }
        print("claude CLI models: \(models.map { "\($0.value) → \($0.displayName ?? "(no display name)")" })")
        #expect(!models.isEmpty)
    }

    @Test(
        "Real backend switches from Claude to Copilot mid-thread",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realBackendSwitchesClaudeToCopilotMidThread() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let copilotPath = try #require(Self.findExecutable("copilot"))
        let claudeModel = Self.liveConfig.claudeModel
        let copilotModel = Self.liveConfig.copilotModel

        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)
        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Reply with exactly this text and nothing else: ASTRA_REAL_CLAUDE_OK",
            model: claudeModel
        )

        _ = try await harness.execute(task: task, worker: worker)
        let firstRun = try #require(task.runs.first)
        Self.printRunSummary(label: "real claude initial", task: task, run: firstRun)

        #expect(firstRun.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(firstRun.status == .completed)
        #expect(!firstRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.model = copilotModel
        _ = try await harness.continueTask(
            task: task,
            message: "Now reply with exactly this text and nothing else: ASTRA_REAL_COPILOT_OK",
            worker: worker
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let secondRun = try #require(runs.last)
        Self.printRunSummary(label: "real copilot follow-up", task: task, run: secondRun)

        #expect(runs.count == 2)
        #expect(secondRun.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(secondRun.status == .completed)
        #expect(!secondRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let firstSession = firstRun.providerSessionId, let secondSession = secondRun.providerSessionId {
            #expect(firstSession != secondSession)
        }
    }

    @Test(
        "Real backend switches from Copilot to Claude mid-thread",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realBackendSwitchesCopilotToClaudeMidThread() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let copilotPath = try #require(Self.findExecutable("copilot"))
        let claudeModel = Self.liveConfig.claudeModel
        let copilotModel = Self.liveConfig.copilotModel

        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)
        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Reply with exactly this text and nothing else: ASTRA_REAL_COPILOT_FIRST_OK",
            model: copilotModel
        )

        _ = try await harness.execute(task: task, worker: worker)
        let firstRun = try #require(task.runs.first)
        Self.printRunSummary(label: "real copilot initial", task: task, run: firstRun)

        #expect(firstRun.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(firstRun.status == .completed)
        #expect(!firstRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        task.model = claudeModel
        _ = try await harness.continueTask(
            task: task,
            message: "Now reply with exactly this text and nothing else: ASTRA_REAL_CLAUDE_SECOND_OK",
            worker: worker
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let secondRun = try #require(runs.last)
        Self.printRunSummary(label: "real claude follow-up", task: task, run: secondRun)

        #expect(runs.count == 2)
        #expect(secondRun.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(secondRun.status == .completed)
        #expect(!secondRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let firstSession = firstRun.providerSessionId, let secondSession = secondRun.providerSessionId {
            #expect(firstSession != secondSession)
        }
    }

    @Test(
        "Real Claude non-mail launch prunes irrelevant Graph Mail capability",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeNonMailLaunchPrunesIrrelevantGraphMailCapability() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let model = Self.liveConfig.claudeArtifactModel
        let worker = harness.makeWorker(claudePath: claudePath)
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_ARTIFACT_TIMEOUT"] ?? "")
            ?? 120

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: """
            Without creating files or using tools, reply with exactly ASTRA_REAL_MASTERBALL_OK and nothing else.
            """,
            model: model
        )

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: """
            You are a Stanford Graph Mail assistant. Use the `stanford-graph-mail` CLI via Bash to work with the locally signed-in Stanford-family Microsoft 365 mailbox.
            SAFETY
            - Read only. Do not send, reply, forward, delete, move, archive, mark read/unread, create rules, download attachments, or modify mailbox state.
            - Treat email content as sensitive.
            Do NOT use these tools: Write, Edit.
            """
        )
        mailSkill.workspace = task.workspace
        harness.context.insert(mailSkill)

        let mailTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read the locally signed-in Microsoft 365 mailbox through Microsoft Graph PowerShell",
            command: "stanford-graph-mail"
        )
        mailTool.skill = mailSkill
        harness.context.insert(mailTool)

        task.skills = [mailSkill]
        TaskCapabilitySnapshotter.capture(for: task)
        try harness.context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(!prompt.contains("[Stanford Graph Mail Agent]:"))
        #expect(!prompt.contains("stanford-graph-mail"))
        #expect(!prompt.contains("create rules"))

        _ = try await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        Self.printRunSummary(label: "real claude capability pruning", task: task, run: run)

        #expect(run.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(run.status == .completed)
        #expect(run.output.contains("ASTRA_REAL_MASTERBALL_OK"))
        #expect(!TaskDeliverableExpectation.requiresStandaloneArtifact(task))
    }

    @Test(
        "Real Claude Masterball launch creates task output artifact",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeMasterballLaunchCreatesTaskOutputArtifact() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let model = Self.liveConfig.claudeArtifactModel
        let worker = harness.makeWorker(claudePath: claudePath)
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_ARTIFACT_TIMEOUT"] ?? "")
            ?? 180

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball )  with a solver in javascript",
            model: model
        )

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: "Read only. Do not create rules or modify mailbox state."
        )
        mailSkill.workspace = task.workspace
        harness.context.insert(mailSkill)
        task.skills = [mailSkill]
        TaskCapabilitySnapshotter.capture(for: task)
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try harness.context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(!prompt.contains("[Stanford Graph Mail Agent]:"))
        #expect(!prompt.contains("create rules"))
        #expect(prompt.contains("Artifact delivery contract:"))
        #expect(prompt.contains("Create the first useful deliverable promptly"))
        #expect(prompt.contains("preferably as index.html"))

        _ = try await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        Self.printRunSummary(label: "real claude masterball artifact", task: task, run: run)

        #expect(run.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(run.fileChanges.contains { $0.path.hasSuffix("index.html") })
        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run))
    }

    @Test(
        "Real Copilot Masterball launch creates task output artifact",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realCopilotMasterballLaunchCreatesTaskOutputArtifact() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let copilotPath = try #require(Self.findExecutable("copilot"))
        let model = Self.liveConfig.copilotArtifactModel
        let worker = harness.makeWorker(copilotPath: copilotPath)
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_ARTIFACT_TIMEOUT"] ?? "")
            ?? 240

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball ) with a solver in javascript",
            model: model
        )
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try harness.context.save()

        _ = try await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        Self.printRunSummary(label: "real copilot masterball artifact", task: task, run: run)

        #expect(run.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run))
    }

    @Test(
        "Real providers run Docker workspace command with projected GCP ADC",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realProvidersRunDockerWorkspaceCommandWithProjectedGCPADC() async throws {
        let configuredImage = ProcessInfo.processInfo.environment["REAL_PROVIDER_DOCKER_IMAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let image = configuredImage.isEmpty ? "astra-starr-data-lake:latest" : configuredImage
        let imageID = try Self.requireDockerImage(image)
        let gcloudHostPath = try Self.requireHostADC()
        let runtimes = try Self.dockerProviderRuntimes()

        for runtime in runtimes {
            let executable = try #require(Self.findExecutable(runtime.executableName))
            let harness = try RealProviderHarness()
            defer { harness.cleanup() }

            let secret = "ASTRA_DOCKER_ADC_OK_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            try Self.writeDockerCredentialWorkspaceFixtures(
                workspaceURL: harness.workspaceURL,
                secret: secret
            )
            let worker = harness.makeWorker(for: runtime.id, executablePath: executable)
            worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_DOCKER_TIMEOUT"] ?? "")
                ?? 180
            let model = runtime.model
            let task = harness.makeTask(
                runtime: runtime.id,
                goal: """
                Use only the ASTRA workspace shell MCP tool to run exactly this command from the workspace root:
                test -r /root/.config/gcloud/application_default_credentials.json && cat /workspace/.astra-docker-secret.txt

                Reply with exactly the command output and nothing else.
                Do not use native Bash, native shell, or Codex command_execution.
                Tool names: Claude/Codex `mcp__astra_workspace__workspace_shell`; Copilot `astra_workspace-workspace_shell`.
                """,
                model: model,
                workspaceConfiguration: { workspace in
                    workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(
                        WorkspaceExecutionEnvironment(
                            id: "image:\(image)",
                            kind: .dockerImage,
                            displayName: "Real Docker Image",
                            sourcePath: harness.workspaceURL.path,
                            image: image,
                            imageDigest: imageID,
                            credentialProjections: [
                                ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcloudHostPath)
                            ]
                        )
                    )
                }
            )

            _ = try await harness.execute(task: task, worker: worker)
            let run = try #require(task.runs.first)
            Self.printRunSummary(label: "real \(runtime.id.rawValue) docker credential projection", task: task, run: run)

            #expect(run.runtimeID == runtime.id.rawValue)
            #expect(run.typedStopReason != .credentialProjectionRequired)
            #expect(run.status == .completed)
            #expect(run.output.contains(secret))
            let launchSignature = task.events.first { $0.type == "astra.provider_launch_signature" }?.payload ?? ""
            let signature = try Self.providerLaunchSignaturePayload(launchSignature)
            let mcpServerIDs = try #require(signature["mcpServerIDs"] as? [String])
            let runtimeSupportTools = try #require(signature["runtimeSupportTools"] as? [String])
            let environmentKeyNames = try #require(signature["environmentKeyNames"] as? [String])
            let credentialLabels = try #require(signature["credentialLabels"] as? [String])
            #expect(mcpServerIDs.contains("astra-builtin:astra_workspace"))
            #expect(runtimeSupportTools.contains { $0.contains(DockerWorkspaceMCPProjection.providerToolPermission) })
            #expect(environmentKeyNames.contains("CLOUDSDK_CONFIG"))
            #expect(environmentKeyNames.contains("GOOGLE_APPLICATION_CREDENTIALS"))
            #expect(credentialLabels.contains("docker:GCP Application Default Credentials:ro:/root/.config/gcloud"))
        }
    }

    // MARK: - Multi-turn conversation continuity (real provider output)

    @Test(
        "Real Claude follow-up uses context from the first turn",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeUsesContextAcrossTurns() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let model = Self.claudeModel()
        let worker = harness.makeWorker(claudePath: claudePath)

        try await Self.assertConversationRecall(
            harness: harness,
            worker: worker,
            firstRuntime: .claudeCode,
            firstModel: model,
            secondRuntime: .claudeCode,
            secondModel: model,
            label: "claude continuity"
        )
    }

    @Test(
        "Real Copilot follow-up uses context from the first turn",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realCopilotUsesContextAcrossTurns() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let copilotPath = try #require(Self.findExecutable("copilot"))
        let model = Self.copilotModel()
        let worker = harness.makeWorker(copilotPath: copilotPath)

        try await Self.assertConversationRecall(
            harness: harness,
            worker: worker,
            firstRuntime: .copilotCLI,
            firstModel: model,
            secondRuntime: .copilotCLI,
            secondModel: model,
            label: "copilot continuity"
        )
    }

    @Test(
        "Real Antigravity follow-up uses context from the first turn",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realAntigravityUsesContextAcrossTurns() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let antigravityPath = try #require(Self.findExecutable("agy"))
        let model = Self.antigravityModel()
        let worker = harness.makeWorker(antigravityPath: antigravityPath)

        try await Self.assertConversationRecallOrProviderUnavailable(
            harness: harness,
            worker: worker,
            firstRuntime: .antigravityCLI,
            firstModel: model,
            secondRuntime: .antigravityCLI,
            secondModel: model,
            label: "antigravity continuity",
            unavailableCheck: Self.isKnownAntigravityUnavailable
        )
    }

    @Test(
        "Real Claude→Copilot switch carries context across turns",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeToCopilotCarriesContextAcrossTurns() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let copilotPath = try #require(Self.findExecutable("copilot"))
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        try await Self.assertConversationRecall(
            harness: harness,
            worker: worker,
            firstRuntime: .claudeCode,
            firstModel: Self.claudeModel(),
            secondRuntime: .copilotCLI,
            secondModel: Self.copilotModel(),
            label: "claude→copilot continuity"
        )
    }

    @Test(
        "Real Copilot→Claude switch carries context across turns",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realCopilotToClaudeCarriesContextAcrossTurns() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let copilotPath = try #require(Self.findExecutable("copilot"))
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        try await Self.assertConversationRecall(
            harness: harness,
            worker: worker,
            firstRuntime: .copilotCLI,
            firstModel: Self.copilotModel(),
            secondRuntime: .claudeCode,
            secondModel: Self.claudeModel(),
            label: "copilot→claude continuity"
        )
    }

    /// Establishes a private fact on turn 1, then on turn 2 asks a question whose
    /// answer can only be produced by recalling that fact. Because the expected
    /// answer never appears in either prompt, a passing assertion proves the
    /// provider actually consumed the replayed conversation context rather than
    /// ASTRA merely including it.
    private static func assertConversationRecall(
        harness: RealProviderHarness,
        worker: AgentRuntimeWorker,
        firstRuntime: AgentRuntimeID,
        firstModel: String,
        secondRuntime: AgentRuntimeID,
        secondModel: String,
        label: String
    ) async throws {
        let probe = ContinuityProbe()

        let task = harness.makeTask(runtime: firstRuntime, goal: probe.firstGoal, model: firstModel)
        _ = try await harness.execute(task: task, worker: worker)
        let firstRun = try #require(task.runs.first)
        printRunSummary(label: "\(label) — turn 1 (\(firstRuntime.rawValue))", task: task, run: firstRun)

        #expect(firstRun.runtimeID == firstRuntime.rawValue)
        #expect(firstRun.status == .completed)

        task.runtimeID = secondRuntime.rawValue
        task.model = secondModel
        _ = try await harness.continueTask(task: task, message: probe.followUpMessage, worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let secondRun = try #require(runs.last)
        printRunSummary(label: "\(label) — turn 2 (\(secondRuntime.rawValue))", task: task, run: secondRun)

        #expect(runs.count == 2)
        #expect(secondRun.runtimeID == secondRuntime.rawValue)
        #expect(secondRun.status == .completed)

        let answer = secondRun.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            answer.contains(String(probe.expectedAnswer)),
            """
            Follow-up turn did not demonstrate conversation continuity for \(label).
            Expected the answer to contain \(probe.expectedAnswer) (= \(probe.favoriteNumber) × \(probe.multiplier)), \
            which is only derivable by recalling the favorite number established in turn 1.
            Got: \(redacted(String(answer.prefix(200))))
            """
        )
    }

    private static func assertConversationRecallOrProviderUnavailable(
        harness: RealProviderHarness,
        worker: AgentRuntimeWorker,
        firstRuntime: AgentRuntimeID,
        firstModel: String,
        secondRuntime: AgentRuntimeID,
        secondModel: String,
        label: String,
        unavailableCheck: (AgentTask, TaskRun) -> Bool
    ) async throws {
        let probe = ContinuityProbe()

        let task = harness.makeTask(runtime: firstRuntime, goal: probe.firstGoal, model: firstModel)
        _ = try await harness.execute(task: task, worker: worker)
        let firstRun = try #require(task.runs.first)
        printRunSummary(label: "\(label) — turn 1 (\(firstRuntime.rawValue))", task: task, run: firstRun)
        if unavailableCheck(task, firstRun) {
            return
        }

        #expect(firstRun.runtimeID == firstRuntime.rawValue)
        #expect(firstRun.status == .completed)
        #expect(!firstRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        task.runtimeID = secondRuntime.rawValue
        task.model = secondModel
        _ = try await harness.continueTask(task: task, message: probe.followUpMessage, worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let secondRun = try #require(runs.last)
        printRunSummary(label: "\(label) — turn 2 (\(secondRuntime.rawValue))", task: task, run: secondRun)
        if unavailableCheck(task, secondRun) {
            return
        }

        #expect(runs.count == 2)
        #expect(secondRun.runtimeID == secondRuntime.rawValue)
        #expect(secondRun.status == .completed)

        let answer = secondRun.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            answer.contains(String(probe.expectedAnswer)),
            """
            Follow-up turn did not demonstrate conversation continuity for \(label).
            Expected the answer to contain \(probe.expectedAnswer) (= \(probe.favoriteNumber) × \(probe.multiplier)), \
            which is only derivable by recalling the favorite number established in turn 1.
            Got: \(redacted(String(answer.prefix(200))))
            """
        )
    }

    private static func isKnownAntigravityUnavailable(task: AgentTask, run: TaskRun) -> Bool {
        guard run.runtimeID == AgentRuntimeID.antigravityCLI.rawValue,
              run.status == .failed,
              run.stopReason == "no_usable_result" else {
            return false
        }
        let payload = task.events
            .filter { $0.run?.id == run.id && $0.type == "error" }
            .map(\.payload)
            .joined(separator: "\n")
            .lowercased()
        return payload.contains("antigravity quota is exhausted")
            || payload.contains("account_ineligible")
            || payload.contains("not eligible for antigravity")
            || payload.contains("authentication")
            || payload.contains("malformed_mcp_config")
    }

    private static func claudeModel() -> String {
        liveConfig.claudeModel
    }

    private static func copilotModel() -> String {
        liveConfig.copilotModel
    }

    private static func antigravityModel() -> String {
        liveConfig.antigravityModel
    }

    private struct DockerProviderRuntime {
        var id: AgentRuntimeID
        var executableName: String
        var model: String
    }

    private enum RealProviderSmokeFailure: Error, CustomStringConvertible {
        case noDockerProviderRuntimes
        case unknownRuntime(String)
        case commandFailed(String)
        case missingADC(String)

        var description: String {
            switch self {
            case .noDockerProviderRuntimes:
                "No installed Docker-capable real provider runtimes were found."
            case .unknownRuntime(let raw):
                "Unknown REAL_PROVIDER_DOCKER_RUNTIMES entry: \(raw)."
            case .commandFailed(let message):
                message
            case .missingADC(let path):
                "Missing host Application Default Credentials at \(path). Run `gcloud auth application-default login` before this real-provider Docker smoke."
            }
        }
    }

    private static func dockerProviderRuntimes() throws -> [DockerProviderRuntime] {
        let all = [
            DockerProviderRuntime(id: .claudeCode, executableName: "claude", model: liveConfig.claudeModel),
            DockerProviderRuntime(id: .copilotCLI, executableName: "copilot", model: liveConfig.copilotModel),
            DockerProviderRuntime(
                id: .codexCLI,
                executableName: "codex",
                model: AgentRuntimeAdapterRegistry.defaultModel(for: .codexCLI)
            )
        ]

        if let configured = ProcessInfo.processInfo.environment["REAL_PROVIDER_DOCKER_RUNTIMES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return try configured
                .split(separator: ",")
                .map { raw in
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let runtime = all.first(where: { $0.id.rawValue == value || $0.executableName == value }) else {
                        throw RealProviderSmokeFailure.unknownRuntime(value)
                    }
                    return runtime
                }
        }

        let installed = all.filter { findExecutable($0.executableName) != nil }
        guard !installed.isEmpty else {
            throw RealProviderSmokeFailure.noDockerProviderRuntimes
        }
        return installed
    }

    private static func requireDockerImage(_ image: String) throws -> String {
        let result = try run(["docker", "image", "inspect", image, "--format", "{{.Id}}"])
        guard result.exitCode == 0 else {
            throw RealProviderSmokeFailure.commandFailed(
                "Docker image \(image) is not available for the real-provider Docker smoke. Evidence: \(redacted(result.output))"
            )
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func requireHostADC() throws -> String {
        let gcloudHostPath = ExecutionEnvironmentCredentialProjection.defaultGCPADCHostPath(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        let adcFile = (gcloudHostPath as NSString)
            .appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
        guard FileManager.default.fileExists(atPath: adcFile) else {
            throw RealProviderSmokeFailure.missingADC(adcFile)
        }
        return gcloudHostPath
    }

    private static func providerLaunchSignaturePayload(_ payload: String) throws -> [String: Any] {
        let data = try #require(payload.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func writeDockerCredentialWorkspaceFixtures(
        workspaceURL: URL,
        secret: String
    ) throws {
        let dbtDirectory = workspaceURL.appendingPathComponent("dbt", isDirectory: true)
        try FileManager.default.createDirectory(at: dbtDirectory, withIntermediateDirectories: true)
        try """
        default:
          target: dev
          outputs:
            dev:
              type: bigquery
              method: oauth
              project: astra-real-provider-smoke
              dataset: astra_smoke
        """.write(
            to: dbtDirectory.appendingPathComponent("profiles.yml"),
            atomically: true,
            encoding: .utf8
        )
        try "\(secret)\n".write(
            to: workspaceURL.appendingPathComponent(".astra-docker-secret.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Randomized fact/question pair for a two-turn recall probe. The expected
    /// answer (the product) intentionally never appears in either prompt, so it
    /// cannot be echoed — it must be recalled and computed by the model.
    private struct ContinuityProbe {
        let favoriteNumber: Int
        let multiplier: Int

        init() {
            favoriteNumber = Int.random(in: 3...9)
            multiplier = Int.random(in: 4...9)
        }

        var expectedAnswer: Int { favoriteNumber * multiplier }

        var firstGoal: String {
            """
            Remember this for the rest of our conversation: my favorite number is \(favoriteNumber). \
            Acknowledge by replying with only the single word REMEMBERED and nothing else.
            """
        }

        var followUpMessage: String {
            """
            Using only the favorite number I told you earlier in this conversation, multiply it by \(multiplier). \
            Reply with only the resulting integer and nothing else.
            """
        }
    }

    private static func findExecutable(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path
            .split(separator: ":")
            .map { "\($0)/\(name)" }
            + [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "\(NSHomeDirectory())/.local/bin/\(name)",
                "\(NSHomeDirectory())/.npm-global/bin/\(name)"
            ]

        var seen: Set<String> = []
        return candidates.first { candidate in
            guard !seen.contains(candidate) else { return false }
            seen.insert(candidate)
            return FileManager.default.isExecutableFile(atPath: candidate)
        }
    }

    private static func run(_ arguments: [String]) throws -> (exitCode: Int, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(process.terminationStatus), output + error)
    }

    fileprivate struct ProviderProgressProbeResult {
        var foundVisibleOrActionableEvent: Bool
        var foundProviderLivenessEvent: Bool
        var stdoutLines: Int
        var stderr: String
        var stdoutSamples: [String] = []
    }

    private static func runUntilProviderProgressSignal(
        plan: AgentRuntimeProcessLaunchPlan,
        timeoutSeconds: TimeInterval
    ) throws -> ProviderProgressProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.currentDirectory, isDirectory: true)
        process.environment = plan.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let capture = ProviderProgressProbeCapture()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            capture.appendStdout(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            capture.appendStderr(chunk)
        }

        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if capture.foundVisibleOrActionableEvent || capture.foundProviderLivenessEvent { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.interrupt()
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        return capture.result()
    }

    private static func printRunSummary(label: String, task: AgentTask, run: TaskRun) {
        let output = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let events = task.events
            .filter { $0.run?.id == run.id }
            .map { "\($0.type): \(redacted(String($0.payload.prefix(300))))" }
        print("""

        === \(label) ===
        task_status=\(task.status.rawValue)
        run_status=\(run.status.rawValue)
        stop_reason=\(run.stopReason)
        runtime=\(run.runtimeID ?? "nil")
        provider_version=\(run.providerVersion ?? "nil")
        exit_code=\(run.exitCode.map(String.init) ?? "nil")
        session=\(run.providerSessionId.map { String($0.prefix(8)) } ?? "nil")
        file_changes=\(run.fileChanges.map(\.path).joined(separator: ","))
        artifacts=\(task.artifacts.map(\.path).joined(separator: ","))
        output=\(redacted(String(output.prefix(500))))
        events=\(events.joined(separator: " | "))
        ====================
        """)
    }

    private static func redacted(_ value: String) -> String {
        LiveProviderDiagnostics.redacted(value)
    }
}

private final class ProviderProgressProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maxSampleCount = 8
    private let maxSampleLength = 500
    private var stdoutText = ""
    private var stderrText = ""
    private var stdoutSamples: [String] = []
    private var visibleOrActionableEventFound = false
    private var providerLivenessEventFound = false

    var foundVisibleOrActionableEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visibleOrActionableEventFound
    }

    var foundProviderLivenessEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return providerLivenessEventFound
    }

    func appendStdout(_ chunk: String) {
        lock.lock()
        stdoutText += chunk
        for line in chunk.split(separator: "\n") where stdoutSamples.count < maxSampleCount {
            stdoutSamples.append(String(line.prefix(maxSampleLength)))
        }
        for line in stdoutText.split(separator: "\n") {
            let progress = Self.providerProgress(in: line)
            if progress.visibleOrActionable {
                visibleOrActionableEventFound = true
            }
            if progress.liveness {
                providerLivenessEventFound = true
            }
        }
        lock.unlock()
    }

    func appendStderr(_ chunk: String) {
        lock.lock()
        stderrText += chunk
        lock.unlock()
    }

    func result() -> RealProviderSmokeTests.ProviderProgressProbeResult {
        lock.lock()
        defer { lock.unlock() }
        return RealProviderSmokeTests.ProviderProgressProbeResult(
            foundVisibleOrActionableEvent: visibleOrActionableEventFound,
            foundProviderLivenessEvent: providerLivenessEventFound,
            stdoutLines: stdoutText.split(separator: "\n").count,
            stderr: stderrText,
            stdoutSamples: stdoutSamples
        )
    }

    private static func providerProgress(in line: Substring) -> (visibleOrActionable: Bool, liveness: Bool) {
        var visibleOrActionable = false
        var liveness = false
        for event in StreamEventParser.parseAll(line: String(line)) {
            switch AgentRuntimeWorker.ProcessMonitor.progressKind(for: event) {
            case .visibleProgress, .actionableProgress, .terminal:
                visibleOrActionable = true
            case .providerLiveness, .accounting:
                liveness = true
            case .lifecycleMetadata, .diagnostic:
                break
            }
        }
        return (visibleOrActionable, liveness)
    }
}

@MainActor
private final class RealProviderHarness {
    let rootURL: URL
    let workspaceURL: URL
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-real-provider-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeTask(
        runtime: AgentRuntimeID,
        goal: String,
        model: String,
        workspaceConfiguration: ((Workspace) throws -> Void)? = nil
    ) rethrows -> AgentTask {
        let workspace = Workspace(name: "Real Provider Smoke", primaryPath: workspaceURL.path)
        try workspaceConfiguration?(workspace)
        context.insert(workspace)

        let task = AgentTask(
            title: "Real provider smoke",
            goal: goal,
            workspace: workspace,
            tokenBudget: 200_000,
            model: model
        )
        task.runtimeID = runtime.rawValue
        task.status = .queued
        context.insert(task)
        try? context.save()
        return task
    }

    func makeWorker(
        claudePath: String? = nil,
        copilotPath: String? = nil,
        codexPath: String? = nil,
        antigravityPath: String? = nil
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        if let claudePath {
            worker.claudePath = claudePath
        }
        if let copilotPath {
            worker.copilotPath = copilotPath
            worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        }
        if let codexPath {
            worker.setExecutablePath(codexPath, for: .codexCLI)
        }
        if let antigravityPath {
            worker.setExecutablePath(antigravityPath, for: .antigravityCLI)
        }
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_TIMEOUT"] ?? "")
            ?? 120
        worker.permissionPolicy = .restricted
        return worker
    }

    func makeWorker(for runtime: AgentRuntimeID, executablePath: String) -> AgentRuntimeWorker {
        switch runtime {
        case .claudeCode:
            makeWorker(claudePath: executablePath)
        case .copilotCLI:
            makeWorker(copilotPath: executablePath)
        case .codexCLI:
            makeWorker(codexPath: executablePath)
        case .antigravityCLI:
            makeWorker(antigravityPath: executablePath)
        default:
            {
                let worker = makeWorker()
                worker.setExecutablePath(executablePath, for: runtime)
                return worker
            }()
        }
    }

    func execute(task: AgentTask, worker: AgentRuntimeWorker) async throws -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: context)
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                events.append(event)
            }
        }
        try? context.save()
        return events
    }

    func continueTask(task: AgentTask, message: String, worker: AgentRuntimeWorker) async throws -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.continueSession(task: task, message: message, modelContext: context) { event in
                events.append(event)
            }
        }
        try? context.save()
        return events
    }
}
