import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

private func makeContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

// MARK: - Cancel

@Suite("AgentRuntimeWorker Cancel")
@MainActor
struct WorkerCancelTests {

    @Test("Cancel on idle worker is safe")
    func cancelIdle() {
        let worker = AgentRuntimeWorker()
        #expect(worker.isRunning == false)
        worker.cancel()
        #expect(worker.isRunning == false)
    }
}

// MARK: - ensureSubAgentPermissions

@Suite("Sub-Agent Permissions File")
struct SubAgentPermissionsTests {

    @Test("Autonomous policy writes Bash(*) permissions")
    @MainActor func autonomousWritesFile() throws {
        let dir = NSTemporaryDirectory() + "subagent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        AgentRuntimeWorker.ensureSubAgentPermissions(
            at: dir, policy: .autonomous, allowedTools: []
        )

        let settingsPath = (dir as NSString)
            .appendingPathComponent(".claude/settings.local.json")
        #expect(FileManager.default.fileExists(atPath: settingsPath))

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = json?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.contains("Bash(*)"))
    }

    @Test("Restricted policy writes only specified tools")
    @MainActor func restrictedWritesSpecificTools() throws {
        let dir = NSTemporaryDirectory() + "subagent-restricted-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        AgentRuntimeWorker.ensureSubAgentPermissions(
            at: dir, policy: .restricted, allowedTools: ["Read", "Grep"]
        )

        let settingsPath = (dir as NSString)
            .appendingPathComponent(".claude/settings.local.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = json?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.contains("Read(*)"))
        #expect(allow.contains("Grep(*)"))
        #expect(!allow.contains("Bash(*)"))
    }

    @Test("Interactive policy writes no file")
    @MainActor func interactiveSkips() throws {
        let dir = NSTemporaryDirectory() + "subagent-interactive-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        AgentRuntimeWorker.ensureSubAgentPermissions(
            at: dir, policy: .interactive, allowedTools: ["Read"]
        )

        let settingsPath = (dir as NSString)
            .appendingPathComponent(".claude/settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: settingsPath))
    }

    @Test("Existing settings file is merged with permissions")
    @MainActor func existingFilePreserved() throws {
        let dir = NSTemporaryDirectory() + "subagent-existing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let claudeDir = (dir as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        let original = "{\"custom\": true}".data(using: .utf8)!
        try original.write(to: URL(fileURLWithPath: settingsPath))

        AgentRuntimeWorker.ensureSubAgentPermissions(
            at: dir, policy: .autonomous, allowedTools: []
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["custom"] as? Bool == true)
        let perms = json?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.contains("Bash(*)"))
    }

    @Test("Template hooks and permissions coexist in settings file")
    @MainActor func templateHooksMergeWithPermissions() throws {
        let dir = NSTemporaryDirectory() + "subagent-hooks-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let hooksJSON = """
        {
          "PostToolUse": [
            {
              "matcher": "Write",
              "hooks": [
                { "type": "command", "command": "echo ok" }
              ]
            }
          ]
        }
        """
        let backup = ClaudeSettingsStore.injectTemplateHooks(hooksJSON: hooksJSON, workspacePath: dir)
        #expect(backup == nil)

        AgentRuntimeWorker.ensureSubAgentPermissions(
            at: dir, policy: .restricted, allowedTools: ["Read", "Grep"]
        )

        let settingsPath = (dir as NSString)
            .appendingPathComponent(".claude/settings.local.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = json?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.contains("Read(*)"))
        #expect(allow.contains("Grep(*)"))

        let hooks = json?["hooks"] as? [String: [[String: Any]]]
        let postToolUse = hooks?["PostToolUse"] ?? []
        #expect(postToolUse.count == 1)
        #expect(postToolUse.first?["_astra_template"] as? Bool == true)

        ClaudeSettingsStore.restoreTemplateHooks(hooksJSON: hooksJSON, workspacePath: dir, backup: backup)

        let restoredData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let restoredJSON = try JSONSerialization.jsonObject(with: restoredData) as? [String: Any]
        let restoredPerms = restoredJSON?["permissions"] as? [String: Any]
        let restoredAllow = restoredPerms?["allow"] as? [String] ?? []
        #expect(restoredAllow.contains("Read(*)"))
        #expect(restoredAllow.contains("Grep(*)"))
        #expect(restoredJSON?["hooks"] == nil)
    }
}

// MARK: - compactEvents

@Suite("Event Compaction (SwiftData)")
@MainActor
struct CompactionSwiftDataTests {

    @Test("Events below threshold are not compacted")
    func belowThreshold() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/compact-test")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)

        for i in 0..<100 {
            let e = TaskEvent(task: task, type: "text", payload: "msg \(i)")
            ctx.insert(e)
        }
        try ctx.save()

        AgentRuntimeWorker.compactEvents(for: task, modelContext: ctx)
        #expect(task.events.count == 100)
    }

    @Test("Events above threshold are compacted with summary")
    func aboveThreshold() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/compact-test-2")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)

        for i in 0..<250 {
            let e = TaskEvent(task: task, type: i < 200 ? "text" : "tool", payload: "msg \(i)")
            e.timestamp = Date(timeIntervalSince1970: Double(i))
            ctx.insert(e)
        }
        try ctx.save()

        AgentRuntimeWorker.compactEvents(for: task, modelContext: ctx)
        try ctx.save()

        let remaining = task.events
        #expect(remaining.count == 51)
        let summary = remaining.first { $0.type == "activity.compacted" }
        #expect(summary != nil)
        #expect(summary?.payload.contains("Compacted 200") == true)
    }
}

// MARK: - buildPrompt

@Suite("Build Prompt")
@MainActor
struct BuildPromptTests {

    @Test("Prompt includes goal")
    func includesGoal() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-test")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "Fix the login bug", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)
        #expect(prompt.contains("Goal: Fix the login bug"))
    }

    @Test("Prompt includes workspace instructions")
    func includesInstructions() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-inst", instructions: "Use Swift 6 strict concurrency")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)
        #expect(prompt.contains("Workspace Context:"))
        #expect(prompt.contains("Use Swift 6 strict concurrency"))
    }

    @Test("Prompt includes memories")
    func includesMemories() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-mem")
        ws.memories = ["User prefers tabs over spaces", "Project uses SwiftData"]
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)
        #expect(prompt.contains("YOUR MEMORIES"))
        #expect(prompt.contains("User prefers tabs over spaces"))
        #expect(prompt.contains("Project uses SwiftData"))
    }

    @Test("Prompt includes constraints and acceptance criteria")
    func includesConstraints() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-c")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        task.constraints = ["No external dependencies"]
        task.acceptanceCriteria = ["All tests pass"]
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)
        #expect(prompt.contains("Constraints:"))
        #expect(prompt.contains("No external dependencies"))
        #expect(prompt.contains("Acceptance Criteria:"))
        #expect(prompt.contains("All tests pass"))
    }

    @Test("Prompt includes agent team block when enabled")
    func agentTeam() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-team")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        task.useAgentTeam = true
        task.teamSize = 3
        task.teamInstructions = "Focus on security"
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)
        #expect(prompt.contains("Create an agent team with 3 teammates"))
        #expect(prompt.contains("Focus on security"))
    }
}
