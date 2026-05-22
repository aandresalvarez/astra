import Testing
import Foundation
@testable import ASTRA
import ASTRACore
import SwiftData

/// Phase 3 Functional Test — Parallel Debate Swarm (3+ Agents)
/// Tests: parallel execution, token budget limits, and synthesis into a final markdown output.
/// Three agents debate state management libraries and produce a comparison matrix.

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

private func hasProviderProgressEvent(_ eventTypes: Set<String>) -> Bool {
    let progressEventTypes: Set<String> = [
        "agent.thinking",
        "agent.response",
        "tool.use",
        "tool.result",
        "astra.complete"
    ]
    return !eventTypes.isDisjoint(with: progressEventTypes)
}

@Suite("Phase 3 Functional — Parallel Debate Swarm", .tags(.integration))
struct Phase3FunctionalTest {

    @Test(
        "3-agent debate with synthesis to markdown",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call live AI CLIs"),
        arguments: E2ETestSupport.runtimeCases
    )
    @MainActor
    func parallelDebateSwarm(runtimeCase: E2ETestSupport.RuntimeCase) async throws {
        // 1. Create workspace directory
        let testDir = "/tmp/phase3_\(runtimeCase.directoryNameComponent)_swarm_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }
        defer { try? FileManager.default.removeItem(atPath: E2ETestSupport.copilotHomePath(forTemporaryRootPath: testDir)) }

        // 2. Create SwiftData container and workspace
        let container = try makeTestContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Phase3 Test Workspace", primaryPath: testDir)
        context.insert(workspace)

        // 3. Create task with 3-agent team
        let task = AgentTask(
            title: "State management debate",
            goal: """
            I need to decide on a state management library for a new React project. \
            Compare Redux Toolkit, Zustand, and React Context API from general knowledge only; \
            do not use web search. \
            Compare them on bundle size, boilerplate, ease of use, TypeScript support, \
            and performance. Challenge each approach's assumptions. \
            Output a final markdown file named state-decision.md with a comparison matrix table \
            and a clear recommendation with reasoning. Use a file-write tool or shell redirection \
            to create state-decision.md on disk; keep it under 350 words. Do not only answer in chat. Once state-decision.md \
            exists, finish immediately.
            """,
            workspace: workspace,
            tokenBudget: 200000,
            model: runtimeCase.model
        )
        task.runtimeID = runtimeCase.runtimeID.rawValue
        task.useAgentTeam = runtimeCase.expectsTeamEvents
        task.teamSize = runtimeCase.expectsTeamEvents ? 3 : 1
        task.teamInstructions = """
        Create an agent team with 3 teammates:
        - Teammate 1 advocates for Redux Toolkit
        - Teammate 2 advocates for Zustand
        - Teammate 3 advocates for React Context API
        Have them debate from general knowledge only; do not use web search. Each teammate should \
        respond with no more than 3 concise bullets covering bundle size, boilerplate, ease of use, \
        TypeScript support, and performance. They must challenge one assumption from another option. \
        Once they reach a consensus, output a final markdown file named state-decision.md with a \
        comparison matrix and recommendation. Use at most one pass per teammate and finish immediately \
        after writing the file.
        """
        task.maxTurns = 8
        context.insert(task)
        try context.save()

        #expect(task.useAgentTeam == runtimeCase.expectsTeamEvents)
        #expect(task.teamSize == (runtimeCase.expectsTeamEvents ? 3 : 1))

        // 4. Run through AgentRuntimeWorker
        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        var receivedEvents: [ParsedEvent] = []

        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { event in
                receivedEvents.append(event)
            }
        }

        // 5. Verify task lifecycle
        let isTerminal = task.isTerminal || task.status == .pendingUser || task.status == .budgetExceeded
        #expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
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

        // 7. Verify core events
        let allEvents = task.events
        let eventTypes = Set(allEvents.map(\.type))

        #expect(eventTypes.contains("task.started"), "Missing task.started")
        #expect(hasProviderProgressEvent(eventTypes), "Missing provider progress/output event")
        if runtimeCase.expectsUsageStats {
            #expect(eventTypes.contains("task.stats"), "Missing task.stats")
        }

        // 8. Verify parallel team activity
        let teamStartEvents = allEvents.filter { $0.type == "team.agent.started" }
        let teamCompletedEvents = allEvents.filter { $0.type == "team.agent.completed" }
        let agentToolUses = allEvents.filter { $0.type == "tool.use" && $0.payload.contains("Agent") }
        let hasTeamActivity = !teamStartEvents.isEmpty || !agentToolUses.isEmpty

        if runtimeCase.expectsTeamEvents {
            #expect(hasTeamActivity,
                    "Should have team spawning activity (team.agent.started: \(teamStartEvents.count), Agent tools: \(agentToolUses.count))")

            // For a 3-agent team, expect multiple agent spawns
            let totalAgentSpawns = teamStartEvents.count + agentToolUses.count
            #expect(totalAgentSpawns >= 2,
                    "Should spawn at least 2 agents for a 3-teammate task, got \(totalAgentSpawns)")
        }

        // 9. Verify output file — state-decision.md
        let decisionPath = findOutputFile(named: "state-decision.md", workspacePath: testDir, task: task)
        let hasDecisionFile = decisionPath != nil

        if let decisionPath {
            let content = try String(contentsOfFile: decisionPath, encoding: .utf8)
            #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "state-decision.md should have content")

            // Check for comparison matrix indicators (markdown table)
            let hasTable = content.contains("|") && content.contains("---")
            let hasLibraries = (content.contains("Redux") || content.contains("redux"))
                && (content.contains("Zustand") || content.contains("zustand"))
                && (content.contains("Context") || content.contains("context"))

            #expect(hasTable || hasLibraries,
                    "state-decision.md should contain a comparison matrix or mention all three libraries")

            print("state-decision.md preview:\n\(content.prefix(500))")
        } else {
            // If budget was exceeded before file creation, that's acceptable
            if task.status == .budgetExceeded {
                print("NOTE: Budget exceeded before state-decision.md was created — this is an expected outcome for Phase 3")
            } else {
                #expect(hasDecisionFile, "state-decision.md should exist (status: \(task.status.rawValue))")
            }
        }

        // 10. Token budget stress test — verify budget tracking worked
        // Agent teams report tokens in large batches (per-agent result events), so overshoot
        // can be significant. We verify the budget mechanism fired, not exact cutoff.
        if task.status == .budgetExceeded {
            if runtimeCase.expectsUsageStats {
                #expect(task.tokensUsed > task.tokenBudget,
                        "Budget exceeded status should mean tokens (\(task.tokensUsed)) exceeded budget (\(task.tokenBudget))")
            }
        }

        // Summary
        print("\n=== Phase 3 Parallel Debate Swarm Results ===")
        print("Runtime: \(runtimeCase.runtimeID.displayName)")
        print("Workspace: \(workspace.name) -> \(workspace.primaryPath)")
        print("Status: \(task.status.rawValue)")
        print("Tokens: \(task.tokensUsed) / \(task.tokenBudget)")
        print("Cost: $\(String(format: "%.4f", task.costUSD))")
        print("Session: \(task.sessionId ?? "nil")")
        print("Events: \(allEvents.count) (\(eventTypes.sorted().joined(separator: ", ")))")
        print("Team spawns: \(teamStartEvents.count) started, \(teamCompletedEvents.count) completed")
        print("Agent tool uses: \(agentToolUses.count)")
        print("state-decision.md exists: \(hasDecisionFile)")
        print("=============================================\n")
    }

    @Test(
        "Budget exceeded kills swarm cleanly",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call live AI CLIs"),
        arguments: E2ETestSupport.runtimeCases
    )
    @MainActor
    func budgetExceededKillsSwarm(runtimeCase: E2ETestSupport.RuntimeCase) async throws {
        // 1. Create workspace
        let testDir = "/tmp/phase3_\(runtimeCase.directoryNameComponent)_budget_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }
        defer { try? FileManager.default.removeItem(atPath: E2ETestSupport.copilotHomePath(forTemporaryRootPath: testDir)) }

        let container = try makeTestContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Budget Test Workspace", primaryPath: testDir)
        context.insert(workspace)

        // 2. Create task with VERY LOW budget to force budget exceeded
        let task = AgentTask(
            title: "Budget limit test",
            goal: """
            Create an agent team with 3 teammates. Each should write a long essay (at least 500 words) \
            about a different programming language (Python, Rust, Go). Save each to a separate file.
            """,
            workspace: workspace,
            tokenBudget: 1,  // Deliberately low — should trigger the launch budget guardrail
            model: runtimeCase.model
        )
        task.runtimeID = runtimeCase.runtimeID.rawValue
        task.useAgentTeam = runtimeCase.expectsTeamEvents
        task.teamSize = runtimeCase.expectsTeamEvents ? 3 : 1
        context.insert(task)
        try context.save()

        // 3. Run
        let worker = AgentRuntimeWorker()
        try E2ETestSupport.configureUnattended(worker, for: runtimeCase, temporaryRootPath: testDir)
        worker.budgetEnforcementModeOverride = .hardStop
        try await E2ETestSupport.withLiveProviderSlot {
            await worker.execute(task: task, modelContext: context) { _ in }
        }

        // 4. Verify task reached a terminal state without crashing
        let isTerminal = task.isTerminal || task.status == .pendingUser || task.status == .budgetExceeded
        #expect(isTerminal, "Task should be terminal, got: \(task.status.rawValue)")

        // Worker should not still be running
        #expect(!worker.isRunning, "Worker should not be running after completion")

        // Should have some events recorded even if budget was exceeded
        #expect(!task.events.isEmpty, "Should have recorded some events before termination")
        #expect(task.runs.count >= 1, "Should have at least 1 run")
        #expect(task.runs.first?.completedAt != nil, "Run should have completed")

        print("\n=== Phase 3 Budget Exceeded Test ===")
        print("Runtime: \(runtimeCase.runtimeID.displayName)")
        print("Status: \(task.status.rawValue)")
        print("Tokens: \(task.tokensUsed) / \(task.tokenBudget)")
        print("Events: \(task.events.count)")
        print("=====================================\n")
    }
}
