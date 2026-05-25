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

// MARK: - Task deliverable expectation

@Suite("Task Deliverable Expectation")
@MainActor
struct TaskDeliverableExpectationTests {
    @Test("Artifact scan finds shallow task output files")
    func artifactScanFindsShallowTaskOutputFiles() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspacePath = NSTemporaryDirectory() + "deliverable-shallow-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workspacePath) }
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Deliverable", primaryPath: workspacePath)
        let task = AgentTask(title: "Create HTML", goal: "create an html file", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run))
    }

    @Test("Artifact scan respects explicit entry and depth caps")
    func artifactScanRespectsExplicitCaps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspacePath = NSTemporaryDirectory() + "deliverable-caps-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workspacePath) }
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Deliverable Caps", primaryPath: workspacePath)
        let task = AgentTask(title: "Create HTML", goal: "create an html file", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let nested = URL(fileURLWithPath: taskFolder)
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "<html></html>".write(
            to: nested.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        #expect(!TaskDeliverableExpectation.hasArtifact(for: task, run: run, scanEntryLimit: 0))
        #expect(!TaskDeliverableExpectation.hasArtifact(for: task, run: run, scanDepthLimit: 0))
        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run, scanDepthLimit: 3))
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

    @Test("Prompt routes standalone artifacts to task output folder")
    func promptRoutesStandaloneArtifactsToTaskOutputFolder() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-artifact")
        ctx.insert(ws)
        let task = AgentTask(
            title: "Tic tac toe",
            goal: "write a web page with html and javascript for a tic tac toe game",
            workspace: ws
        )
        ctx.insert(task)
        try ctx.save()

        let initialPrompt = AgentPromptBuilder.buildPrompt(for: task)
        let followUpPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "write this in files to see it working",
            task: task
        )

        for prompt in [initialPrompt, followUpPrompt] {
            #expect(prompt.contains("Task Output Folder:"))
            #expect(prompt.contains("create them in this task output folder by default"))
            #expect(prompt.contains("Only write to workspace or project files when the user explicitly names that target path"))
            #expect(prompt.contains("For informational tasks, summaries, reviews, lookups, and status checks, return the useful answer in chat"))
        }
    }

    @Test("Prompt makes current task explicit before context and at end")
    func currentTaskIsExplicitBeforeContextAndAtEnd() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-current-task")
        ctx.insert(ws)

        let oldTask = AgentTask(title: "Old browser task", goal: "Open the wrong old file", workspace: ws)
        oldTask.status = .completed
        oldTask.completedAt = Date().addingTimeInterval(-60)
        let oldRun = TaskRun(task: oldTask)
        oldRun.status = .completed
        oldRun.output = "This old task is context only and must not become the current task."
        oldTask.runs = [oldRun]
        ctx.insert(oldTask)
        ctx.insert(oldRun)

        let task = AgentTask(
            title: "Translate Alvaro1 t",
            goal: "open the doccument called  'Alvaro1 t' and translate all text to Spanish",
            workspace: ws
        )
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)

        #expect(prompt.hasPrefix("Current Task:\nopen the doccument called  'Alvaro1 t' and translate all text to Spanish"))
        #expect(prompt.contains("Recent tasks in this workspace (for context):"))
        let currentTaskIndex = try #require(prompt.range(of: "Current Task:")?.lowerBound)
        let recentTasksIndex = try #require(prompt.range(of: "Recent tasks in this workspace")?.lowerBound)
        #expect(currentTaskIndex < recentTasksIndex)
        #expect(prompt.hasSuffix("Current Task Reminder: complete this task now: open the doccument called  'Alvaro1 t' and translate all text to Spanish"))
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

    @Test("Initial prompt includes Astra Run Protocol instructions")
    func initialPromptIncludesAstraRunProtocol() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-arp")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        let worker = AgentRuntimeWorker()
        let prompt = worker.buildPrompt(for: task)

        #expect(prompt.contains("Astra Run Protocol v1:"))
        #expect(prompt.contains("ASTRA_EVENT {\"v\":1,\"type\":\"todo.replace\""))
        #expect(prompt.contains("ASTRA_EVENT {\"v\":1,\"type\":\"complete\""))
    }

    @Test("Follow-up prompt includes the same Astra Run Protocol instructions")
    func followUpPromptIncludesAstraRunProtocol() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-arp-followup")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)

        #expect(prompt.contains("Astra Run Protocol v1:"))
        #expect(prompt.contains("ASTRA_EVENT {\"v\":1,\"type\":\"todo.replace\""))
        #expect(prompt.contains("ASTRA_EVENT {\"v\":1,\"type\":\"complete\""))
    }

    @Test("Follow-up prompt includes exact recent session output")
    func followUpPromptIncludesExactRecentSessionOutput() throws {
        let root = NSTemporaryDirectory() + "prompt-followup-history-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: root)
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "Revise an email draft", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let filler = String(repeating: "setup context before the draft. ", count: 80)
        let exactDraft = "EXACT_ACTIVE_DRAFT_FOR_TEST: keep this current draft text available for revision."
        SessionHistoryManager.recordTurn(
            taskFolder: folder,
            taskTitle: task.title,
            turnMessage: "Please update the draft",
            output: filler + "\n\n" + exactDraft,
            tokensUsed: 0,
            costUSD: 0,
            fileChanges: []
        )

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "revise the draft", task: task)

        #expect(prompt.contains("Recent conversation transcript"))
        #expect(prompt.contains(exactDraft))
        #expect(prompt.contains("User's follow-up request:\nrevise the draft"))
    }

    @Test("Follow-up prompt ignores stale copied fork runs")
    func followUpPromptIgnoresStaleCopiedForkRuns() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let task = AgentTask(title: "Fork", goal: "Continue current branch")
        task.forkedFromID = UUID()
        task.forkedAtRunIndex = 5
        ctx.insert(task)

        for index in 0..<10 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index))
            run.completedAt = run.startedAt.addingTimeInterval(1)
            run.status = .completed
            run.output = index < 5 ? "STALE_COPIED_RUN_\(index)" : "ACTIVE_FORK_RUN_\(index)"
            run.appendFileChange(StoredFileChange(from: FileChange(
                path: index < 5 ? "/tmp/stale-copied-\(index).txt" : "/tmp/active-fork-\(index).txt",
                changeType: .write,
                content: nil,
                oldString: nil,
                newString: nil,
                timestamp: run.completedAt ?? run.startedAt
            )))
            task.runs.append(run)
            ctx.insert(run)
        }
        try ctx.save()

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "continue", task: task)

        #expect(!prompt.contains("STALE_COPIED_RUN_0"))
        #expect(!prompt.contains("STALE_COPIED_RUN_4"))
        #expect(!prompt.contains("/tmp/stale-copied-0.txt"))
        #expect(!prompt.contains("/tmp/stale-copied-4.txt"))
        #expect(prompt.contains("ACTIVE_FORK_RUN_5"))
        #expect(prompt.contains("ACTIVE_FORK_RUN_9"))
        #expect(prompt.contains("/tmp/active-fork-5.txt"))
        #expect(prompt.contains("/tmp/active-fork-9.txt"))
    }

    @Test("Copilot prompt includes Astra Run Protocol instructions through runtime capability")
    func copilotPromptIncludesAstraRunProtocol() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-arp-copilot")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        ctx.insert(task)
        try ctx.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: .copilotCLI))
        #expect(prompt.contains("Astra Run Protocol v1:"))
        #expect(prompt.contains("ASTRA_EVENT {\"v\":1,\"type\":\"todo.replace\""))
        #expect(prompt.contains("ASTRA_EVENT {\"v\":1,\"type\":\"complete\""))
    }

    @Test("Prompt includes Shelf browser bridge when visible and enabled")
    func promptIncludesShelfBrowserBridge() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-browser")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "Draft a reply", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://outlook.office.com/mail/",
            currentTitle: "Outlook",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("Shelf Browser Session:"))
        #expect(prompt.contains("Available CLI/Script Tools"))
        #expect(prompt.contains("Shelf Browser Control: `astra-browser`"))
        #expect(prompt.contains("ASTRA_BROWSER_URL"))
        #expect(prompt.contains(task.id.uuidString))
        #expect(prompt.contains("https://outlook.office.com/mail/"))
        #expect(prompt.contains("Do not send emails"))
        #expect(prompt.contains("astra-browser page --limit 2000"))
        #expect(prompt.contains("astra-browser snapshot --mode summary"))
        #expect(prompt.contains("astra-browser batch"))
        #expect(prompt.contains("astra-browser keypress"))
        #expect(prompt.contains("astra-browser text"))
        #expect(prompt.contains("astra-browser google-docs-insert"))
        #expect(prompt.contains("astra-browser google-docs-find"))
        #expect(prompt.contains("astra-browser google-docs-read-visible-page"))
        #expect(prompt.contains("astra-browser google-docs-read-document"))
        #expect(prompt.contains("astra-browser google-docs-replace-document"))
        #expect(prompt.contains("google_docs_controlled_browser_required"))
        #expect(prompt.contains("requires Controlled mode"))
        #expect(prompt.contains("astra-browser read-page --format markdown --limit 50000"))
        #expect(prompt.contains("clearly state partial coverage"))
        #expect(prompt.contains("Never use `keypress --key a --mod command` followed by Backspace/Delete"))
        #expect(!prompt.contains("astra-browser google-drive-open"))
        #expect(prompt.contains("Do not use osascript"))
    }

    @Test("Prompt adds read-only mail safety for browser-backed email tasks")
    func promptAddsReadOnlyMailSafetyForBrowserEmailTasks() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Mail Browser", primaryPath: "/tmp/prompt-mail-browser")
        ctx.insert(ws)
        let task = AgentTask(title: "Summarize my last email", goal: "summarize my last email", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://outlook.cloud.microsoft/mail/inbox/id/example",
            currentTitle: "Outlook",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("Mail Read Safety:"))
        #expect(prompt.contains("stanford-mail"))
        #expect(prompt.contains("treat Outlook/mail pages as read-only evidence"))
        #expect(prompt.contains("Do not click Reply, Reply all, Forward, Send"))
    }

    @Test("Prompt keeps promoted Shelf browser when inactive shared session starts")
    func promptKeepsPromotedShelfBrowserAfterInactiveSharedSessionUpdate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-browser-promoted")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "List files in the page", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://drive.google.com/drive/home",
            currentTitle: "Google Drive",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49153",
            currentURL: nil,
            currentTitle: nil,
            taskID: nil,
            isPresented: false,
            isEnabled: true
        )

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("Shelf Browser Session:"))
        #expect(prompt.contains("https://drive.google.com/drive/home"))
        #expect(prompt.contains("Google Drive"))
        #expect(prompt.contains("http://127.0.0.1:49152"))
        #expect(!prompt.contains("http://127.0.0.1:49153"))
        #expect(prompt.contains("astra-browser google-drive-open"))
        #expect(prompt.contains("respects the selected browser engine"))
        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id)["ASTRA_BROWSER_URL"] == "http://127.0.0.1:49152")
    }

    @Test("Prompt and environment keep enabled Shelf browser when panel is hidden")
    func promptKeepsEnabledShelfBrowserWhenPanelHidden() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-browser-hidden")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "Use browser", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "http://127.0.0.1:47831/",
            currentTitle: "Validation",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "http://127.0.0.1:47831/",
            currentTitle: "Validation",
            taskID: task.id,
            isPresented: false,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("Shelf Browser Session:"))
        #expect(prompt.contains("ASTRA_BROWSER_URL"))
        #expect(prompt.contains("http://127.0.0.1:47831/"))
        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id)["ASTRA_BROWSER_URL"] == "http://127.0.0.1:49152")
    }

    @Test("Prompt hides Shelf browser bridge when disabled")
    func promptHidesDisabledShelfBrowserBridge() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-browser-disabled")
        ctx.insert(ws)
        let task = AgentTask(title: "T", goal: "G", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com",
            currentTitle: "Example",
            taskID: task.id,
            isPresented: true,
            isEnabled: false
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(!prompt.contains("Shelf Browser Session:"))
        #expect(!prompt.contains("ASTRA_BROWSER_URL"))
    }

    @Test("Prompt hides Shelf browser bridge for other task threads")
    func promptHidesShelfBrowserBridgeForOtherTaskThreads() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-browser-other-task")
        ctx.insert(ws)
        let attachedTask = AgentTask(title: "Attached", goal: "Use browser", workspace: ws)
        let otherTask = AgentTask(title: "Other", goal: "No browser", workspace: ws)
        ctx.insert(attachedTask)
        ctx.insert(otherTask)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com",
            currentTitle: "Example",
            taskID: attachedTask.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: attachedTask.id)["ASTRA_BROWSER_URL"] == "http://127.0.0.1:49152")
        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: otherTask.id).isEmpty)

        let prompt = AgentPromptBuilder.buildPrompt(for: otherTask)

        #expect(!prompt.contains("Shelf Browser Session:"))
        #expect(!prompt.contains("ASTRA_BROWSER_URL"))
    }

    @Test("Shelf browser token is environment-only")
    func shelfBrowserTokenIsEnvironmentOnly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/prompt-browser-token")
        ctx.insert(ws)
        let task = AgentTask(title: "Attached", goal: "Use browser", workspace: ws)
        ctx.insert(task)
        try ctx.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com",
            currentTitle: "Example",
            taskID: task.id,
            accessToken: "ASTRA_TEST_BROWSER_TOKEN",
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let environment = ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id)
        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(environment["ASTRA_BROWSER_URL"] == "http://127.0.0.1:49152")
        #expect(environment["ASTRA_BROWSER_TOKEN"] == "ASTRA_TEST_BROWSER_TOKEN")
        #expect(prompt.contains("http://127.0.0.1:49152"))
        #expect(!prompt.contains("ASTRA_TEST_BROWSER_TOKEN"))
        #expect(!prompt.contains("ASTRA_BROWSER_TOKEN"))
    }
}

@Suite("Shelf Browser Address")
struct ShelfBrowserAddressTests {
    @Test("normalizes full URLs")
    func normalizesFullURLs() {
        #expect(ShelfBrowserAddress.normalizedURL(from: "https://example.com/path")?.absoluteString == "https://example.com/path")
    }

    @Test("normalizes hostnames to HTTPS")
    func normalizesHostnames() {
        #expect(ShelfBrowserAddress.normalizedURL(from: "outlook.office.com")?.absoluteString == "https://outlook.office.com")
    }

    @Test("normalizes absolute local file paths")
    func normalizesAbsoluteLocalFilePaths() {
        let path = "/tmp/astra preview/index.html"
        let url = ShelfBrowserAddress.normalizedURL(from: path)

        #expect(url?.isFileURL == true)
        #expect(url?.path == path)
    }

    @Test("normalizes search terms")
    func normalizesSearchTerms() {
        let url = ShelfBrowserAddress.normalizedURL(from: "service now incident form")?.absoluteString ?? ""
        #expect(url.contains("https://www.google.com/search"))
        #expect(url.contains("service%20now%20incident%20form") || url.contains("service+now+incident+form"))
    }
}

@Suite("Controlled Browser")
struct ControlledBrowserTests {
    @Test("launch arguments isolate profile and bind DevTools to localhost")
    func launchArgumentsIsolateProfileAndDevTools() throws {
        let candidate = ControlledBrowserCandidate(name: "Test Chromium", executablePath: "/tmp/chromium")
        let url = try #require(URL(string: "https://outlook.office.com/mail/"))

        let arguments = candidate.launchArguments(
            profilePath: "/tmp/astra-browser-profile",
            debugPort: 49_123,
            initialURL: url
        )

        #expect(arguments.contains("--remote-debugging-address=127.0.0.1"))
        #expect(arguments.contains("--remote-debugging-port=49123"))
        #expect(arguments.contains("--user-data-dir=/tmp/astra-browser-profile"))
        #expect(arguments.contains("--no-first-run"))
        #expect(arguments.contains("--new-window"))
        #expect(arguments.last == "https://outlook.office.com/mail/")
    }

    @Test("default candidates cover common Chromium browsers")
    func defaultCandidatesCoverCommonChromiumBrowsers() {
        let names = Set(ControlledBrowserCandidate.defaultCandidates.map(\.name))

        #expect(names.contains("Google Chrome"))
        #expect(names.contains("Microsoft Edge"))
        #expect(names.contains("Brave Browser"))
        #expect(names.contains("Chromium"))
    }

    @Test("controlled browser handoff preserves embedded page URL")
    @MainActor
    func controlledBrowserHandoffPreservesEmbeddedPageURL() throws {
        let webViewURL = try #require(URL(string: "https://drive.google.com/drive/home"))

        let address = ShelfBrowserSession.controlledBrowserHandoffAddress(
            currentURL: "about:blank",
            webViewURL: webViewURL
        )

        #expect(address == "https://drive.google.com/drive/home")
    }

    @Test("controlled browser handoff ignores blank pages")
    @MainActor
    func controlledBrowserHandoffIgnoresBlankPages() throws {
        let webViewURL = try #require(URL(string: "about:blank"))

        let address = ShelfBrowserSession.controlledBrowserHandoffAddress(
            currentURL: "",
            webViewURL: webViewURL
        )

        #expect(address == nil)
    }

    @Test("embedded browser handoff preserves controlled page URL")
    @MainActor
    func embeddedBrowserHandoffPreservesControlledPageURL() {
        let address = ShelfBrowserSession.embeddedBrowserHandoffAddress(
            currentURL: "about:blank",
            controlledURL: "https://docs.google.com/document/d/example/edit"
        )

        #expect(address == "https://docs.google.com/document/d/example/edit")
    }

    @Test("embedded browser handoff falls back to current URL")
    @MainActor
    func embeddedBrowserHandoffFallsBackToCurrentURL() {
        let address = ShelfBrowserSession.embeddedBrowserHandoffAddress(
            currentURL: "https://drive.google.com/drive/home",
            controlledURL: "about:blank"
        )

        #expect(address == "https://drive.google.com/drive/home")
    }

    @Test("dangerous clicks require explicit override")
    func dangerousClicksRequireOverride() {
        let script = BrowserAutomationScripts.clickScript(
            selector: "button[type=submit]",
            x: nil,
            y: nil,
            allowDangerous: false
        )

        #expect(script.contains("confirmation_required"))
        #expect(script.contains("allowDangerous = false"))
        #expect(script.contains("reply all"))
        #expect(script.contains("archive"))
    }

    @Test("click script supports viewport coordinate targets")
    func clickScriptSupportsViewportCoordinates() {
        let script = BrowserAutomationScripts.clickScript(
            selector: nil,
            x: 0.5,
            y: 0.5,
            allowDangerous: false
        )

        #expect(script.contains("document.elementFromPoint"))
        #expect(script.contains("normalized"))
    }

    @Test("click script supports locator actionability checks")
    func clickScriptSupportsLocatorActionabilityChecks() {
        let script = BrowserAutomationScripts.clickScript(
            selector: nil,
            x: nil,
            y: nil,
            allowDangerous: false,
            label: "Save",
            role: "button"
        )

        #expect(script.contains("locatorLabel"))
        #expect(script.contains("locatorRole"))
        #expect(script.contains("target_obscured"))
        #expect(script.contains("target_disabled"))
        #expect(script.contains("boundsForTarget"))
    }

    @Test("type script supports filling by label")
    func typeScriptSupportsFillingByLabel() {
        let script = BrowserAutomationScripts.typeScript(
            selector: nil,
            text: "alvaro@example.com",
            clear: true,
            label: "Email"
        )

        #expect(script.contains("locatorLabel"))
        #expect(script.contains("target_not_editable"))
        #expect(script.contains("insertReplacementText"))
    }

    @Test("snapshot reports focus and bounds metadata")
    func snapshotReportsFocusAndBoundsMetadata() {
        let script = BrowserAutomationScripts.snapshotScript

        #expect(script.contains("focusedElement"))
        #expect(script.contains("boundsFor"))
        #expect(script.contains("viewport"))
        #expect(script.contains("actionable"))
        #expect(script.contains("shadowRoot"))
        #expect(script.contains("compareViewportOrder"))
        #expect(script.contains("inViewport"))
    }

    @Test("existing controlled profile process parser finds DevTools port")
    func existingControlledProfileProcessParserFindsDevToolsPort() {
        let processList = """
          99935 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-address=127.0.0.1 --remote-debugging-port=60007 --user-data-dir=/tmp/Astra Dev/ControlledBrowser/Default --new-window
          99942 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --user-data-dir=/tmp/Astra Dev/ControlledBrowser/Default
        """

        let target = ControlledBrowserController.runningDebugTarget(
            profilePath: "/tmp/Astra Dev/ControlledBrowser/Default",
            processList: processList
        )

        #expect(target == ControlledBrowserDebugTarget(processID: 99_935, debugPort: 60_007))
    }

    @Test("existing controlled profile parser prefers the primary browser process")
    func existingControlledProfileParserPrefersPrimaryBrowserProcess() {
        let processList = """
          39917 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/147.0.7727.56/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer --user-data-dir=/tmp/Astra Dev/ControlledBrowser/Default --remote-debugging-port=60007
          99935 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-address=127.0.0.1 --remote-debugging-port=60007 --user-data-dir=/tmp/Astra Dev/ControlledBrowser/Default --no-first-run --new-window
        """

        let target = ControlledBrowserController.runningDebugTarget(
            profilePath: "/tmp/Astra Dev/ControlledBrowser/Default",
            processList: processList
        )

        #expect(target == ControlledBrowserDebugTarget(processID: 99_935, debugPort: 60_007))
    }
}

@Suite("Cardinal Key Client Certificate")
struct CardinalKeyClientCertificateTests {
    @Test("limits automatic certificate use to Stanford hosts")
    func limitsAutomaticCertificateUseToStanfordHosts() {
        #expect(CardinalKeyClientCertificateProvider.isStanfordHost("login.stanford.edu"))
        #expect(CardinalKeyClientCertificateProvider.isStanfordHost("cardinalkey-test.stanford.edu"))
        #expect(CardinalKeyClientCertificateProvider.isStanfordHost("stanford.edu"))
        #expect(!CardinalKeyClientCertificateProvider.isStanfordHost("evilstanford.edu"))
        #expect(!CardinalKeyClientCertificateProvider.isStanfordHost("stanford.edu.example.com"))
        #expect(!CardinalKeyClientCertificateProvider.isStanfordHost("google.com"))
    }

    @Test("recognizes Cardinal Key enrollment subjects")
    func recognizesCardinalKeyEnrollmentSubjects() {
        #expect(CardinalKeyClientCertificateProvider.isCardinalKeySubject("sunetid/Enrollment-12345"))
        #expect(CardinalKeyClientCertificateProvider.isCardinalKeySubject("SUNETID/Enrollment"))
        #expect(CardinalKeyClientCertificateProvider.isCardinalKeySubject("Stanford Cardinal Key"))
        #expect(!CardinalKeyClientCertificateProvider.isCardinalKeySubject("Developer ID Application"))
    }
}
