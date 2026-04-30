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

@Suite("Phase 3 Functional — Parallel Debate Swarm", .tags(.integration))
struct Phase3FunctionalTest {

    @Test("3-agent debate with synthesis to markdown", .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call Claude CLI"))
    @MainActor
    func parallelDebateSwarm() async throws {
        // 1. Create workspace directory
        let testDir = "/tmp/phase3_swarm_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

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
            Investigate Redux Toolkit, Zustand, and React Context API. \
            Compare them on bundle size, boilerplate, ease of use, TypeScript support, \
            and performance. Challenge each approach's assumptions. \
            Output a final markdown file named state-decision.md with a comparison matrix table \
            and a clear recommendation with reasoning.
            """,
            workspace: workspace,
            tokenBudget: 200000,
            model: "claude-sonnet-4-6"
        )
        task.useAgentTeam = true
        task.teamSize = 3
        task.teamInstructions = """
        Create an agent team with 3 teammates:
        - Teammate 1 advocates for Redux Toolkit
        - Teammate 2 advocates for Zustand
        - Teammate 3 advocates for React Context API
        Have them research and debate the pros and cons based on bundle size, boilerplate, \
        ease of use, TypeScript support, and performance. They must actively challenge each \
        other's assumptions. Once they reach a consensus, output a final markdown file named \
        state-decision.md with a comparison matrix and recommendation.
        """
        context.insert(task)
        try context.save()

        #expect(task.useAgentTeam == true)
        #expect(task.teamSize == 3)

        // 4. Run through AgentRuntimeWorker
        let worker = AgentRuntimeWorker()
        var receivedEvents: [ParsedEvent] = []

        await worker.execute(task: task, modelContext: context) { event in
            receivedEvents.append(event)
        }

        // 5. Verify task lifecycle
        let isTerminal = task.isTerminal || task.status == .pendingUser || task.status == .budgetExceeded
        #expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
        #expect(task.tokensUsed > 0, "Tokens used: \(task.tokensUsed)")
        #expect(task.costUSD > 0, "Cost: \(task.costUSD)")
        #expect(task.sessionId != nil, "Session ID should be captured")

        // 6. Verify TaskRun
        #expect(task.runs.count >= 1, "Should have at least 1 run")
        let run = task.runs.first!
        #expect(run.tokensUsed > 0)
        #expect(run.completedAt != nil)

        // 7. Verify core events
        let allEvents = task.events
        let eventTypes = Set(allEvents.map(\.type))

        #expect(eventTypes.contains("task.started"), "Missing task.started")
        #expect(eventTypes.contains("agent.thinking"), "Missing agent.thinking")
        #expect(eventTypes.contains("task.stats"), "Missing task.stats")

        // 8. Verify parallel team activity
        let teamStartEvents = allEvents.filter { $0.type == "team.agent.started" }
        let teamCompletedEvents = allEvents.filter { $0.type == "team.agent.completed" }
        let agentToolUses = allEvents.filter { $0.type == "tool.use" && $0.payload.contains("Agent") }
        let hasTeamActivity = !teamStartEvents.isEmpty || !agentToolUses.isEmpty

        #expect(hasTeamActivity,
                "Should have team spawning activity (team.agent.started: \(teamStartEvents.count), Agent tools: \(agentToolUses.count))")

        // For a 3-agent team, expect multiple agent spawns
        let totalAgentSpawns = teamStartEvents.count + agentToolUses.count
        #expect(totalAgentSpawns >= 2,
                "Should spawn at least 2 agents for a 3-teammate task, got \(totalAgentSpawns)")

        // 9. Verify output file — state-decision.md
        let fm = FileManager.default
        let decisionPath = "\(testDir)/state-decision.md"
        let hasDecisionFile = fm.fileExists(atPath: decisionPath)

        if hasDecisionFile {
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
            #expect(task.tokensUsed > task.tokenBudget,
                    "Budget exceeded status should mean tokens (\(task.tokensUsed)) exceeded budget (\(task.tokenBudget))")
        }

        // Summary
        print("\n=== Phase 3 Parallel Debate Swarm Results ===")
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

    @Test("Budget exceeded kills swarm cleanly")
    @MainActor
    func budgetExceededKillsSwarm() async throws {
        // 1. Create workspace
        let testDir = "/tmp/phase3_budget_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

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
            tokenBudget: 5000,  // Deliberately low — should trigger budget exceeded
            model: "claude-sonnet-4-6"
        )
        task.useAgentTeam = true
        task.teamSize = 3
        context.insert(task)
        try context.save()

        // 3. Run
        let worker = AgentRuntimeWorker()
        await worker.execute(task: task, modelContext: context) { _ in }

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
        print("Status: \(task.status.rawValue)")
        print("Tokens: \(task.tokensUsed) / \(task.tokenBudget)")
        print("Events: \(task.events.count)")
        print("=====================================\n")
    }
}
