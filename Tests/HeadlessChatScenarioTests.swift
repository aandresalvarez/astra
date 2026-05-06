import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Headless Chat Scenarios")
@MainActor
struct HeadlessChatScenarioTests {
    @Test("Fake Copilot chat completes through the worker without UI")
    func fakeCopilotChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Headless Copilot response"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Answer from Copilot", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Headless Copilot response")
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 4)
        #expect(events.contains { if case .text("Headless Copilot response") = $0 { true } else { false } })
    }

    @Test("Fake Claude chat completes through the worker without UI")
    func fakeClaudeChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Headless Claude response"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Headless Claude response","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Answer from Claude", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(task.sessionId == "session-1")
        #expect(run.status == .completed)
        #expect(run.output == "Headless Claude response")
        #expect(run.inputTokens == 3)
        #expect(run.outputTokens == 5)
        #expect(events.contains { if case .systemInit(_, "session-1") = $0 { true } else { false } })
    }

    @Test("Headless chat enforces budget guardrails")
    func headlessChatEnforcesBudget() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let largeOutput = String(repeating: "x", count: 600)
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(largeOutput)"}}'
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Produce too much output",
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Permission warning can recover when later provider output arrives")
    func permissionWarningCanRecover() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Bash","message":"approval needed for Bash"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Recovered after the warning"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Recover after warning", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.output == "Recovered after the warning")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("Bash") })
        #expect(task.events.contains { $0.type == "agent.response" && $0.payload == "Recovered after the warning" })
    }

    @Test("Permission mode is passed to the provider command")
    func permissionModeIsPassedToProviderCommand() async throws {
        let reviewHarness = try HeadlessChatHarness()
        defer { reviewHarness.cleanup() }
        let reviewArgsURL = reviewHarness.rootURL.appendingPathComponent("review-args.txt")
        let reviewCopilotPath = try reviewHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"review mode"}}'
                exit 0
                """,
                argsFile: reviewArgsURL
            )
        )
        let reviewTask = reviewHarness.makeTask(runtime: .copilotCLI, goal: "Run in review mode", model: "gpt-5")
        let reviewWorker = reviewHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: reviewCopilotPath,
            permissionPolicy: .restricted
        )

        _ = await reviewHarness.execute(task: reviewTask, worker: reviewWorker)

        let reviewArgs = try String(contentsOf: reviewArgsURL, encoding: .utf8)
        #expect(reviewArgs.contains("--allow-tool"))
        #expect(!reviewArgs.contains("--allow-all-tools"))

        let autoHarness = try HeadlessChatHarness()
        defer { autoHarness.cleanup() }
        let autoArgsURL = autoHarness.rootURL.appendingPathComponent("auto-args.txt")
        let autoCopilotPath = try autoHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"auto mode"}}'
                exit 0
                """,
                argsFile: autoArgsURL
            )
        )
        let autoTask = autoHarness.makeTask(runtime: .copilotCLI, goal: "Run in auto mode", model: "gpt-5")
        let autoWorker = autoHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: autoCopilotPath,
            permissionPolicy: .autonomous
        )

        _ = await autoHarness.execute(task: autoTask, worker: autoWorker)

        let autoArgs = try String(contentsOf: autoArgsURL, encoding: .utf8)
        #expect(autoArgs.contains("--allow-all-tools"))
    }

    @Test("Headless chat can continue a task")
    func headlessChatCanContinueTask() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("call-count.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Initial answer"}}'
            else
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Follow-up answer"}}'
            fi
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":5,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start a thread", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        _ = await harness.continueTask(task: task, message: "Follow up", worker: worker)

        #expect(task.runs.count == 2)
        #expect(task.runs.contains { $0.output == "Initial answer" })
        #expect(task.runs.contains { $0.output == "Follow-up answer" })
        #expect(task.events.contains { $0.type == "user.message" && $0.payload == "Follow up" })
        #expect(task.status == .completed)
    }

    private static func copilotScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuote($0.path))" } ?? ""
        return """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        \(recordArgs)
        \(body)
        """
    }

    private static func claudeScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuote($0.path))" } ?? ""
        return """
        #!/bin/sh
        \(recordArgs)
        \(body)
        """
    }

    private static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
private final class HeadlessChatHarness {
    let rootURL: URL
    let workspaceURL: URL
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-headless-chat-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        context = container.mainContext
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeExecutable(named name: String, script: String) throws -> String {
        let url = rootURL.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func makeTask(
        runtime: AgentRuntimeID,
        goal: String,
        model: String,
        tokenBudget: Int = 1_000
    ) -> AgentTask {
        let workspace = Workspace(name: "Headless", primaryPath: workspaceURL.path)
        context.insert(workspace)

        let task = AgentTask(
            title: "Headless \(runtime.rawValue)",
            goal: goal,
            workspace: workspace,
            tokenBudget: tokenBudget,
            model: model
        )
        task.runtimeID = runtime.rawValue
        task.status = .queued
        context.insert(task)
        try? context.save()
        return task
    }

    func makeWorker(
        runtime: AgentRuntimeID,
        executablePath: String,
        permissionPolicy: PermissionPolicy = .restricted
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        switch runtime {
        case .claudeCode:
            worker.claudePath = executablePath
        case .copilotCLI:
            worker.copilotPath = executablePath
            worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        }
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
