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
        let copilotModel = ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? "gpt-5"

        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)
        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Reply with exactly this text and nothing else: ASTRA_REAL_CLAUDE_OK",
            model: claudeModel
        )

        _ = await harness.execute(task: task, worker: worker)
        let firstRun = try #require(task.runs.first)
        Self.printRunSummary(label: "real claude initial", task: task, run: firstRun)

        #expect(firstRun.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(firstRun.status == .completed)
        #expect(!firstRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.model = copilotModel
        _ = await harness.continueTask(
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
        let copilotModel = ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? "gpt-5"

        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)
        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Reply with exactly this text and nothing else: ASTRA_REAL_COPILOT_FIRST_OK",
            model: copilotModel
        )

        _ = await harness.execute(task: task, worker: worker)
        let firstRun = try #require(task.runs.first)
        Self.printRunSummary(label: "real copilot initial", task: task, run: firstRun)

        #expect(firstRun.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(firstRun.status == .completed)
        #expect(!firstRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        task.model = claudeModel
        _ = await harness.continueTask(
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

    func makeWorker(claudePath: String, copilotPath: String) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        worker.claudePath = claudePath
        worker.copilotPath = copilotPath
        worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = TimeInterval(ProcessInfo.processInfo.environment["REAL_PROVIDER_TIMEOUT"] ?? "")
            ?? 120
        worker.permissionPolicy = .restricted
        return worker
    }

    func execute(task: AgentTask, worker: AgentRuntimeWorker) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.execute(task: task, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func continueTask(task: AgentTask, message: String, worker: AgentRuntimeWorker) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.continueSession(task: task, message: message, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }
}
