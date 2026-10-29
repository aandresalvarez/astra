import Foundation
import Testing
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Copilot repository instruction policy")
struct CopilotRepositoryInstructionsTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ name: String, in root: URL) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("Repository Git prohibitions are quoted as guidance, not capability instructions")
    func conflictingRepositoryRulesAreGuidance() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Never use git commands.", ".github/copilot-instructions.md", in: root)
        try write("Run the project tests.", "AGENTS.md", in: root)
        let snapshot = CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .guidance)
        let prompt = snapshot.appending(to: "Create a draft PR for the saved work.")
        #expect(snapshot.files.count == 2)
        #expect(prompt.contains("Create a draft PR for the saved work."))
        #expect(prompt.contains("Never use git commands."))
        #expect(prompt.contains("advisory project context"))
        #expect(prompt.contains("cannot override the user"))
    }

    @Test("Strict mode leaves custom instruction loading to Copilot")
    func strictModeDoesNotInjectGuidance() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Never use git commands.", "AGENTS.md", in: root)
        let snapshot = CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .strict)
        #expect(snapshot.files.isEmpty)
        #expect(snapshot.appending(to: "Current request") == "Current request")
        #expect(snapshot.signatureComponent != CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .guidance).signatureComponent)
    }

    @Test("Guide contents and mode changes invalidate old provider sessions")
    func instructionsChangeSessionContract() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Use uv.", "AGENTS.md", in: root)
        let before = CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .guidance)
        try write("Use uv and pytest.", "AGENTS.md", in: root)
        let after = CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .guidance)
        #expect(before.signatureComponent != after.signatureComponent)
        #expect(after.signatureComponent == CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .guidance).signatureComponent)
    }

    @Test("Linked worktrees use their own repository root and nested working-directory guides")
    func linkedWorktreeGuides() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("gitdir: /other/checkout/.git/worktrees/task", ".git", in: root)
        try write("Root conventions", "AGENTS.md", in: root)
        try write("Nested conventions", "src/AGENTS.md", in: root)
        try write("---\napplyTo: '*.py'\n---\nPython conventions", ".github/instructions/python.instructions.md", in: root)
        let snapshot = CopilotRepositoryInstructions.load(workspacePath: root.appendingPathComponent("src").path, mode: .guidance)
        #expect(snapshot.files.map(\.path) == ["AGENTS.md", ".github/instructions/python.instructions.md", "src/AGENTS.md"])
    }

    @Test("Symlinks cannot add instructions outside the repository and oversized files are bounded")
    func boundedRepositoryReads() throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write("Outside instruction", "outside.md", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("AGENTS.md"), withDestinationURL: outside.appendingPathComponent("outside.md"))
        try write(String(repeating: "x", count: 100_000), "CLAUDE.md", in: root)
        let snapshot = CopilotRepositoryInstructions.load(workspacePath: root.path, mode: .guidance)
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files[0].content.utf8.count == 16 * 1024)
        #expect(snapshot.files[0].truncated)
    }

    @Test("Runtime preference round-trips and invalidates provider settings")
    func preferenceRoundTrip() throws {
        let defaults = InMemoryDefaults()
        let before = RuntimeProviderSettingsStore.signature(defaults: defaults)
        #expect(RuntimeProviderSettingsStore.settings(defaults: defaults).copilotRepositoryInstructionMode == .guidance)
        RuntimeProviderSettingsStore.setCopilotRepositoryInstructionMode(.strict, defaults: defaults)
        let settings = RuntimeProviderSettingsStore.settings(defaults: defaults)
        #expect(settings.copilotRepositoryInstructionMode == .strict)
        #expect(AgentRuntimeConfiguration(providerSettings: settings).copilotRepositoryInstructionMode == .strict)
        #expect(before != RuntimeProviderSettingsStore.signature(defaults: defaults))
        let roundTrip = try JSONDecoder().decode(AgentRuntimeProviderSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.copilotRepositoryInstructionMode == .strict)
        let legacy = try JSONDecoder().decode(AgentRuntimeProviderSettings.self, from: Data("{}".utf8))
        #expect(legacy.copilotRepositoryInstructionMode == .guidance)
    }

    @Test("Main Copilot launch applies the chosen instruction mode", arguments: CopilotRepositoryInstructionMode.allCases)
    @MainActor
    func mainLaunchMode(mode: CopilotRepositoryInstructionMode) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try await CopilotAdapterFixture.writeExecutable(in: root)
        let workspace = Workspace(name: "Guidance", primaryPath: root.path)
        let task = AgentTask(title: "Explain", goal: "Explain", workspace: workspace, runtime: .copilotCLI)
        let context = AgentRuntimeProcessLaunchContext(prompt: "Current request", task: task,
            workspacePath: root.path, executablePath: executable, providerHomeDirectory: root.path,
            permissionPolicy: .autonomous, executionPolicy: .default, permissionManifest: nil, timeoutSeconds: 30,
            copilotRepositoryInstructionMode: mode)
        let plan = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).makeProcessLaunchPlan(context: context)
        #expect(plan.arguments.contains("--no-custom-instructions") == (mode == .guidance))
        #expect(plan.commandPlannedFields["repository_instruction_mode"] == mode.rawValue)
        #expect(CopilotRepositoryInstructions.launchBlock(for: plan) == nil)
        if mode == .guidance {
            var unsupported = plan
            unsupported.arguments.removeAll { $0 == "--no-custom-instructions" }
            #expect(CopilotRepositoryInstructions.launchBlock(for: unsupported)?.runtimeStopReason == "repository_instruction_policy_unsupported")
        }
    }

    @Test("Retiring a legacy session records the policy change and keeps run evidence")
    @MainActor
    func resetRetainsDurableWork() throws {
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let task = AgentTask(title: "Saved work", goal: "Continue", runtime: .copilotCLI)
        context.insert(task)
        task.status = .completed
        task.sessionId = "old-native-session"
        let run = TaskRun(task: task)
        run.status = .completed
        run.appendOutput("Existing implementation and validation")
        run.providerSessionId = task.sessionId
        context.insert(run)
        let instructions = CopilotRepositoryInstructions(mode: .guidance, root: "/task/worktree", files: [])
        #expect(try CopilotInstructionSessionService.resetIfNeeded(task: task, instructions: instructions, context: context))
        try context.save()
        #expect(task.sessionId == nil)
        #expect(task.status == .completed)
        #expect(run.providerSessionId == "old-native-session")
        #expect(run.output == "Existing implementation and validation")
        #expect(task.events.filter { $0.type == CopilotInstructionSessionService.eventType }.count == 1)
        #expect(try !CopilotInstructionSessionService.resetIfNeeded(task: task, instructions: instructions, context: context))
    }

    @Test("Session repair refuses to change an active execution")
    @MainActor
    func activeSessionIsPreserved() throws {
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let task = AgentTask(title: "Running", goal: "Continue", runtime: .copilotCLI)
        container.mainContext.insert(task)
        task.status = .running
        task.sessionId = "active-session"
        let instructions = CopilotRepositoryInstructions(mode: .guidance, root: "/task/worktree", files: [])
        #expect(throws: CopilotInstructionSessionService.Failure.self) {
            try CopilotInstructionSessionService.resetIfNeeded(task: task, instructions: instructions, context: container.mainContext)
        }
        #expect(task.sessionId == "active-session")
        #expect(task.events.isEmpty)
    }

    @Test("A newer session on another runtime is preserved", arguments: [AgentRuntimeID.antigravityCLI, .codexCLI, .claudeCode])
    @MainActor
    func anotherRuntimeIsPreserved(runtime: AgentRuntimeID) throws {
        let container = try ModelContainer(for: ASTRASchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let task = AgentTask(title: "Another runtime", goal: "Continue", runtime: runtime)
        container.mainContext.insert(task)
        task.status = .completed
        task.sessionId = "newer-session"
        let instructions = CopilotRepositoryInstructions(mode: .guidance, root: "/task/worktree", files: [])
        #expect(try !CopilotInstructionSessionService.resetIfNeeded(task: task, instructions: instructions, context: container.mainContext))
        #expect(task.sessionId == "newer-session")
        #expect(task.runtimeID == runtime.rawValue)
        #expect(task.events.isEmpty)
    }
}
