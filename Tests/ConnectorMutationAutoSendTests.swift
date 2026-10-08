import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// Auto asks nothing, so a Jira write an Auto run staged is sent at the run
/// boundary without the review sheet — through the same coordinator checks an
/// approved send uses — and the chat records it. Ask and Custom keep the sheet.
@Suite("Connector mutation auto send")
@MainActor
struct ConnectorMutationAutoSendTests {
    @Test("Auto sends what the run staged, once, and records that Auto sent it")
    func autoSendsAndRecords() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender(body: #"{"key":"STAR-901"}"#)

        try fixture.stage(summary: "Age filter missing")

        await fixture.crossBoundaryAndSettle(policyLevel: .autonomous, sender: sender)

        #expect(sender.count == 1)
        let receiptEvent = try #require(fixture.task.events.first { $0.type == ConnectorMutationEventTypes.receipt })
        let record = try #require(ExternalActionRecordProjection.record(
            type: receiptEvent.type,
            payload: receiptEvent.payload,
            eventID: receiptEvent.id,
            timestamp: receiptEvent.timestamp
        ))
        #expect(record.authorization == .autoPolicy)
        #expect(record.title == "Created STAR-901")
        #expect(record.url?.absoluteString == "https://jira.auto.test/browse/STAR-901")
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    @Test("Ask and Custom send nothing; the proposal waits for review")
    func askAndCustomSendNothing() async throws {
        for level in [AgentPolicyLevel.review, .custom] {
            let fixture = try AutoSendFixture()
            let sender = AutoSendRecordingSender()
            try fixture.stage(summary: "Age filter missing")

            await fixture.crossBoundaryAndSettle(policyLevel: level, sender: sender)

            #expect(sender.count == 0, "\(level.rawValue)")
            #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.receipt })
            #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
        }
    }

    @Test("Auto does not send a proposal another run staged")
    func autoLeavesAnotherRunsProposal() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender()
        try fixture.stage(summary: "Staged by an earlier Ask run", stagingRunID: UUID().uuidString)

        await fixture.crossBoundaryAndSettle(policyLevel: .autonomous, sender: sender)

        #expect(sender.count == 0)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
    }

    // The broker numbers each service-and-operation pair on its own, so file
    // names sort a transition (`transition_issue`) ahead of an update staged
    // before it. Auto sends in the order the agent proposed.
    @Test("Auto sends a run's writes in the order they were staged, across operation types")
    func autoKeepsStagingOrderAcrossOperations() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender(statusCode: 204)
        try fixture.stage(
            summary: "Set the priority first",
            operation: "update_issue", method: "PUT", path: "/rest/api/2/issue/STAR-1",
            target: "STAR-1", body: ["fields": ["priority": ["name": "High"]]]
        )
        try fixture.stage(
            summary: "Then move it to In Progress",
            operation: "transition_issue", method: "POST", path: "/rest/api/2/issue/STAR-1/transitions",
            target: "STAR-1", body: ["transition": ["id": "21"]]
        )

        await fixture.crossBoundaryAndSettle(policyLevel: .autonomous, sender: sender)

        #expect(sender.paths == ["/rest/api/2/issue/STAR-1", "/rest/api/2/issue/STAR-1/transitions"])
    }

    // Auto's writes leave the machine only during settlement: after the run's
    // provider result is captured and the settlement marker is saved. An exit
    // before that lets recovery send what is still pending; an exit during it
    // is reconciled instead of replayed. Source-shape pin: the worker and the
    // settlement pipeline are too entangled to drive here.
    @Test("Auto sends connector writes only during settlement, after the result is captured")
    func autoSendsOnlyDuringSettlement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let boundary = try source("Astra/Services/Runtime/RunBoundaryDiscovery.swift")
        #expect(!boundary.contains("ConnectorMutationAutoSend.send"), "the run boundary must not leave the machine")

        let settlement = try source("Astra/Services/Runtime/RuntimeTurnSettlementService.swift")
        let started = try #require(settlement.range(of: "operation: \"runtime_settlement_started\""))
        let send = try #require(settlement.range(of: "ConnectorMutationAutoSend.sendPendingMutations("))
        let outcome = try #require(settlement.range(of: "RuntimeTurnOutcomeService.apply("))
        #expect(started.upperBound < send.lowerBound, "send only after the settlement marker is saved")
        #expect(send.upperBound < outcome.lowerBound, "send before the outcome reads receipts")

        let worker = try source("Astra/Services/Runtime/AgentRuntimeWorker.swift")
        let capture = try #require(worker.range(of: "RuntimeTurnSettlementService.capture("))
        let settle = try #require(worker.range(of: "RuntimeTurnSettlementService.settle("))
        #expect(capture.upperBound < settle.lowerBound)
    }

    // Cancelling is the user saying stop, and a run that did not finish did not
    // finish the work its staged writes belong to: neither may still send.
    @Test("Auto sends only for a run that finished cleanly")
    func autoSendsOnlyForACleanFinish() {
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

        let settlement = (try? String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/Services/Runtime/RuntimeTurnSettlementService.swift"),
            encoding: .utf8
        )) ?? ""
        let gate = settlement.range(of: "if finishedCleanly(checkpoint: checkpoint, taskStatus: task.status) {")
        let send = settlement.range(of: "ConnectorMutationAutoSend.sendPendingMutations(")
        #expect(gate != nil && send != nil && gate!.upperBound < send!.lowerBound, "settlement gates the send")
    }

    // The outcome fails a run whose provider reported an error but exited 0
    // (Codex does), and one whose usage ran over a hard budget. The send gate
    // reads the same captured verdicts, so Auto never writes for either.
    @Test("The settlement gate reads the provider's own error and the hard budget from the checkpoint")
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

    @Test("Auto stops at the first write that does not go out and says so")
    func autoStopsAtTheFirstRefusal() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender(statusCode: 400, body: #"{"errorMessages":["Field 'priority' is required"]}"#)
        try fixture.stage(summary: "The epic")
        try fixture.stage(summary: "A story under the epic")

        await fixture.crossBoundaryAndSettle(policyLevel: .autonomous, sender: sender)

        #expect(sender.count == 1, "the dependent proposal is not sent after its parent failed")
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 2)
        let notice = try #require(fixture.task.events.first { $0.payload.hasPrefix("Auto could not send") }?.payload)
        #expect(notice.contains("The epic"))
        #expect(notice.contains("It and 1 more are waiting for your review."))
    }
}

@MainActor
private final class AutoSendFixture {
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
            .appendingPathComponent("astra-connector-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Auto send", primaryPath: workspaceRoot.path)
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

    /// What a finished run goes through: discovery at the run boundary, then
    /// the settlement step that may send.
    func crossBoundaryAndSettle(policyLevel: AgentPolicyLevel, sender: AutoSendRecordingSender) async {
        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: task, run: run, modelContext: context, policyLevel: policyLevel
        )
        await ConnectorMutationAutoSend.sendPendingMutations(
            task: task, run: run, policyLevel: policyLevel, modelContext: context,
            coordinator: coordinator(sender: sender)
        )
    }

    func coordinator(sender: AutoSendRecordingSender) -> ConnectorMutationCoordinator {
        ConnectorMutationCoordinator(
            modelContext: context,
            sender: sender,
            secretStore: AutoSendSecretStore(),
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

private final class AutoSendRecordingSender: ConnectorMutationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var sentPaths: [String] = []
    let statusCode: Int
    let body: String

    init(statusCode: Int = 201, body: String = "{}") {
        self.statusCode = statusCode
        self.body = body
    }

    var count: Int { lock.withLock { sent } }
    var paths: [String] { lock.withLock { sentPaths } }

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        lock.withLock {
            sent += 1
            sentPaths.append(request.url.path)
        }
        return ConnectorMutationHTTPResponse(statusCode: statusCode, body: body)
    }
}

private struct AutoSendSecretStore: SecretStore {
    func load(key: String, entityID _: String) -> String? {
        ["JIRA_EMAIL": "user@example.com", "JIRA_API_TOKEN": "auto-token"][key]
    }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID: String) -> Bool { load(key: key, entityID: entityID) != nil }
}

@Suite("Connector proposal guidance by level")
struct ConnectorProposalGuidanceTests {
    private static let contract = HostControlPlanePromptGuidance.mutationUnderReviewContract(usesHostControlCLIRelay: false)

    @Test("Auto tells the agent a staged write is sent at the end of the turn")
    func autoGuidanceSaysItIsSent() {
        let prompt = HostControlPlanePromptGuidance.appendingAutoSendGuidance(to: Self.contract, permissionPolicy: .autonomous)
        #expect(prompt.hasPrefix(Self.contract))
        #expect(prompt.contains("sent by ASTRA with the connector credential when this turn ends"))
    }

    @Test("Ask keeps the review contract and a prompt without it gains nothing")
    func askAndUnrelatedPromptsAreUnchanged() {
        for policy in [PermissionPolicy.restricted, .interactive] {
            #expect(HostControlPlanePromptGuidance.appendingAutoSendGuidance(to: Self.contract, permissionPolicy: policy) == Self.contract)
        }
        #expect(HostControlPlanePromptGuidance.appendingAutoSendGuidance(to: "Fix the bug", permissionPolicy: .autonomous) == "Fix the bug")
    }
}
