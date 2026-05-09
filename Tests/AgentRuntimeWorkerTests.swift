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

        #expect(AgentRuntimeID.copilotCLI.supportsAstraRunProtocol)
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
        #expect(prompt.contains("ASTRA_BROWSER_URL"))
        #expect(prompt.contains(task.id.uuidString))
        #expect(prompt.contains("https://outlook.office.com/mail/"))
        #expect(prompt.contains("Do not send emails"))
        #expect(prompt.contains("astra-browser snapshot --mode summary"))
        #expect(prompt.contains("astra-browser batch"))
        #expect(prompt.contains("astra-browser keypress"))
        #expect(prompt.contains("astra-browser text"))
        #expect(prompt.contains("Do not use osascript"))
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

    @Test("snapshot reports focus and bounds metadata")
    func snapshotReportsFocusAndBoundsMetadata() {
        let script = BrowserAutomationScripts.snapshotScript

        #expect(script.contains("focusedElement"))
        #expect(script.contains("boundsFor"))
        #expect(script.contains("viewport"))
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
