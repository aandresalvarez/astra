import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRAPersistence
@testable import HostControlToolSupport

/// The handoff between the two halves of the seam: the broker writes a file in
/// one process, and the app has to notice it in another. Everything else in the
/// mutation path is tested against events that a test hand-wrote, so this is the
/// only place the two halves are made to agree on a real envelope.
@Suite("Connector mutation discovery")
@MainActor
struct ConnectorMutationDiscoveryTests {
    @Test("A proposal the broker staged becomes a pending review")
    func stagedProposalBecomesPendingReview() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let reply = try propose(
            fixture,
            summary: "De-identification drops the age filter on three domains"
        )
        let digest = try #require(value(of: "request_digest", in: reply))
        let stagedPath = try #require(value(of: "staged_path", in: reply))

        let recorded = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(recorded.count == 1)
        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        #expect(pending.count == 1)
        // The digest the broker reported and the one the app will bind the
        // approval to have to be the same string, or review and commit are
        // agreeing about different bytes.
        #expect(pending.first?.requestDigest == digest)
        #expect(pending.first?.stagedPayloadPath == stagedPath)
        #expect(pending.first?.serviceType == "jira")
        // What ASTRA will do, not what the agent called.
        #expect(pending.first?.operation == "create_issue")
        #expect(pending.first?.target == "STAR / Bug")
        #expect(pending.first?.runID == fixture.run.id)
    }

    /// Declining leaves the file in place, on purpose — the user may still want
    /// to read what was proposed. So the next run's scan sees it again, and
    /// `recordedStagedPaths` is the only thing standing between that and a row
    /// the user cannot get rid of.
    @Test("A rescan does not resurrect a proposal the user declined")
    func rescanDoesNotResurrectADeclinedProposal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let reply = try propose(fixture, summary: "Add an age filter to dose_era")
        let stagedPath = try #require(value(of: "staged_path", in: reply))

        ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            type: ConnectorMutationEventTypes.declined,
            payload: #"{"version":2,"stagedPayloadPath":"\#(stagedPath)"}"#,
            run: fixture.run
        ))
        try fixture.context.save()

        let rescanned = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(rescanned.isEmpty)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
        // Still on disk. The scan has to be what stayed quiet, not the file.
        #expect(FileManager.default.fileExists(atPath: stagedPath))
    }

    /// The same ticket, asked for twice. The bytes are identical, so the digest
    /// is too — and identifying a proposal by its digest meant the second one
    /// was silently swallowed as a replay of a decision the user had already
    /// made. Two acts of proposing are two decisions.
    @Test("Re-proposing a declined ticket is offered again")
    func reProposingADeclinedTicketIsOfferedAgain() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let first = try propose(fixture, summary: "Add an age filter to dose_era")
        let firstPath = try #require(value(of: "staged_path", in: first))
        let firstDigest = try #require(value(of: "request_digest", in: first))

        ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            type: ConnectorMutationEventTypes.declined,
            payload: #"{"version":2,"stagedPayloadPath":"\#(firstPath)"}"#,
            run: fixture.run
        ))
        try fixture.context.save()

        // Byte-for-byte the same request, so the same digest.
        let second = try propose(fixture, summary: "Add an age filter to dose_era")
        let secondPath = try #require(value(of: "staged_path", in: second))
        #expect(try #require(value(of: "request_digest", in: second)) == firstDigest)
        #expect(secondPath != firstPath)

        let rescanned = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(rescanned.map(\.stagedPayloadPath) == [secondPath])
        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        #expect(pending.map(\.stagedPayloadPath) == [secondPath])
    }

    @Test("Two proposals in one run each need their own approval")
    func twoProposalsEachNeedTheirOwnApproval() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = try propose(fixture, summary: "Add an age filter to dose_era", issueType: "Bug")
        _ = try propose(fixture, summary: "Add an age filter to cost", issueType: "Task")

        ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.stagedPayloadPath)).count == 2)
        #expect(Set(pending.map(\.requestDigest)).count == 2)
        #expect(Set(pending.map(\.target)) == ["STAR / Bug", "STAR / Task"])
    }

    /// The overwhelmingly common case, and it must not cost an event. A run that
    /// staged nothing has nothing to say.
    @Test("A run that staged nothing records nothing")
    func runThatStagedNothingRecordsNothing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let recorded = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(recorded.isEmpty)
        #expect(fixture.task.events.isEmpty)
    }

    /// The staging directory is agent-writable, so its size is agent-controlled.
    /// The cap is the defence, and saying so is the other half of it: a silently
    /// truncated scan reads as "ASTRA saw everything" when it did not.
    @Test("A staging directory over the cap is truncated and says so")
    func stagingDirectoryOverTheCapSaysSo() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let overCap = ConnectorMutationDiscovery.maximumProposalsPerScan + 1
        for index in 0..<overCap {
            _ = try propose(fixture, summary: "Proposal \(index)")
        }

        let recorded = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(recorded.count == ConnectorMutationDiscovery.maximumProposalsPerScan)
        let errors = fixture.task.events.filter { $0.type == TaskEventTypes.System.error.rawValue }
        #expect(errors.count == 1)
        #expect(errors.first?.payload.contains("has \(overCap) connector mutations") == true)
        #expect(
            errors.first?.payload
                .contains("offering \(ConnectorMutationDiscovery.maximumProposalsPerScan) of them") == true
        )
    }

    /// The cap must apply to what is *left*, not to the directory listing.
    /// Filtering after the cap meant every later scan re-examined the same
    /// first 25 recorded names, skipped them all, and never reached the 26th —
    /// a proposal the agent staged and the user would never be shown.
    @Test("A proposal past the cap is picked up by the next scan")
    func proposalPastTheCapIsPickedUpByTheNextScan() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let overCap = ConnectorMutationDiscovery.maximumProposalsPerScan + 1
        var stagedPaths: [String] = []
        for index in 0..<overCap {
            let reply = try propose(fixture, summary: "Proposal \(index)")
            stagedPaths.append(try #require(value(of: "staged_path", in: reply)))
        }

        let first = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()
        #expect(first.count == ConnectorMutationDiscovery.maximumProposalsPerScan)

        let second = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(second.count == 1)
        let recordedPaths = ConnectorMutationRequirementResolver.recordedStagedPaths(task: fixture.task)
        #expect(recordedPaths == Set(stagedPaths))
        #expect(
            ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == overCap
        )
    }

    /// An envelope the app cannot parse is a proposal the user will never be
    /// offered. Skipping it quietly leaves the agent believing a write is queued
    /// and the user unaware one is missing.
    @Test("An unreadable envelope is reported rather than skipped in silence")
    func unreadableEnvelopeIsReported() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let directory = ConnectorMutationStaging.stagingDirectory(taskFolder: fixture.taskFolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not an envelope".write(
            to: directory.appendingPathComponent("jira-create_issue-broken.json"),
            atomically: true,
            encoding: .utf8
        )

        let recorded = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(recorded.isEmpty)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
        let errors = fixture.task.events.filter { $0.type == TaskEventTypes.System.error.rawValue }
        #expect(errors.count == 1)
        #expect(errors.first?.payload.contains("could not read 1 staged connector") == true)
        #expect(errors.first?.payload.contains("jira-create_issue-broken.json") == true)
    }

    /// A file dropped outside the staging directory is not a proposal, however
    /// well-formed it looks. The scan reads one directory and the reader refuses
    /// anything whose parent is not that directory.
    @Test("An envelope outside the staging directory is never discovered")
    func envelopeOutsideTheStagingDirectoryIsNeverDiscovered() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let reply = try propose(fixture, summary: "Add an age filter to specimen")
        let stagedPath = try #require(value(of: "staged_path", in: reply))
        let moved = URL(fileURLWithPath: fixture.taskFolder)
            .appendingPathComponent("jira-create_issue-loose.json")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: stagedPath), to: moved)

        let recorded = ConnectorMutationDiscovery.recordStagedMutations(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        try fixture.context.save()

        #expect(recorded.isEmpty)
        #expect(fixture.task.events.isEmpty)
    }

    // MARK: - Fixture

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun
        let root: String
        let taskFolder: String
        let server: HostControlMCPServer

        func cleanUp() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [configuration]
        )
        let context = container.mainContext

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-mutation-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Discovery", primaryPath: root.path)
        let task = AgentTask(
            title: "File a ticket",
            goal: "File a Jira ticket for the age filter gap",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        // The app's own folder resolution, not a path the test invented: the
        // broker staging somewhere the app does not scan is the failure this
        // whole suite is here to catch.
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()

        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira",\
        "serviceType":"jira","baseURL":"https://jira.discovery.test","authMethod":"basic",\
        "env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},\
        "credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(
            taskFolder: taskFolder,
            runID: run.id.uuidString,
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        ))

        return Fixture(
            container: container,
            context: context,
            task: task,
            run: run,
            root: root.path,
            taskFolder: taskFolder,
            server: server
        )
    }

    @discardableResult
    private func propose(
        _ fixture: Fixture,
        summary: String,
        issueType: String = "Bug"
    ) throws -> String {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "jira",
                "arguments": [
                    "operation": "propose_issue",
                    "project_key": "STAR",
                    "issue_type": issueType,
                    "summary": summary,
                    "description": "Filed from ASTRA under review."
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: data, encoding: .utf8))
        let line = try #require(fixture.server.handleLine(requestLine))
        let responseData = try #require(line.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("sent: false"))
        return text
    }

    private func value(of key: String, in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)) }
    }
}
