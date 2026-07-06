import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// ASTRA always rebuilds the authoritative follow-up prompt. Provider-native
/// continuation is optional and must be passed explicitly by the worker after
/// launch-signature safety checks; adapters never infer it from `task.sessionId`.
@Suite("Session resume contract")
@MainActor
struct SessionResumeTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-session-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("Adapter follow-up launch plans never infer provider-native resume")
    func adapterFollowUpsNeverInferProviderNativeResumeFlag() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Resume", primaryPath: root)
        context.insert(workspace)

        let priorSessionToken = "PRIOR_SESSION_DO_NOT_RESUME"
        let providerHome = (root as NSString).appendingPathComponent("provider-home")

        let cases: [(runtime: AgentRuntimeID, executablePath: String)] = [
            (.claudeCode, "/bin/claude"),
            (.copilotCLI, "/bin/copilot"),
            (.antigravityCLI, "/bin/agy")
        ]

        for runtimeCase in cases {
            let task = AgentTask(
                title: "Follow up",
                goal: "Continue the prior discussion",
                workspace: workspace,
                model: AgentRuntimeAdapterRegistry.defaultModel(for: runtimeCase.runtime),
                runtime: runtimeCase.runtime
            )
            task.sessionId = priorSessionToken
            context.insert(task)

            let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
                message: "Now extend what you said earlier.",
                task: task
            )
            let plan = AgentRuntimeAdapterRegistry
                .adapter(for: runtimeCase.runtime)
                .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                    prompt: prompt,
                    task: task,
                    workspacePath: workspace.primaryPath,
                    executablePath: runtimeCase.executablePath,
                    providerHomeDirectory: providerHome,
                    permissionPolicy: .restricted,
                    executionPolicy: .default,
                    permissionManifest: nil,
                    timeoutSeconds: 30
                ))

            #expect(
                !plan.arguments.contains("--resume"),
                "\(runtimeCase.runtime.rawValue) must not pass a native --resume flag without a vetted native continuation id."
            )
            #expect(
                !plan.arguments.contains { $0.contains(priorSessionToken) },
                "\(runtimeCase.runtime.rawValue) must not forward the prior session id to the CLI."
            )
        }
    }

    @Test("Follow-up prompt replays the goal, prior turn output, and the new message")
    func followUpPromptReplaysPriorTurnContextAndMessage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Replay", primaryPath: root)
        let task = AgentTask(title: "Replay", goal: "Investigate the cache layer", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "The cache uses an LRU policy with a 512 MB ceiling."
        run.completedAt = Date()
        context.insert(run)
        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "How does the cache evict entries?"
        )

        let followUp = "Given that, would an LFU policy reduce evictions?"
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: followUp, task: task)

        #expect(prompt.contains("Goal: Investigate the cache layer"))
        #expect(prompt.contains("LRU policy with a 512 MB ceiling"))
        #expect(prompt.contains(followUp))
    }

    @Test("Claude system init exposes the session id used for resume bookkeeping")
    func claudeSystemInitExposesSessionIdForResumeBookkeeping() {
        let systemInitLine = """
        {"type":"system","subtype":"init","cwd":"/tmp","session_id":"sess-42","model":"claude-sonnet-4-6"}
        """
        let events = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .parseProcessEvents(line: systemInitLine, parsesJSONLines: true)

        let sessionId: String? = events.compactMap { event -> String? in
            if case let .systemInit(_, sessionId) = event { return sessionId }
            return nil
        }.first

        #expect(sessionId == "sess-42")
    }
}
