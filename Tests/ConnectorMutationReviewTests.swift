import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// A connector write the agent staged is sent only after the user reviews it,
/// at every level for now: ASTRA learns of it only when it reads the task
/// folder after the run, so sending without asking would mean sending after
/// the turn, across every state the run can reach in between. Auto will send
/// it when the agent asks, in its own change (spec decision 15).
@Suite("Connector mutation review")
@MainActor
struct ConnectorMutationReviewTests {
    @Test("Every level leaves a staged write for review; nothing is sent at the run boundary")
    func everyLevelLeavesTheWriteForReview() throws {
        for level in [AgentPolicyLevel.review, .custom, .autonomous] {
            let fixture = try ConnectorReviewFixture()
            try fixture.stage(summary: "Login fails")
            fixture.crossBoundary(policyLevel: level)
            #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1, "\(level.rawValue)")
            #expect(ExternalActionPolicy.asksUser(for: .connectorMutation, level: level), "\(level.rawValue)")
            #expect(ExternalActionPolicy.asksUser(for: .githubReviewPublication, level: level), "\(level.rawValue)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Astra/Services/Runtime/RuntimeTurnSettlementService.swift", "Astra/Services/Runtime/RunBoundaryDiscovery.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("ConnectorMutationCoordinator"), "\(path) sends nothing")
        }
    }

    // The broker numbers a run's proposals across services and operations, so
    // the dock can show them in the order the agent proposed them.
    @Test("Staged proposals are numbered across operations, and a planted number is ignored")
    func stagedNumbersAreRunWideAndBounded() throws {
        let fixture = try ConnectorReviewFixture()
        try fixture.stage(summary: "Set the priority", operation: "update_issue", method: "PUT",
                          path: "/rest/api/2/issue/STAR-1", target: "STAR-1", body: ["fields": ["priority": ["name": "High"]]])
        try fixture.stage(summary: "Move it", operation: "transition_issue", method: "POST",
                          path: "/rest/api/2/issue/STAR-1/transitions", target: "STAR-1", body: ["transition": ["id": "21"]])
        let runID = fixture.run.id.uuidString
        let numbers = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
            .compactMap { ConnectorMutationStaging.stagedNumber(fileName: URL(fileURLWithPath: $0.stagedPayloadPath).lastPathComponent, runID: runID) }
        let staging = ConnectorMutationStaging.stagingDirectory(taskFolder: TaskWorkspaceAccess(task: fixture.task).taskFolder)
        let named = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .compactMap { ConnectorMutationStaging.stagedNumber(fileName: $0, runID: runID) }
        #expect(Set(named) == [1, 2], "update 1, transition 2: \(named) \(numbers)")
        fixture.crossBoundary(policyLevel: .review)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).map(\.summary)
            == ["Set the priority", "Move it"], "the dock shows them in the order they were proposed")
        #expect(ConnectorMutationStaging.stagedNumber(fileName: "jira-create_issue-RUN-7.json", runID: "RUN") == 7)
        #expect(ConnectorMutationStaging.stagedNumber(fileName: "jira-create_issue-RUN-\(Int.max).json", runID: "RUN") == nil)
        #expect(ConnectorMutationStaging.stagedNumber(fileName: "jira-create_issue-OTHER-7.json", runID: "RUN") == nil)
    }

    // The review can be open in more than one place; once a send has claimed
    // the proposal, a decline would sit beside the write it refuses.
    @Test("A proposal an in-flight send claimed cannot be declined")
    func claimedProposalCannotBeDeclined() async throws {
        let fixture = try ConnectorReviewFixture()
        let sender = RecordingConnectorSender(statusCode: 201, body: #"{"key":"STAR-1"}"#)
        try fixture.stage(summary: "First")
        fixture.crossBoundary(policyLevel: .review)
        let coordinator = fixture.coordinator(sender: sender)
        let pending = try #require(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).first)
        let opened = try coordinator.prepare(task: fixture.task, pending: pending)
        var declineError: ConnectorMutationCoordinatorError?
        sender.duringFirstSend = {
            do {
                try coordinator.decline(task: fixture.task, proposal: opened)
            } catch {
                declineError = error as? ConnectorMutationCoordinatorError
            }
        }

        _ = try await coordinator.send(task: fixture.task, proposal: opened)

        #expect(sender.count == 1)
        #expect(declineError == .alreadySent(opened.target))
        #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.declined })
    }

    // Auto allows a connector the run reached for only after a clean finish
    // (`BrokeredCredentialApprovalDiscovery`).
    @Test("A run finishes cleanly only without a cancel, failure, stop, error or budget overrun")
    func cleanFinish() {
        func clean(_ result: AgentProcessResult, cancelled: Bool = false, status: TaskStatus = .running,
                   agentReportedError: Bool = false, overBudget: Bool = false) -> Bool {
            RuntimeTurnSettlementService.finishedCleanly(result: result, cancelled: cancelled, taskStatus: status,
                agentReportedError: agentReportedError, overBudget: overBudget)
        }
        #expect(clean(AgentProcessResult(exitCode: 0)))
        #expect(clean(AgentProcessResult(exitCode: 143, terminatedAfterTerminalProgress: true)))
        #expect(!clean(AgentProcessResult(exitCode: 0), cancelled: true), "cancelled run")
        #expect(!clean(AgentProcessResult(exitCode: 0), status: .cancelled), "cancelled task")
        #expect(!clean(AgentProcessResult(exitCode: 1)), "provider failed")
        #expect(!clean(AgentProcessResult(exitCode: 0, timedOut: true)), "timed out")
        #expect(!clean(AgentProcessResult(exitCode: 0, policyViolation: true)), "policy violation")
        #expect(!clean(AgentProcessResult(exitCode: 0, policyApprovalRequired: true)), "approval pause")
        #expect(!clean(AgentProcessResult(exitCode: 0, runtimeStopReason: "no_semantic_progress")), "runtime stop")
        #expect(!clean(AgentProcessResult(exitCode: 0, maxTurnsExceeded: true)), "max turns")
        #expect(!clean(AgentProcessResult(exitCode: 0), agentReportedError: true), "provider reported an error, exit 0")
        #expect(!clean(AgentProcessResult(exitCode: 0), overBudget: true), "usage over a hard budget")
    }

    @Test("A clean finish reads the provider's own error and the hard budget from the checkpoint")
    func checkpointGateReadsTheCapturedVerdicts() {
        let task = AgentTask(title: "File a ticket", goal: "File a Jira ticket")
        func checkpoint(agentReportedError: Bool = false, mode: BudgetEnforcementMode = .hardStop,
                        budget: Int = 1_000, used: Int = 10) -> RuntimeTurnSettlementService.Checkpoint {
            .init(requestID: nil, result: AgentProcessResult(exitCode: 0), runtime: .codexCLI, phase: .run,
                executionPath: "/tmp", launchSnapshot: .init(task: task), permissionPolicy: .autonomous,
                sandboxEnforcement: .off, verifierRuntime: .init(runtime: .codexCLI, claudePath: "/bin/sh"),
                timeoutSeconds: 10, budgetEnforcementMode: mode.rawValue, effectiveTokenBudget: budget,
                tokensUsed: used, agentReportedError: agentReportedError, cancelled: false, failureDiagnostic: nil,
                approvedPlan: nil, chainedGoal: "", scheduleID: nil)
        }
        func clean(_ value: RuntimeTurnSettlementService.Checkpoint) -> Bool {
            RuntimeTurnSettlementService.finishedCleanly(checkpoint: value, taskStatus: .running)
        }
        #expect(clean(checkpoint()))
        #expect(!clean(checkpoint(agentReportedError: true)), "provider reported an error, exit 0")
        #expect(!clean(checkpoint(used: 2_000)), "usage over a hard budget")
        #expect(clean(checkpoint(mode: .warning, used: 2_000)), "a warning budget does not fail the run")
    }
}

@MainActor
private final class ConnectorReviewFixture {
    let container: ModelContainer
    let context: ModelContext
    let task: AgentTask
    let run: TaskRun
    let connector: Connector
    let workspaceRoot: URL

    init() throws {
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
        workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-connector-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Connector review", primaryPath: workspaceRoot.path)
        task = AgentTask(title: "File a ticket", goal: "File a Jira ticket")
        run = TaskRun(task: task)
        connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.auto.test", authMethod: "basic")
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        task.workspace = workspace
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        context.insert(connector)
        try context.save()
    }

    deinit { try? FileManager.default.removeItem(at: workspaceRoot) }

    func crossBoundary(policyLevel: AgentPolicyLevel) {
        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: task, run: run, modelContext: context, policyLevel: policyLevel
        )
    }

    func coordinator(sender: RecordingConnectorSender) -> ConnectorMutationCoordinator {
        ConnectorMutationCoordinator(
            modelContext: context,
            sender: sender,
            secretStore: ConnectorReviewSecretStore(),
            durableEventSave: { _, _, _, _ in }
        )
    }

    /// Stages through the broker's own writer, named after `stagingRunID` the
    /// way the broker names a file after the run that wrote it.
    func stage(
        summary: String,
        stagingRunID: String? = nil,
        operation: String = "create_issue",
        method: String = "POST",
        path: String = "/rest/api/2/issue",
        target: String = "STAR / Bug",
        body: [String: Any]? = nil
    ) throws {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: taskFolder, isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try ConnectorMutationStaging.stage(
            serviceType: "jira",
            operation: operation,
            connector: HostControlConnector(
                id: connector.id.uuidString,
                alias: "jira",
                envPrefix: "JIRA_JIRA",
                name: "Jira",
                serviceType: "jira",
                baseURL: "https://jira.auto.test",
                authMethod: "basic",
                env: [:],
                credentials: [:],
                config: [:]
            ),
            target: target,
            summary: summary,
            requestMethod: method,
            requestPath: path,
            body: body ?? ["fields": ["project": ["key": "STAR"], "issuetype": ["name": "Bug"], "summary": summary]],
            configuration: HostControlToolConfiguration(
                taskFolder: taskFolder,
                runID: stagingRunID ?? run.id.uuidString,
                connectorsJSON: "{\"connectors\":[]}",
                environment: [:]
            )
        )
    }
}

private final class RecordingConnectorSender: ConnectorMutationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var sentPaths: [String] = []
    let statusCode: Int
    let body: String
    /// Runs on the main actor during the first send, while it is in flight.
    var duringFirstSend: (@MainActor () -> Void)?

    init(statusCode: Int = 201, body: String = "{}") {
        self.statusCode = statusCode
        self.body = body
    }

    var count: Int { lock.withLock { sent } }
    var paths: [String] { lock.withLock { sentPaths } }

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        let first = lock.withLock {
            sent += 1
            sentPaths.append(request.url.path)
            return sent == 1
        }
        if first, let duringFirstSend {
            await MainActor.run { duringFirstSend() }
        }
        return ConnectorMutationHTTPResponse(statusCode: statusCode, body: body)
    }
}

private struct ConnectorReviewSecretStore: SecretStore {
    func load(key: String, entityID _: String) -> String? {
        ["JIRA_EMAIL": "user@example.com", "JIRA_API_TOKEN": "auto-token"][key]
    }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID: String) -> Bool { load(key: key, entityID: entityID) != nil }
}
