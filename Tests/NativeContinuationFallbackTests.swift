import Foundation
import SwiftData
import SQLite3
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// A resumed provider session that is gone must degrade to the history-carrying
/// prompt, not to a launch that silently starts over with a shorter one.
@Suite("Native continuation fallback")
@MainActor
struct NativeContinuationFallbackTests {
    private func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "native-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    private func touch(_ path: String, directory: Bool = false) throws {
        if directory {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: Data())
        }
    }

    // MARK: Provider session store

    @Test("Antigravity reads its store from the configured provider home, else the user home")
    func antigravityHomeResolution() throws {
        let userHome = try makeHome()
        let providerHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: userHome)
            try? FileManager.default.removeItem(atPath: providerHome)
        }
        try touch("\(providerHome)/.gemini/antigravity-cli/conversations/conv-1.db")

        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .antigravityCLI, sessionID: "conv-1", providerHomeDirectory: providerHome, userHome: userHome
        ))
        // Without the provider home configured it looks under the user home, where it is absent.
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .antigravityCLI, sessionID: "conv-1", userHome: userHome, environment: [:]
        ))
        try touch("\(userHome)/.gemini/antigravity-cli/conversations/conv-2.db")
        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .antigravityCLI, sessionID: "conv-2", userHome: userHome, environment: [:]
        ))
    }

    @Test("With no provider home, Antigravity follows a launch-scoped HOME")
    func antigravityFollowsTheLaunchHome() throws {
        let userHome = try makeHome()
        let skillHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: userHome)
            try? FileManager.default.removeItem(atPath: skillHome)
        }
        try touch("\(skillHome)/.gemini/antigravity-cli/conversations/conv-s.db")

        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .antigravityCLI, sessionID: "conv-s", userHome: userHome, environment: ["HOME": skillHome]
        ))
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .antigravityCLI, sessionID: "conv-s", userHome: userHome, environment: [:]
        ))
        // A configured provider home still wins over the launch HOME.
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .antigravityCLI, sessionID: "conv-s", providerHomeDirectory: userHome,
            userHome: userHome, environment: ["HOME": skillHome]
        ))
    }

    @Test("Copilot session is a directory under session-state")
    func copilotSessionLookup() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try touch("\(home)/.copilot/session-state/sess-1", directory: true)

        #expect(ProviderNativeSessionStore.sessionExists(runtime: .copilotCLI, sessionID: "sess-1", userHome: home))
        #expect(!ProviderNativeSessionStore.sessionExists(runtime: .copilotCLI, sessionID: "sess-2", userHome: home))
    }

    @Test("Cursor chat is found under whichever workspace hash directory holds it")
    func cursorChatLookup() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try touch("\(home)/.cursor/chats/aaaa/other-chat", directory: true)
        try touch("\(home)/.cursor/chats/bbbb/chat-1", directory: true)

        #expect(ProviderNativeSessionStore.sessionExists(runtime: .cursorCLI, sessionID: "chat-1", userHome: home, environment: [:]))
        #expect(!ProviderNativeSessionStore.sessionExists(runtime: .cursorCLI, sessionID: "chat-2", userHome: home, environment: [:]))
    }

    @Test("Cursor with no chats directory at all reads as missing")
    func cursorWithoutStore() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(!ProviderNativeSessionStore.sessionExists(runtime: .cursorCLI, sessionID: "chat-1", userHome: home, environment: [:]))
    }

    @Test("Cursor follows a launch-scoped HOME")
    func cursorFollowsTheLaunchHome() throws {
        let userHome = try makeHome()
        let skillHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: userHome)
            try? FileManager.default.removeItem(atPath: skillHome)
        }
        try touch("\(skillHome)/.cursor/chats/h/chat-s", directory: true)

        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .cursorCLI, sessionID: "chat-s", userHome: userHome, environment: ["HOME": skillHome]
        ))
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .cursorCLI, sessionID: "chat-s", userHome: userHome, environment: [:]
        ))
    }

    @Test("OPENCODE_DB points the lookup at another database: absolute as given, relative to OpenCode's data directory")
    func openCodeDatabaseOverride() throws {
        let userHome = try makeHome()
        let elsewhere = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: userHome)
            try? FileManager.default.removeItem(atPath: elsewhere)
        }
        try makeOpenCodeDatabase(at: "\(userHome)/.local/share/opencode/opencode.db", sessionIDs: ["ses_default"])
        try makeOpenCodeDatabase(at: "\(elsewhere)/alt.db", sessionIDs: ["ses_absolute"])
        try makeOpenCodeDatabase(at: "\(userHome)/.local/share/opencode/rel.db", sessionIDs: ["ses_relative"])

        func exists(_ id: String, _ environment: [String: String]) -> Bool {
            ProviderNativeSessionStore.sessionExists(
                runtime: .openCodeCLI, sessionID: id, userHome: userHome, environment: environment
            )
        }
        #expect(exists("ses_absolute", ["OPENCODE_DB": "\(elsewhere)/alt.db"]))
        #expect(!exists("ses_default", ["OPENCODE_DB": "\(elsewhere)/alt.db"]))
        #expect(exists("ses_relative", ["OPENCODE_DB": "rel.db"]))
        #expect(exists("ses_default", [:]))
    }

    @Test("OpenCode session is a row of its SQLite database, under XDG_DATA_HOME when set")
    func openCodeSessionLookup() throws {
        let userHome = try makeHome()
        let dataHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: userHome)
            try? FileManager.default.removeItem(atPath: dataHome)
        }
        try makeOpenCodeDatabase(at: "\(dataHome)/opencode/opencode.db", sessionIDs: ["ses_known"])

        let configured = ["XDG_DATA_HOME": dataHome]
        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_known", userHome: userHome, environment: configured
        ))
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_other", userHome: userHome, environment: configured
        ))
        // Without XDG_DATA_HOME it looks under ~/.local/share, where there is no database.
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_known", userHome: userHome, environment: [:]
        ))
        try makeOpenCodeDatabase(at: "\(userHome)/.local/share/opencode/opencode.db", sessionIDs: ["ses_home"])
        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_home", userHome: userHome, environment: [:]
        ))
    }

    @Test("A launch-scoped HOME with no XDG_DATA_HOME moves OpenCode's database with it")
    func openCodeFollowsTheLaunchHome() throws {
        let userHome = try makeHome()
        let skillHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: userHome)
            try? FileManager.default.removeItem(atPath: skillHome)
        }
        try makeOpenCodeDatabase(at: "\(skillHome)/.local/share/opencode/opencode.db", sessionIDs: ["ses_scoped"])

        #expect(ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_scoped", userHome: userHome, environment: ["HOME": skillHome]
        ))
        // The user's own home has no such database.
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_scoped", userHome: userHome, environment: [:]
        ))
    }

    @Test("An OpenCode database that cannot be read reads as missing, never as a crash")
    func openCodeUnreadableDatabase() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try touch("\(home)/.local/share/opencode/opencode.db")
        FileManager.default.createFile(
            atPath: "\(home)/.local/share/opencode/opencode.db", contents: Data("not a database".utf8)
        )
        #expect(!ProviderNativeSessionStore.sessionExists(
            runtime: .openCodeCLI, sessionID: "ses_known", userHome: home, environment: [:]
        ))
    }

    private func makeOpenCodeDatabase(at path: String, sessionIDs: [String]) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        let inserts = sessionIDs.map { "INSERT INTO session VALUES ('\($0)');" }.joined()
        guard sqlite3_exec(database, "CREATE TABLE session (id text PRIMARY KEY);\(inserts)", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @Test("A session id that is not a plain token never reaches the filesystem")
    func traversalIsRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try touch("\(home)/.copilot/session-state/real", directory: true)

        for hostile in ["../session-state/real", "a/b", "", " ", "-leading", "real\u{0}", String(repeating: "a", count: 129)] {
            #expect(!ProviderNativeSessionStore.sessionExists(runtime: .copilotCLI, sessionID: hostile, userHome: home))
        }
    }

    @Test("Runtimes that fail loudly on a stale id are not second-guessed")
    func otherRuntimesPassThrough() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for runtime in [AgentRuntimeID.claudeCode, .codexCLI] {
            #expect(!ProviderNativeSessionStore.verifiesBeforeResume(runtime))
            #expect(ProviderNativeSessionStore.sessionExists(runtime: runtime, sessionID: "anything", userHome: home))
        }
    }

    // MARK: Worker

    @Test("A follow-up whose Copilot session is gone launches without --resume")
    func workerFallsBackWhenProviderSessionIsMissing() async throws {
        let testDir = "/tmp/native_fallback_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Native Fallback", primaryPath: testDir)
        context.insert(workspace)
        let task = AgentTask(
            title: "Copilot follow-up",
            goal: "Carry on after the session was cleaned up",
            workspace: workspace,
            model: CopilotCLIRuntime.defaultModel,
            runtime: .copilotCLI
        )
        // An id no Copilot install has: the store check must reject it.
        task.sessionId = "astra-test-missing-\(UUID().uuidString)"
        task.status = .completed
        context.insert(task)
        let priorRun = TaskRun(task: task)
        priorRun.status = .completed
        priorRun.stopReason = "completed"
        context.insert(priorRun)
        try context.save()

        let runner = ContinuationRecordingRunner()
        let worker = AgentRuntimeWorker(
            processRunner: runner,
            providerSettingsSnapshotProvider: { .headlessScenario }
        )
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.defaultRuntimeID = .copilotCLI
        worker.setExecutablePath("/bin/sh", for: .copilotCLI)

        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(task: task, message: "Pick up where we left off.", modelContext: context) { _ in }

        #expect(runner.nativeSessionIDs.count == 1)
        #expect(runner.nativeSessionIDs.first == .some(nil))
        #expect(task.sessionId == nil)
        let prompt = try #require(runner.prompts.first)
        #expect(prompt.contains("Pick up where we left off."))
        // Pin the reason: a missing launch signature would also skip, and must not pass for this.
        AppLogger.flushForTesting()
        #expect(AppLogger.entries.contains {
            $0.taskID == task.id && $0.message.contains("native_continuation_skip_reason=provider_session_missing")
        })
    }
}

private final class ContinuationRecordingRunner: AgentRuntimeProcessRunning {
    private(set) var nativeSessionIDs: [String?] = []
    private(set) var prompts: [String] = []

    func cancel() {}
    func isHostControlBrokerAvailable() -> Bool { true }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        phase: RunPhase,
        contextText: String,
        nativeContinuationSessionID: String?,
        runID: UUID?,
        launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?,
        runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        nativeSessionIDs.append(nativeContinuationSessionID)
        prompts.append(prompt)
        return AgentProcessResult(exitCode: 0)
    }
}
