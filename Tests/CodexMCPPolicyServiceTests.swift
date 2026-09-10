import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The verbatim shape `codex mcp list --json` returned on the machine that hit
/// this in production, with ASTRA's own server definition injected by the probe.
private let disabledByPolicyResponse = #"""
[
  {
    "name": "astra_host",
    "enabled": false,
    "disabled_reason": "requirements (enterprise-managed requirements Baseline (regulated-workspace-default-fallback))",
    "transport": {"type": "stdio", "command": "/tmp/astra-host-control", "args": []},
    "startup_timeout_sec": 10.0,
    "tool_timeout_sec": 60.0,
    "auth_status": "unsupported"
  },
  {
    "name": "some_other_server",
    "enabled": false,
    "disabled_reason": "requirements (enterprise-managed requirements Baseline (regulated-workspace-default-fallback))",
    "transport": {"type": "stdio", "command": "/usr/bin/true", "args": []}
  }
]
"""#

@Suite("Codex MCP policy preflight")
struct CodexMCPPolicyProbeTests {
    @Test("A policy that switches every MCP server off is read as a refusal, and the policy is named")
    func parsesPolicyRefusal() throws {
        let result = try CodexMCPListPolicyProbe.parse(
            Data(disabledByPolicyResponse.utf8),
            serverID: "astra_host"
        )
        #expect(result.serverEnabled == false)
        #expect(result.disabledReason?.contains("regulated-workspace-default-fallback") == true)
        // The name an administrator can act on, without the provider's
        // parenthetical internals reaching the user.
        #expect(CodexMCPPolicyService.policyName(fromDisabledReason: result.disabledReason) == "Baseline")
    }

    @Test("An unnamed refusal still blocks, and no provider wording is invented")
    func unnamedPolicyRefusal() throws {
        let response = #"[{"name":"astra_host","enabled":false,"disabled_reason":"blocked by administrator"}]"#
        let result = try CodexMCPListPolicyProbe.parse(Data(response.utf8), serverID: "astra_host")
        #expect(result.serverEnabled == false)
        #expect(CodexMCPPolicyService.policyName(fromDisabledReason: result.disabledReason) == nil)
        #expect(RuntimeProviderMCPPolicy.serversDisabled(policyName: nil).refusesServers)
    }

    @Test("An accepted server reports permission and carries no refusal text")
    func parsesPermission() throws {
        let response = #"[{"name":"astra_host","enabled":true,"disabled_reason":null}]"#
        let result = try CodexMCPListPolicyProbe.parse(Data(response.utf8), serverID: "astra_host")
        #expect(result == CodexMCPPolicyProbeResult(serverEnabled: true, disabledReason: nil))
    }

    @Test("A response ASTRA cannot read is an error, never a silent verdict", arguments: [
        // No `enabled` field: neither "permitted" nor "disabled" is an answer.
        #"[{"name":"astra_host","disabled_reason":"who knows"}]"#,
        // The probe's own server is absent, so nothing was actually asked.
        #"[{"name":"something_else","enabled":true}]"#,
        "not json at all",
        "[]"
    ])
    func rejectsUnreadableResponses(response: String) {
        #expect(throws: CodexMCPPolicyProbeError.self) {
            try CodexMCPListPolicyProbe.parse(Data(response.utf8), serverID: "astra_host")
        }
    }

    @Test("The probe asks about the exact server ASTRA injects, and tolerates a banner ahead of the JSON")
    func realTransportAsksTheRightQuestion() async throws {
        let fixture = try makeExecutable(#"""
        case "$1$2$3" in mcplist--json) ;; *) exit 21;; esac
        case "$4" in -c) ;; *) exit 22;; esac
        case "$5" in 'mcp_servers.astra_host={command="/opt/astra host-control"}') ;; *) exit 23;; esac
        printf '%s\n' 'Reading enterprise configuration...'
        printf '%s\n' '[{"name":"astra_host","enabled":false,"disabled_reason":"requirements (enterprise-managed requirements Baseline (x))"}]'
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let result = try await CodexMCPListPolicyProbe(timeout: 5).probe(
            serverID: "astra_host",
            command: "/opt/astra host-control",
            executablePath: fixture.path,
            environment: [:]
        )
        #expect(result.serverEnabled == false)
    }

    @Test("A path with a quote in it cannot reshape the config override")
    func escapesTheServerCommand() {
        #expect(CodexMCPListPolicyProbe.tomlString(#"/a/b"c\d"#) == #""/a/b\"c\\d""#)
    }

    @Test("A hung CLI is killed at the deadline instead of holding up a launch")
    func boundedProbeLifetime() async throws {
        let fixture = try makeExecutable("sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        await #expect(throws: CodexMCPPolicyProbeError.timedOut) {
            try await CodexMCPListPolicyProbe(timeout: 0.2).probe(
                serverID: "astra_host", command: "/bin/true",
                executablePath: fixture.path, environment: [:]
            )
        }
    }

    @Test("A missing CLI is an unavailable probe, not a refusal")
    func missingExecutable() async {
        await #expect(throws: CodexMCPPolicyProbeError.unavailableExecutable) {
            try await CodexMCPListPolicyProbe(timeout: 2).probe(
                serverID: "astra_host", command: "/bin/true",
                executablePath: "/nonexistent/astra-test-codex", environment: [:]
            )
        }
    }

    private func makeExecutable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-mcp-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

@Suite("Codex MCP policy cache")
struct CodexMCPPolicyServiceTests {
    @Test("A refusal is cached with the policy's name and read back by the launch path")
    func cachesRefusal() async throws {
        let name = "CodexMCPPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        let service = CodexMCPPolicyService(probe: StubCodexMCPPolicyProbe(
            result: CodexMCPPolicyProbeResult(
                serverEnabled: false,
                disabledReason: "requirements (enterprise-managed requirements Baseline (regulated-workspace-default-fallback))"
            )
        ))
        let policy = await service.refreshAndPersist(
            executablePath: " /configured/codex ", homeDirectory: "/test/codex-home",
            defaults: defaults, now: now
        )
        #expect(policy == .serversDisabled(policyName: "Baseline"))
        #expect(CodexMCPPolicyService.cachedPolicy(defaults: defaults, now: now) == .serversDisabled(policyName: "Baseline"))
        #expect(CodexMCPPolicyService.isCacheFresh(defaults: defaults, now: now))
        // Codex re-pulls its own bundle hourly; an answer older than that has
        // to be re-asked rather than trusted.
        let stale = now.addingTimeInterval(CodexMCPPolicyService.cacheLifetime + 1)
        #expect(CodexMCPPolicyService.cachedPolicy(defaults: defaults, now: stale) == .unknown)
        #expect(!CodexMCPPolicyService.isCacheFresh(defaults: defaults, now: stale))
    }

    @Test("The probe is asked about ASTRA's real server, using the configured CLI")
    func asksAboutTheRealServer() async throws {
        let name = "CodexMCPPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let probe = StubCodexMCPPolicyProbe(result: CodexMCPPolicyProbeResult(serverEnabled: true, disabledReason: nil))
        let service = CodexMCPPolicyService(probe: probe, detectExecutable: { "/detected/codex" })
        #expect(await service.refreshAndPersist(executablePath: "  ", homeDirectory: "/home", defaults: defaults) == .permitted)
        #expect(await probe.serverID == HostControlPlaneMCPProjection.serverID)
        #expect(await probe.command == HostControlBrokerReadiness.helperPath)
        #expect(await probe.executablePath == "/detected/codex")
        #expect(await probe.home == "/home")
    }

    @Test("A probe that fails learns nothing: the answer is unknown and a known refusal survives")
    func failsOpenWithoutClobberingTheCache() async throws {
        let name = "CodexMCPPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        _ = await CodexMCPPolicyService(probe: StubCodexMCPPolicyProbe(
            result: CodexMCPPolicyProbeResult(serverEnabled: false, disabledReason: "requirements Baseline (x)")
        )).refreshAndPersist(executablePath: "/codex", defaults: defaults, now: now)
        let cached = defaults.string(forKey: AppStorageKeys.runtimeMCPPolicyKey(for: .codexCLI))

        for error in [CodexMCPPolicyProbeError.timedOut, .unavailableExecutable, .invalidResponse] {
            let service = CodexMCPPolicyService(probe: StubCodexMCPPolicyProbe(error: error))
            #expect(await service.refreshAndPersist(executablePath: "/codex", defaults: defaults, now: now) == .unknown)
            #expect(defaults.string(forKey: AppStorageKeys.runtimeMCPPolicyKey(for: .codexCLI)) == cached)
        }
        #expect(CodexMCPPolicyService.cachedPolicy(defaults: defaults, now: now).refusesServers)
    }

    @Test("With nothing cached, the launch path sees no opinion at all")
    func emptyCacheIsUnknown() throws {
        let name = "CodexMCPPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CodexMCPPolicyService.cachedPolicy(defaults: defaults) == .unknown)
        #expect(!CodexMCPPolicyService.cachedPolicy(defaults: defaults).refusesServers)
    }

    @Test("A fresh cache is answered without touching the CLI")
    func freshCacheSkipsTheProbe() async throws {
        let name = "CodexMCPPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        let probe = StubCodexMCPPolicyProbe(result: CodexMCPPolicyProbeResult(serverEnabled: false, disabledReason: "requirements Baseline (x)"))
        let service = CodexMCPPolicyService(probe: probe)
        _ = await service.policy(executablePath: "/codex", defaults: defaults, now: now)
        _ = await service.policy(executablePath: "/codex", defaults: defaults, now: now.addingTimeInterval(60))
        #expect(await probe.callCount == 1)
        _ = await service.policy(
            executablePath: "/codex", defaults: defaults,
            now: now.addingTimeInterval(CodexMCPPolicyService.cacheLifetime + 1)
        )
        #expect(await probe.callCount == 2)
    }

    /// The shared domain inside a test process holds whoever's laptop is
    /// running the suite, and their employer's Codex policy is a real answer:
    /// caching it there made six unrelated suites fail on this machine and
    /// pass on a colleague's. Tests get `.unknown` — the behavior that
    /// predates this check — and the shared domain is neither read nor written.
    @Test("A test process never asks the real CLI, and never writes to the shared defaults")
    func testProcessesAreClosedOutOfTheSharedDomain() async throws {
        let key = AppStorageKeys.runtimeMCPPolicyKey(for: .codexCLI)
        #expect(!CodexMCPPolicyService.answersAllowed(in: .standard))
        let probe = StubCodexMCPPolicyProbe(
            result: CodexMCPPolicyProbeResult(serverEnabled: false, disabledReason: "requirements Baseline (x)")
        )
        let policy = await CodexMCPPolicyService(probe: probe).policy(executablePath: "/codex")
        #expect(policy == .unknown)
        #expect(await probe.callCount == 0)
        #expect(UserDefaults.standard.string(forKey: key) == nil)
        #expect(CodexMCPPolicyService.cachedPolicy() == .unknown)
        #expect(!CodexMCPPolicyService.isCacheFresh())
    }
}

@Suite("Runtime capabilities under a provider MCP refusal")
struct ProviderMCPRefusalCapabilityTests {
    private func codexProfile(_ policy: RuntimeProviderMCPPolicy) -> AgentRuntimeCapabilityProfile {
        AgentRuntimeCapabilityProfile.defaultProfile(for: .codexCLI, providerMCPPolicy: policy)
    }

    @Test("A refused runtime keeps its delivery mechanism but stops advertising the route")
    func refusalClosesTheRoute() {
        let refused = codexProfile(.serversDisabled(policyName: "Baseline"))
        // ASTRA's side of the contract is unchanged — the provider's is not.
        #expect(refused.hasTaskScopedMCPDeliveryMechanism)
        #expect(!refused.supportsTaskScopedMCPDelivery)
        #expect(!refused.canDeliverHostControlPlaneMCP)
        #expect(!refused.canDeliverHostControlPlane)
        #expect(!refused.canDeliverDockerWorkspaceShellMCP)
        #expect(refused.observedEvidence.contains("codex-mcp-list:servers-disabled(Baseline)"))
        // Browser control survives: it has a shell transport that is not MCP.
        #expect(refused.canUseBrowserBridgeTransport)
    }

    @Test("An unknown or permitted policy leaves the profile exactly as it was")
    func unknownPolicyChangesNothing() {
        let baseline = AgentRuntimeCapabilityProfile.defaultProfile(for: .codexCLI)
        #expect(codexProfile(.unknown) == baseline)
        #expect(codexProfile(.permitted).supportsTaskScopedMCPDelivery)
        #expect(baseline.supportsTaskScopedMCPDelivery)
        #expect(AgentRuntimeCapabilityProfile.defaultProfile(for: .claudeCode).supportsTaskScopedMCPDelivery)
    }

    @Test("A connector turn is blocked with the provider named, and Claude Code offered")
    func connectorTurnIsBlocked() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["jira"], requiresDockerWorkspaceShell: false, requiresBrowserControl: false
        )
        let found = TaskRuntimeCompatibilityService.incompatibilities(
            runtime: .codexCLI,
            requirements: requirements,
            profile: codexProfile(.serversDisabled(policyName: "Baseline")),
            isRuntimeUsable: true
        )
        #expect(found == [.providerMCPServersDisabled(policyName: "Baseline")])

        let block = TaskRuntimeCompatibilityService.launchBlock(
            for: .codexCLI, requirements: requirements,
            incompatibilities: found, suggestedRuntime: .claudeCode
        )
        #expect(block.message == #"Codex CLI cannot use ASTRA's connectors: your organization's Codex policy ("Baseline") disables all MCP servers."#)
        #expect(block.remediation == "Run this task on Claude Code, or ask your Codex administrator to allow ASTRA's MCP server.")
        #expect(block.suggestedRuntime == .claudeCode)
        // No provider debug text, and nothing that reads as a missing ASTRA feature.
        #expect(!block.message.contains("regulated-workspace-default-fallback"))
        #expect(!block.message.contains("cannot satisfy"))
    }

    @Test("Claude Code still satisfies the same turn, so there is somewhere to send it")
    func claudeCodeRemainsCompatible() {
        let found = TaskRuntimeCompatibilityService.incompatibilities(
            runtime: .claudeCode,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: ["jira"], requiresDockerWorkspaceShell: false, requiresBrowserControl: false
            ),
            profile: AgentRuntimeCapabilityProfile.defaultProfile(for: .claudeCode),
            isRuntimeUsable: true
        )
        #expect(found.isEmpty)
    }

    @Test("A turn that needs no MCP route is not blocked by the refusal", arguments: [
        (tools: [String](), docker: false, browser: false),
        (tools: [], docker: false, browser: true)
    ])
    func nonConnectorTurnsStillRun(scenario: (tools: [String], docker: Bool, browser: Bool)) {
        let found = TaskRuntimeCompatibilityService.incompatibilities(
            runtime: .codexCLI,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: scenario.tools,
                requiresDockerWorkspaceShell: scenario.docker,
                requiresBrowserControl: scenario.browser
            ),
            profile: codexProfile(.serversDisabled(policyName: "Baseline")),
            isRuntimeUsable: true
        )
        #expect(found.isEmpty)
    }

    @Test("An unnamed policy is blocked too, and the wording does not invent a name")
    func unnamedPolicyBlocksWithHonestWording() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [], requiresDockerWorkspaceShell: true, requiresBrowserControl: false
        )
        let found = TaskRuntimeCompatibilityService.incompatibilities(
            runtime: .codexCLI, requirements: requirements,
            profile: codexProfile(.serversDisabled(policyName: nil)), isRuntimeUsable: true
        )
        #expect(found == [.providerMCPServersDisabled(policyName: nil)])
        let block = TaskRuntimeCompatibilityService.launchBlock(
            for: .codexCLI, requirements: requirements, incompatibilities: found, suggestedRuntime: nil
        )
        #expect(block.message == "Codex CLI cannot use ASTRA's connectors: your organization's Codex policy disables all MCP servers.")
        #expect(block.remediation == "Ask your Codex administrator to allow ASTRA's MCP server.")
    }
}

@Suite("A run the agent said failed is not a completed run")
@MainActor
struct AgentReportedErrorOutcomeTests {
    @Test("A provider failure frame is remembered for the run that reported it")
    func failureFrameIsRemembered() throws {
        let container = try makeAgentReportedErrorContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Connectors", goal: "File a Jira ticket")
        let run = TaskRun(task: task)
        let other = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        context.insert(other)
        let recordingState = AgentEventRecordingState()
        #expect(!recordingState.agentReportedError(for: run))

        AgentEventRecorder.recordClaudeEvent(
            .failed(message: "broker unavailable"),
            to: task, run: run, modelContext: context, recordingState: recordingState
        )
        #expect(recordingState.agentReportedError(for: run))
        #expect(!recordingState.agentReportedError(for: other))
    }

    @Test("A clean exit after an agent-reported failure is filed as failed, not completed")
    func agentReportedErrorFailsTheRun() throws {
        let container = try makeAgentReportedErrorContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Connectors", goal: "File a Jira ticket")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        // What the worker had already written for a zero exit code.
        run.status = .completed
        run.typedStopReason = .completed
        run.exitCode = 0

        let blocked = AgentRuntimeCompletionValidation.applyAgentReportedErrorIfNeeded(
            task: task, run: run, modelContext: context, agentReportedError: true
        )
        #expect(blocked)
        #expect(run.status == .failed)
        #expect(run.typedStopReason == .agentReportedError)
        #expect(task.status == .failed)
    }

    @Test("A run with no reported failure is left completely alone")
    func cleanRunIsUntouched() throws {
        let container = try makeAgentReportedErrorContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Connectors", goal: "File a Jira ticket")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        run.status = .completed
        run.typedStopReason = .completed
        let statusBefore = task.status

        let blocked = AgentRuntimeCompletionValidation.applyAgentReportedErrorIfNeeded(
            task: task, run: run, modelContext: context, agentReportedError: false
        )
        #expect(!blocked)
        #expect(run.status == .completed)
        #expect(run.typedStopReason == .completed)
        #expect(task.status == statusBefore)
    }
}

private func makeAgentReportedErrorContainer() throws -> ModelContainer {
    try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
}

private actor StubCodexMCPPolicyProbe: CodexMCPPolicyProbing {
    let result: CodexMCPPolicyProbeResult?
    let error: (any Error)?
    private(set) var serverID: String?
    private(set) var command: String?
    private(set) var executablePath: String?
    private(set) var home: String?
    private(set) var callCount = 0

    init(result: CodexMCPPolicyProbeResult? = nil, error: (any Error)? = nil) {
        self.result = result
        self.error = error
    }

    func probe(
        serverID: String,
        command: String,
        executablePath: String,
        environment: [String: String]
    ) async throws -> CodexMCPPolicyProbeResult {
        self.serverID = serverID
        self.command = command
        self.executablePath = executablePath
        self.home = environment["CODEX_HOME"]
        callCount += 1
        if let error { throw error }
        return result ?? CodexMCPPolicyProbeResult(serverEnabled: true, disabledReason: nil)
    }
}
