import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private let realProviderSmokeEnabled = ProcessInfo.processInfo.environment["RUN_REAL_PROVIDERS"] != nil

@Suite("Real Provider Smoke Tests")
@MainActor
struct RealProviderSmokeTests {
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
        "Real backend switches from Claude to Copilot mid-thread",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realBackendSwitchesClaudeToCopilotMidThread() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let copilotPath = try #require(Self.findExecutable("copilot"))
        let claudeModel = ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"] ?? "claude-sonnet-4-6"
        let copilotModel = ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)

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
        let claudeModel = ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"] ?? "claude-sonnet-4-6"
        let copilotModel = ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)

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
        "Real Claude artifact launch prunes irrelevant Graph Mail capability",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeArtifactLaunchPrunesIrrelevantGraphMailCapability() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let model = ProcessInfo.processInfo.environment["REAL_CLAUDE_ARTIFACT_MODEL"]
            ?? ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"]
            ?? "claude-opus-4-6@default"
        let worker = harness.makeWorker(claudePath: claudePath)
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_ARTIFACT_TIMEOUT"] ?? "")
            ?? 120

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: """
            Without creating files or using tools, answer this artifact-shaped task: createa web page wit a masterball \
            (similar to rubicks cube but as aball) with a solver in javascript. \
            Reply with exactly ASTRA_REAL_MASTERBALL_OK and nothing else.
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
        Self.printRunSummary(label: "real claude artifact pruning", task: task, run: run)

        #expect(run.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(run.status == .completed)
        #expect(run.output.contains("ASTRA_REAL_MASTERBALL_OK"))
    }

    @Test(
        "Real Claude Masterball launch creates task output artifact",
        .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
    )
    func realClaudeMasterballLaunchCreatesTaskOutputArtifact() async throws {
        let harness = try RealProviderHarness()
        defer { harness.cleanup() }

        let claudePath = try #require(Self.findExecutable("claude"))
        let model = ProcessInfo.processInfo.environment["REAL_CLAUDE_ARTIFACT_MODEL"]
            ?? ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"]
            ?? "claude-opus-4-6@default"
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
        let model = ProcessInfo.processInfo.environment["REAL_COPILOT_ARTIFACT_MODEL"]
            ?? ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"]
            ?? "gpt-5.3-codex"
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

        try await Self.assertConversationRecall(
            harness: harness,
            worker: worker,
            firstRuntime: .antigravityCLI,
            firstModel: model,
            secondRuntime: .antigravityCLI,
            secondModel: model,
            label: "antigravity continuity"
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

    private static func claudeModel() -> String {
        ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"] ?? "claude-sonnet-4-6"
    }

    private static func copilotModel() -> String {
        ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"]
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
    }

    private static func antigravityModel() -> String {
        ProcessInfo.processInfo.environment["REAL_ANTIGRAVITY_MODEL"]
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .antigravityCLI)
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
        let errors = task.events
            .filter { $0.run?.id == run.id && $0.type == "error" }
            .map { redacted($0.payload) }
        print("""

        === \(label) ===
        task_status=\(task.status.rawValue)
        run_status=\(run.status.rawValue)
        runtime=\(run.runtimeID ?? "nil")
        provider_version=\(run.providerVersion ?? "nil")
        exit_code=\(run.exitCode.map(String.init) ?? "nil")
        session=\(run.providerSessionId.map { String($0.prefix(8)) } ?? "nil")
        output=\(redacted(String(output.prefix(500))))
        errors=\(errors.joined(separator: " | "))
        ====================
        """)
    }

    private static func redacted(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"gho_[A-Za-z0-9_]+"#,
                with: "gho_[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_-]+"#,
                with: "sk-[redacted]",
                options: .regularExpression
            )
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

    func makeTask(runtime: AgentRuntimeID, goal: String, model: String) -> AgentTask {
        let workspace = Workspace(name: "Real Provider Smoke", primaryPath: workspaceURL.path)
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
        if let antigravityPath {
            worker.setExecutablePath(antigravityPath, for: .antigravityCLI)
        }
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_TIMEOUT"] ?? "")
            ?? 120
        worker.permissionPolicy = .restricted
        return worker
    }

    func execute(task: AgentTask, worker: AgentRuntimeWorker) async throws -> [ParsedEvent] {
        var events: [ParsedEvent] = []
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
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.continueSession(task: task, message: message, modelContext: context) { event in
                events.append(event)
            }
        }
        try? context.save()
        return events
    }
}
