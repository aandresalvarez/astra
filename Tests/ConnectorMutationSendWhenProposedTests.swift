import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// Spec decision 15 for connector writes: in Auto the write happens when the
/// agent proposes it — the broker asks, ASTRA sends through the review sheet's
/// own `prepare` and `send`, and the receipt is the agent's answer. Ask and
/// Custom are unchanged: nothing is sent, and the run-boundary scan offers the
/// proposal for review. Nothing here waits for the run to end.
@Suite("Connector write sent when proposed", .serialized)
@MainActor
struct ConnectorMutationSendWhenProposedTests {
    @Test("Auto sends a proposal when the broker asks and returns its receipt")
    func autoSendsWhenProposed() async throws {
        let fixture = try Fixture()
        let sender = Sender(responses: [.init(statusCode: 201, body: #"{"key":"STAR-12558"}"#)])
        let staged = try fixture.stage()

        let outcome = await fixture.handler(level: .autonomous, sender: sender).sendStagedConnectorMutation(staged.request)

        #expect(outcome == .performed(BrokeredExternalActionReceipt(
            identifier: "STAR-12558", url: "https://jira.auto.test/browse/STAR-12558"
        )))
        #expect(sender.requests.count == 1)
        #expect(sender.requests.first?.body == staged.staged.requestBody)

        let record = try #require(fixture.stagedRecords().first)
        #expect(fixture.stagedRecords().count == 1)
        #expect(record.authorization == .autoPolicy)
        #expect(record.runID == fixture.run.id)
        let receipt = try #require(fixture.receipts().first)
        #expect(receipt.authorization == .autoPolicy)
        #expect(receipt.createdKey == "STAR-12558")
        #expect(fixture.events(ConnectorMutationEventTypes.receipt).first?.run?.id == fixture.run.id)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)

        // The chat shows the Auto pill, from the receipt.
        let event = try #require(fixture.events(ConnectorMutationEventTypes.receipt).first)
        let shown = try #require(ExternalActionRecordProjection.record(
            type: event.type, payload: event.payload, eventID: event.id, timestamp: event.timestamp
        ))
        #expect(shown.authorization == .autoPolicy)
        #expect(shown.title == "Created STAR-12558")
    }

    @Test("Ask and Custom send nothing and leave the proposal for the run-boundary review")
    func askAndCustomLeaveItForReview() async throws {
        for level in [AgentPolicyLevel.review, .custom, .build] {
            let fixture = try Fixture()
            let sender = Sender()
            let staged = try fixture.stage()

            let outcome = await fixture.handler(level: level, sender: sender).sendStagedConnectorMutation(staged.request)

            #expect(outcome == .awaitingReview, "\(level.rawValue)")
            #expect(sender.requests.isEmpty)
            #expect(fixture.task.events.isEmpty, "\(level.rawValue) recorded something at proposal time")

            // Exactly as before: the scan at the run boundary records it, unsent.
            let discovered = ConnectorMutationDiscovery.recordStagedMutations(
                task: fixture.task, run: fixture.run, modelContext: fixture.context
            )
            #expect(discovered.map(\.stagedPayloadPath) == [staged.staged.path])
            #expect(discovered.first?.authorization == nil)
            #expect(ConnectorMutationCoordinator.reviewable(
                ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
            ).count == 1)
        }
    }

    @Test("The run-boundary scan never offers a proposal Auto already sent")
    func scanDoesNotReofferAnAutoSend() async throws {
        let fixture = try Fixture()
        let staged = try fixture.stage()
        _ = await fixture.handler(level: .autonomous, sender: Sender()).sendStagedConnectorMutation(staged.request)

        let discovered = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task, run: fixture.run, modelContext: fixture.context
        )

        #expect(discovered.isEmpty)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    /// The staged directory is agent-writable, and the broker's digest is the
    /// only claim about what it wrote.
    @Test("Auto refuses bytes that changed after the broker staged them")
    func changedBytesAreRefused() async throws {
        let fixture = try Fixture()
        let sender = Sender()
        let staged = try fixture.stage()
        // A different, well-formed envelope in its place, so only the digest
        // can tell the two apart.
        let other = try fixture.stage(summary: "Delete every ticket in STAR")
        try Data(contentsOf: URL(fileURLWithPath: other.staged.path)).write(to: URL(fileURLWithPath: staged.staged.path))
        try FileManager.default.removeItem(atPath: other.staged.path)

        let outcome = await fixture.handler(level: .autonomous, sender: sender).sendStagedConnectorMutation(staged.request)

        guard case .refused = outcome else {
            Issue.record("Expected a refusal, got \(outcome)")
            return
        }
        #expect(sender.requests.isEmpty)
    }

    /// The agent was told, and may already have proposed a corrected one.
    @Test("A provider refusal goes back to the agent and is never offered for a later send")
    func refusalRetiresTheAutoProposal() async throws {
        let fixture = try Fixture()
        let sender = Sender(responses: [.init(statusCode: 400, body: #"{"errorMessages":["Field 'priority' is invalid"]}"#)])
        let staged = try fixture.stage()
        let handler = fixture.handler(level: .autonomous, sender: sender)

        let outcome = await handler.sendStagedConnectorMutation(staged.request)

        #expect(outcome == .refused(message: "The connector rejected the request (HTTP 400): Field 'priority' is invalid"))
        #expect(fixture.events(ConnectorMutationEventTypes.failed).count == 1)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)

        // Asking again for the same file sends nothing.
        _ = await handler.sendStagedConnectorMutation(staged.request)
        #expect(sender.requests.count == 1)
    }

    /// The store that would not take the failure is the case the event cannot
    /// cover: the record stays pending and the dock shows it. What it must not
    /// be is sendable — the agent was told to correct it, and the corrected
    /// one may already have landed — and that has to survive a relaunch.
    @Test("An Auto failure that cannot be saved still can never be sent from the dock")
    func unsavedFailureStillCannotBeSent() async throws {
        let fixture = try Fixture()
        let sender = Sender(responses: [.init(statusCode: 400, body: #"{"errorMessages":["Field 'priority' is invalid"]}"#)])
        let staged = try fixture.stage()
        let failingFailureSave: ConnectorMutationCoordinator.DurableEventSave = { _, context, _, fields in
            if fields["operation"] == "connector_mutation_failed" { throw URLError(.cannotWriteToFile) }
            try context.save()
        }
        let handler = BrokeredExternalActionHandler(
            modelContext: fixture.context,
            taskID: fixture.task.id,
            runID: fixture.run.id,
            policyLevel: .autonomous,
            makeCoordinator: { context in
                fixture.coordinator(sender: sender, context: context, durableEventSave: failingFailureSave)
            }
        )

        let outcome = await handler.sendStagedConnectorMutation(staged.request)

        guard case .refused = outcome else {
            Issue.record("Expected a refusal, got \(outcome)")
            return
        }
        let record = try #require(ConnectorMutationCoordinator.reviewable(
            ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        ).first, "the unsaved retirement leaves the record pending")
        // As after a relaunch: only what is on disk is left.
        ConnectorMutationCoordinator.resetSentStagedPathsForTesting()
        #expect(throws: ConnectorMutationCoordinatorError.returnedToAgent(target: record.target)) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: record)
        }
        #expect(sender.requests.count == 1)
    }

    /// Staged names are predictable and the folder is the agent's, so a link
    /// planted where the marker goes must not lead ASTRA's write outside it.
    @Test("A link planted at the returned marker is never followed")
    func plantedMarkerLinkIsNotFollowed() async throws {
        let fixture = try Fixture(baseURL: "http://jira.auto.test")
        let staged = try fixture.stage()
        let outside = fixture.workspaceRoot.appendingPathComponent("outside.txt")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: staged.staged.path + ".returned", withDestinationPath: outside.path
        )

        let outcome = await fixture.handler(level: .autonomous, sender: Sender()).sendStagedConnectorMutation(staged.request)

        guard case .refused = outcome else {
            Issue.record("Expected a refusal, got \(outcome)")
            return
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
        ConnectorMutationCoordinator.resetSentStagedPathsForTesting()
        #expect(ConnectorMutationCoordinator.wasReturnedToAgent(stagedPath: staged.staged.path))
    }

    @Test("A refusal before dispatch retires the Auto proposal too")
    func preDispatchRefusalRetires() async throws {
        let fixture = try Fixture(baseURL: "http://jira.auto.test")
        let sender = Sender()
        let staged = try fixture.stage()

        let outcome = await fixture.handler(level: .autonomous, sender: sender).sendStagedConnectorMutation(staged.request)

        guard case let .refused(message) = outcome else {
            Issue.record("Expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("unprotected HTTP"))
        #expect(sender.requests.isEmpty)
        #expect(fixture.events(ConnectorMutationEventTypes.failed).count == 1)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    @Test("An ambiguous dispatch is never sent a second time, by Auto or by the review")
    func ambiguousDispatchIsNeverResent() async throws {
        let fixture = try Fixture()
        let sender = Sender(failure: URLError(.networkConnectionLost))
        let staged = try fixture.stage()
        let handler = fixture.handler(level: .autonomous, sender: sender)

        let outcome = await handler.sendStagedConnectorMutation(staged.request)

        guard case .uncertain = outcome else {
            Issue.record("Expected an uncertain outcome, got \(outcome)")
            return
        }
        #expect(fixture.events(ConnectorMutationEventTypes.indeterminate).count == 1)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)

        _ = await handler.sendStagedConnectorMutation(staged.request)
        let record = try #require(fixture.stagedRecords().first)
        #expect(throws: ConnectorMutationCoordinatorError.self) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: record)
        }
        #expect(sender.requests.count == 1)
    }

    /// The caller's timeout reaches the send, kept inside the broker's wait so
    /// a finished write is never reported as "not known yet".
    @Test("Auto sends with the caller's timeout, bounded by the broker's wait")
    func autoSendUsesTheCallersTimeout() async throws {
        let fixture = try Fixture()
        let sender = Sender()
        let handler = fixture.handler(level: .autonomous, sender: sender)
        for timeout in [nil, 90, 100_000] as [TimeInterval?] {
            let staged = try fixture.stage(summary: "Timeout \(String(describing: timeout))")
            _ = await handler.sendStagedConnectorMutation(StagedConnectorMutationRequest(
                stagedPath: staged.staged.path, requestDigest: staged.staged.digest, timeoutSeconds: timeout
            ))
        }

        #expect(sender.requests.map(\.timeoutSeconds) == [
            URLSessionConnectorMutationSender.timeoutSeconds, 90, BrokeredExternalActionHandler.longestSendSeconds
        ])
        #expect(BrokeredExternalActionHandler.longestSendSeconds < BrokeredExternalActionBridge.defaultTimeoutSeconds)
    }

    @Test("An epic's key comes back before the story under it is proposed")
    func dependentProposalsBuildOnTheReceipt() async throws {
        let fixture = try Fixture()
        let sender = Sender(responses: [
            .init(statusCode: 201, body: #"{"key":"STAR-1"}"#),
            .init(statusCode: 201, body: #"{"key":"STAR-2"}"#)
        ])
        let handler = fixture.handler(level: .autonomous, sender: sender)

        let epic = await handler.sendStagedConnectorMutation(try fixture.stage(summary: "Epic").request)
        guard case let .performed(epicReceipt) = epic, let epicKey = epicReceipt.identifier else {
            Issue.record("Expected the epic to be sent, got \(epic)")
            return
        }
        let story = await handler.sendStagedConnectorMutation(try fixture.stage(summary: "Story", parentKey: epicKey).request)

        #expect(story == .performed(BrokeredExternalActionReceipt(identifier: "STAR-2", url: "https://jira.auto.test/browse/STAR-2")))
        let storyBody = try #require(sender.requests.last?.body)
        let fields = try #require((try JSONSerialization.jsonObject(with: storyBody) as? [String: Any])?["fields"] as? [String: Any])
        #expect((fields["parent"] as? [String: Any])?["key"] as? String == "STAR-1")
    }

    /// The run's outcome is not part of the decision: the write happened when
    /// the agent asked, as its own `git push` would have.
    @Test("A run that already failed or was cancelled still gets its request answered")
    func runOutcomeDoesNotDecide() async throws {
        let fixture = try Fixture()
        fixture.run.status = .failed
        let sender = Sender()

        let outcome = await fixture.handler(level: .autonomous, sender: sender).sendStagedConnectorMutation(try fixture.stage().request)

        guard case .performed = outcome else {
            Issue.record("Expected a send, got \(outcome)")
            return
        }
        #expect(sender.requests.count == 1)
    }

    @Test("A proposal ASTRA cannot record is not sent and waits for review")
    func unrecordableProposalIsNotSent() async throws {
        let fixture = try Fixture()
        let sender = Sender()
        let staged = try fixture.stage()
        let handler = BrokeredExternalActionHandler(
            modelContext: fixture.context,
            taskID: fixture.task.id,
            runID: fixture.run.id,
            policyLevel: .autonomous,
            makeCoordinator: { context in
                fixture.coordinator(sender: sender, context: context, durableEventSave: { _, _, _, _ in
                    throw URLError(.cannotCreateFile)
                })
            }
        )

        let outcome = await handler.sendStagedConnectorMutation(staged.request)

        #expect(outcome == .awaitingReview)
        #expect(sender.requests.isEmpty)
        #expect(fixture.stagedRecords().isEmpty)
        #expect(ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task, run: fixture.run, modelContext: fixture.context
        ).count == 1)
    }

    @Test("The dock does not offer a proposal while Auto is sending it")
    func inFlightSendIsNotReviewable() async throws {
        let fixture = try Fixture()
        let sender = Sender(holdsFirstSend: true)
        let staged = try fixture.stage()
        let handler = fixture.handler(level: .autonomous, sender: sender)

        let sending = Task { await handler.sendStagedConnectorMutation(staged.request) }
        guard await sender.waitUntilHeld() else {
            Issue.record("Auto never started sending: \(await sending.value)")
            return
        }

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        #expect(pending.map(\.stagedPayloadPath) == [staged.staged.path])
        #expect(ConnectorMutationCoordinator.reviewable(pending).isEmpty)

        sender.release()
        _ = await sending.value
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    /// ASTRA stopped mid-send: the record has no outcome. It stays visible, so
    /// the review can say it was already claimed rather than it vanishing.
    @Test("An Auto proposal with no outcome stays visible after the process that sent it is gone")
    func orphanedAutoProposalStaysVisible() throws {
        let fixture = try Fixture()
        let staged = try fixture.stage()
        let record = TaskStagedConnectorMutation(
            runID: fixture.run.id, serviceType: "jira", operation: staged.staged.operation,
            connectorID: staged.staged.connectorID, connectorAlias: staged.staged.connectorAlias,
            target: staged.staged.target, summary: staged.staged.summary,
            stagedPayloadPath: staged.staged.path, requestDigest: staged.staged.digest,
            authorization: .autoPolicy
        )
        fixture.context.insert(TaskEvent.structuredPayloadEvent(
            task: fixture.task, type: ConnectorMutationEventTypes.staged, payload: record, run: fixture.run
        ))

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        #expect(ConnectorMutationCoordinator.reviewable(pending).map(\.stagedPayloadPath) == [staged.staged.path])
    }

    @Test("A failure retires an Auto proposal and leaves a reviewed one sendable")
    func failureRetiresOnlyAutoRecords() throws {
        func staged(_ path: String, _ authorization: ExternalActionAuthorization?) -> TaskOutcomeEventRecord {
            let record = TaskStagedConnectorMutation(
                runID: UUID(), serviceType: "jira", operation: "create_issue", connectorID: UUID().uuidString,
                connectorAlias: "jira", target: "STAR / Bug", summary: "s", stagedPayloadPath: path,
                requestDigest: "d", authorization: authorization
            )
            return event(ConnectorMutationEventTypes.staged, record, at: 0)
        }
        func failed(_ path: String) -> TaskOutcomeEventRecord {
            event(ConnectorMutationEventTypes.failed, ConnectorMutationFailure(
                stagedPayloadPath: path, requestDigest: "d", statusCode: 400, message: "no"
            ), at: 1)
        }

        let pending = ConnectorMutationRequirementResolver.pendingMutations(events: [
            staged("/t/auto.json", .autoPolicy), failed("/t/auto.json"),
            staged("/t/reviewed.json", nil), failed("/t/reviewed.json")
        ])

        #expect(pending.map(\.stagedPayloadPath) == ["/t/reviewed.json"])
    }

    // MARK: - Through the broker

    @Test("The broker's request reaches ASTRA and the receipt comes back as the tool result")
    func brokerRequestEndToEnd() async throws {
        let fixture = try Fixture()
        let sender = Sender(responses: [.init(statusCode: 201, body: #"{"key":"STAR-7"}"#)])
        try FileManager.default.createDirectory(atPath: fixture.taskFolder, withIntermediateDirectories: true)
        let server = Unchecked(HostControlMCPServer(
            configuration: fixture.brokerConfiguration(),
            externalActionRequester: BrokeredExternalActionBridge(handler: fixture.handler(level: .autonomous, sender: sender))
        ))
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jira","arguments":{"operation":"propose_issue","project_key":"STAR","issue_type":"Bug","summary":"Age filter missing"}}}"#

        let reply = await Self.offMain { server.value.handleLine(line) ?? "" }

        #expect(reply.contains("sent: true"))
        #expect(reply.contains("key: STAR-7"))
        #expect(reply.contains(#""isError":false"#))
        #expect(sender.requests.count == 1)
        #expect(fixture.receipts().first?.authorization == .autoPolicy)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    @Test("The same request through the broker in Ask sends nothing and says it waits for review")
    func brokerRequestInAsk() async throws {
        let fixture = try Fixture()
        let sender = Sender()
        try FileManager.default.createDirectory(atPath: fixture.taskFolder, withIntermediateDirectories: true)
        let server = Unchecked(HostControlMCPServer(
            configuration: fixture.brokerConfiguration(),
            externalActionRequester: BrokeredExternalActionBridge(handler: fixture.handler(level: .review, sender: sender))
        ))
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jira","arguments":{"operation":"propose_issue","project_key":"STAR","issue_type":"Bug","summary":"Age filter missing"}}}"#

        let reply = await Self.offMain { server.value.handleLine(line) ?? "" }

        #expect(reply.contains("sent: false"))
        #expect(reply.contains("review this exact payload"))
        #expect(sender.requests.isEmpty)
        #expect(fixture.task.events.isEmpty)
    }

    /// Waiting there would wait on itself.
    @Test("A request made on the main thread is left for review instead of waiting on itself")
    func mainThreadRequestDoesNotWaitOnItself() throws {
        let fixture = try Fixture()
        let sender = Sender()
        let bridge = BrokeredExternalActionBridge(handler: fixture.handler(level: .autonomous, sender: sender))
        try #require(Thread.isMainThread)

        #expect(bridge.sendStagedConnectorMutation(try fixture.stage().request) == .awaitingReview)
        #expect(sender.requests.isEmpty)
    }

    @Test("A send that outlives the broker's wait is reported as uncertain and still records its outcome")
    func slowSendIsUncertainThenRecorded() async throws {
        let fixture = try Fixture()
        let sender = Sender(holdsFirstSend: true)
        let bridge = BrokeredExternalActionBridge(
            handler: fixture.handler(level: .autonomous, sender: sender),
            timeoutSeconds: 0.2
        )
        let request = try fixture.stage().request

        let outcome = await Self.offMain { bridge.sendStagedConnectorMutation(request) }

        guard case .uncertain = outcome else {
            Issue.record("Expected an uncertain outcome, got \(outcome)")
            return
        }
        #expect(await sender.waitUntilHeld())
        sender.release()
        // Polls, not a clock: the send finishes on the main actor once released.
        for _ in 0..<500 where fixture.receipts().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fixture.receipts().first?.authorization == .autoPolicy)
        #expect(sender.requests.count == 1)
    }

    /// The binding is what makes the level the run's own: the worker binds it
    /// with the launch manifest's level before the provider starts, and the
    /// registry hands it to the session it prepares. Without it every request
    /// answers "waits for review" and Auto silently stops sending.
    @Test("Each run's broker is bound to that run's launch level")
    func workerBindsTheRunsLevel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let worker = try String(contentsOf: root.appendingPathComponent("Astra/Services/Runtime/AgentRuntimeWorker.swift"), encoding: .utf8)
        let binding = try #require(worker.range(of: "bindExternalActions("))
        let bound = worker[binding.lowerBound...].prefix(900)
        #expect(bound.contains("policyLevel: manifest.policyLevel"))
        #expect(bound.contains("runID: run.id"))
        #expect(worker.contains("unbindExternalActions(taskID: task.id, runID: run.id)"))
        #expect(worker.range(of: "let manifest = AgentPolicyManifestService.recordPreflightManifest")!.lowerBound < binding.lowerBound)

        let registry = try String(contentsOf: root.appendingPathComponent("Astra/Services/Runtime/HostControlBrokerSessionRegistry.swift"), encoding: .utf8)
        #expect(registry.contains("externalActionRequester: externalActionRequester(taskID: task.id, runID: runID)"))
    }

    /// On a GCD thread, as the broker's connection queue is — never the
    /// cooperative pool, which a semaphore wait would starve.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Fixture

    private func event<T: Encodable>(_ type: String, _ payload: T, at offset: TimeInterval) -> TaskOutcomeEventRecord {
        let data = (try? TaskEventPayloadCodec.makeEncoder().encode(payload)) ?? Data()
        return TaskOutcomeEventRecord(
            id: UUID(), runID: nil, type: type, payload: String(decoding: data, as: UTF8.self),
            timestamp: Date(timeIntervalSince1970: 1_000 + offset)
        )
    }

    @MainActor
    final class Fixture {
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun
        let connector: Connector
        let workspaceRoot: URL

        init(baseURL: String = "https://jira.auto.test") throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-send-when-proposed-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            let workspace = Workspace(name: "Auto", primaryPath: workspaceRoot.path)
            task = AgentTask(title: "File tickets", goal: "File the epic and its stories in Jira")
            run = TaskRun(task: task)
            connector = Connector(name: "Jira", serviceType: "jira", baseURL: baseURL, authMethod: "basic")
            connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
            task.workspace = workspace
            context.insert(workspace)
            context.insert(task)
            context.insert(run)
            context.insert(connector)
            try context.save()
            ConnectorMutationCoordinator.resetSentStagedPathsForTesting()
        }

        deinit { try? FileManager.default.removeItem(at: workspaceRoot) }

        var taskFolder: String { TaskWorkspaceAccess(task: task).taskFolder }

        func coordinator(
            sender: any ConnectorMutationSending,
            context: ModelContext? = nil,
            durableEventSave: @escaping ConnectorMutationCoordinator.DurableEventSave = { _, context, _, _ in
                try context.save()
            }
        ) -> ConnectorMutationCoordinator {
            ConnectorMutationCoordinator(
                modelContext: context ?? self.context,
                sender: sender,
                secretStore: StoreWithJiraCredential(),
                durableEventSave: durableEventSave
            )
        }

        func handler(level: AgentPolicyLevel, sender: any ConnectorMutationSending) -> BrokeredExternalActionHandler {
            BrokeredExternalActionHandler(
                modelContext: context,
                taskID: task.id,
                runID: run.id,
                policyLevel: level,
                makeCoordinator: { [unowned self] context in self.coordinator(sender: sender, context: context) }
            )
        }

        /// Through the broker's own writer, as `propose_issue` does.
        func stage(
            summary: String = "Age filter missing",
            parentKey: String? = nil
        ) throws -> (staged: ConnectorMutationStaging.StagedConnectorMutation, request: StagedConnectorMutationRequest) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: taskFolder, isDirectory: true), withIntermediateDirectories: true
            )
            var fields: [String: Any] = [
                "project": ["key": "STAR"], "issuetype": ["name": "Bug"], "summary": summary
            ]
            if let parentKey { fields["parent"] = ["key": parentKey] }
            let staged = try ConnectorMutationStaging.stage(
                serviceType: "jira",
                operation: "create_issue",
                connector: HostControlConnector(
                    id: connector.id.uuidString, alias: "jira", envPrefix: "JIRA_JIRA", name: "Jira",
                    serviceType: "jira", baseURL: connector.baseURL, authMethod: "basic",
                    env: [:], credentials: [:], config: [:]
                ),
                target: "STAR / Bug",
                summary: summary,
                requestMethod: "POST",
                requestPath: "/rest/api/2/issue",
                body: ["fields": fields],
                configuration: HostControlToolConfiguration(taskFolder: taskFolder, runID: run.id.uuidString)
            )
            return (staged, StagedConnectorMutationRequest(stagedPath: staged.path, requestDigest: staged.digest))
        }

        /// The broker's configuration for this run, with the connector the app
        /// resolves by id and the credential the broker's readiness check reads.
        func brokerConfiguration() -> HostControlToolConfiguration {
            let connectors = """
            {"connectors":[{"id":"\(connector.id.uuidString)","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira",\
            "serviceType":"jira","baseURL":"\(connector.baseURL)","authMethod":"basic",\
            "env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},\
            "credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
            """
            return HostControlToolConfiguration(
                taskFolder: taskFolder,
                runID: run.id.uuidString,
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_EMAIL_ENV": "user@example.com",
                    "JIRA_TOKEN_ENV": "token-value"
                ]
            )
        }

        func events(_ type: String) -> [TaskEvent] {
            task.events.filter { $0.type == type }
        }

        func stagedRecords() -> [TaskStagedConnectorMutation] {
            events(ConnectorMutationEventTypes.staged).compactMap { decode(TaskStagedConnectorMutation.self, $0) }
        }

        func receipts() -> [ConnectorMutationReceipt] {
            events(ConnectorMutationEventTypes.receipt).compactMap { decode(ConnectorMutationReceipt.self, $0) }
        }

        private func decode<T: Decodable>(_ type: T.Type, _ event: TaskEvent) -> T? {
            try? TaskEventPayloadCodec.makeDecoder().decode(type, from: Data(event.payload.utf8))
        }
    }
}

/// Answers in order and records what it was asked to send. Optionally holds the
/// first send open, so a test can look at the task while it is in flight.
private final class Sender: ConnectorMutationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ConnectorMutationHTTPRequest] = []
    private var responses: [ConnectorMutationHTTPResponse]
    private let failure: (any Error)?
    private let holdsFirstSend: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var isHeld = false

    init(
        responses: [ConnectorMutationHTTPResponse] = [],
        failure: (any Error)? = nil,
        holdsFirstSend: Bool = false
    ) {
        self.responses = responses
        self.failure = failure
        self.holdsFirstSend = holdsFirstSend
    }

    var requests: [ConnectorMutationHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        let first = lock.withLock { () -> Bool in
            recorded.append(request)
            return recorded.count == 1
        }
        if holdsFirstSend, first {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    held = continuation
                    isHeld = true
                }
            }
        }
        if let failure { throw failure }
        return lock.withLock {
            responses.isEmpty
                ? ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-1"}"#)
                : responses.removeFirst()
        }
    }

    /// Whether the first send reached the hold. Polled a bounded number of
    /// times, so a send that never starts fails the test instead of hanging it.
    func waitUntilHeld() async -> Bool {
        for _ in 0..<500 {
            if lock.withLock({ isHeld }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}

private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private struct StoreWithJiraCredential: SecretStore {
    func load(key: String, entityID _: String) -> String? {
        ["JIRA_EMAIL": "user@example.com", "JIRA_API_TOKEN": "token-value"][key]
    }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID _: String) -> Bool { load(key: key, entityID: "") != nil }
}
