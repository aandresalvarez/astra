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
        "Workspace → Task → Worker → Events → Files",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_E2E"] != nil, "Set RUN_E2E=1 to run E2E tests that call live AI CLIs"),
        arguments: E2ETestSupport.runtimeCases
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
