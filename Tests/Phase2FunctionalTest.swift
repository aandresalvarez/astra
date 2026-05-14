import Testing
import Foundation
@testable import ASTRA
import ASTRACore
import SwiftData

/// Phase 2 Functional Test — Maker & Checker Team (2 Agents)
/// Tests: agent spawning, task dependencies, inter-agent messaging, and cleanup.
/// The Lead agent spawns a Developer and QA Tester to build and test a regex parser.

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
    let files = enumerator.compactMap { $0 as? String }.prefix(120)
    return files.isEmpty ? "<empty>" : files.joined(separator: ", ")
}

@Suite("Phase 2 Functional — Maker & Checker Team", .tags(.integration))
struct Phase2FunctionalTest {

    @Test("Team task with 2 agents: Developer + QA Tester", .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call Claude CLI"))
    @MainActor
    func makerCheckerTeam() async throws {
        // 1. Create workspace directory
        let testDir = "/tmp/phase2_team_test_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        // 2. Create SwiftData container and workspace
        let container = try makeTestContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Phase2 Test Workspace", primaryPath: testDir)
        context.insert(workspace)

        // 3. Create task with Agent Teams enabled
        let task = AgentTask(
            title: "Regex email extractor with QA",
            goal: """
            Complete this small JavaScript task with concise team coordination.
            The final deliverables must exist in the current working directory:
            - ./regex.js: exports a function that extracts all email addresses from a string.
            - ./test.js: tests simple emails, subdomains, plus signs, and invalid strings.
            - ./test_results.txt: the captured result from running `node test.js`.
            Run the tests, fix any bug found, and verify all three files exist before your final response.
            """,
            workspace: workspace,
            tokenBudget: 350000,
            model: "claude-sonnet-4-6"
        )
        task.status = .queued
        task.useAgentTeam = true
        task.teamSize = 2
        task.teamInstructions = """
        Spawn two teammates:
        1. A 'Developer' who writes the regex.js email extractor function.
        2. A 'QA Tester' who writes test.js to find edge cases and validates the implementation.
        The QA Tester should wait for the Developer to finish before testing. \
        If bugs are found, communicate to fix them. The lead agent remains responsible for ensuring \
        regex.js, test.js, and test_results.txt exist in the current working directory before finishing.
        """
        context.insert(task)
        try context.save()

        #expect(task.useAgentTeam == true, "Task should have teams enabled")
        #expect(task.teamSize == 2, "Team size should be 2")

        // 4. Run through AgentRuntimeWorker
        let worker = AgentRuntimeWorker()
        var receivedEvents: [ParsedEvent] = []

        await worker.execute(task: task, modelContext: context) { event in
            receivedEvents.append(event)
        }

        // 5. Verify task lifecycle
        // Agent teams can exceed budget due to batched token reporting — budgetExceeded is acceptable
        let isTerminal = task.isTerminal || task.status == .pendingUser || task.status == .budgetExceeded
        #expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
        #expect(task.status != .failed, "Task should not have failed, status: \(task.status.rawValue)")
        #expect(task.tokensUsed > 0, "Tokens used: \(task.tokensUsed)")
        #expect(task.costUSD > 0, "Cost: \(task.costUSD)")
        #expect(task.sessionId != nil, "Session ID should be captured")

        // 6. Verify TaskRun
        #expect(task.runs.count >= 1, "Should have at least 1 run")
        let run = task.runs.first!
        #expect(run.tokensUsed > 0)
        #expect(run.completedAt != nil)

        // 7. Verify core events exist
        let allEvents = task.events
        let eventTypes = Set(allEvents.map(\.type))

        #expect(eventTypes.contains("task.started"), "Missing task.started")
        #expect(eventTypes.contains("agent.thinking"), "Missing agent.thinking")
        #expect(eventTypes.contains("tool.use"), "Missing tool.use")
        #expect(eventTypes.contains("task.stats"), "Missing task.stats")

        // 8. Verify Agent Teams events — spawning teammates
        // The Lead should spawn agents (team.agent.started events or Agent tool uses)
        let teamStartEvents = allEvents.filter { $0.type == "team.agent.started" }
        let agentToolUses = allEvents.filter { $0.type == "tool.use" && $0.payload.contains("Agent") }
        let hasTeamActivity = !teamStartEvents.isEmpty || !agentToolUses.isEmpty
        #expect(hasTeamActivity, "Should have team agent spawning events (team.agent.started or Agent tool uses)")

        // 9. Verify files on disk
        let fm = FileManager.default
        let fileListing = workspaceFileListing(at: testDir)
        let regexPath = try #require(
            findOutputFile(named: "regex.js", workspacePath: testDir, task: task),
            "regex.js missing from workspace or task output folder. Files: \(fileListing)"
        )
        let testPath = try #require(
            findOutputFile(named: "test.js", workspacePath: testDir, task: task),
            "test.js missing from workspace or task output folder. Files: \(fileListing)"
        )
        #expect(fm.fileExists(atPath: regexPath), "regex.js should exist")
        #expect(fm.fileExists(atPath: testPath), "test.js should exist")

        // Verify regex.js has email extraction logic
        let regexContent = try String(contentsOfFile: regexPath, encoding: .utf8)
        #expect(regexContent.contains("email") || regexContent.contains("Email") || regexContent.contains("@"),
                "regex.js should contain email-related code")

        // Verify test.js has test cases
        let testContent = try String(contentsOfFile: testPath, encoding: .utf8)
        #expect(testContent.contains("test") || testContent.contains("assert") || testContent.contains("expect"),
                "test.js should contain test assertions")

        // Check for test results
        let hasTestResults = findOutputFile(named: "test_results.txt", workspacePath: testDir, task: task) != nil

        // 10. Verify callback events include team-related events
        let parsedTeamEvents = receivedEvents.filter {
            if case .teammateStarted = $0 { return true }
            if case .teammateCompleted = $0 { return true }
            if case .teamMessage = $0 { return true }
            if case .toolUse(let name, _, _) = $0, name == "Agent" { return true }
            return false
        }

        // Summary
        print("\n=== Phase 2 Maker & Checker E2E Results ===")
        print("Workspace: \(workspace.name) -> \(workspace.primaryPath)")
        print("Status: \(task.status.rawValue)")
        print("Tokens: \(task.tokensUsed) / \(task.tokenBudget)")
        print("Cost: $\(String(format: "%.4f", task.costUSD))")
        print("Session: \(task.sessionId ?? "nil")")
        print("Events: \(allEvents.count) (\(eventTypes.sorted().joined(separator: ", ")))")
        print("Team start events: \(teamStartEvents.count)")
        print("Agent tool uses: \(agentToolUses.count)")
        print("Parsed team events: \(parsedTeamEvents.count)")
        print("Files: regex.js=\(fm.fileExists(atPath: "\(testDir)/regex.js")), test.js=\(fm.fileExists(atPath: "\(testDir)/test.js")), test_results.txt=\(hasTestResults)")
        print("regex.js preview: \(regexContent.prefix(200))")
        print("===========================================\n")
    }
}
