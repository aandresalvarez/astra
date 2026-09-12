import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

// MARK: - Shared JSON-RPC plumbing

/// The broker speaks one line of JSON-RPC at a time. `HostControlToolSupportTests`
/// has the same four helpers, but they are `private` to that suite, so they are
/// rebuilt here rather than made shared API of a test file this one does not own.
private func brokerCall(
    _ server: HostControlMCPServer,
    id: Int,
    tool: String,
    arguments: [String: Any]
) throws -> [String: Any] {
    let request: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": ["name": tool, "arguments": arguments]
    ]
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    let line = try #require(String(data: data, encoding: .utf8))
    let response = try #require(server.handleLine(line))
    let responseData = try #require(response.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
}

private func brokerResultText(_ object: [String: Any]) throws -> String {
    let result = try #require(object["result"] as? [String: Any])
    let content = try #require(result["content"] as? [[String: Any]])
    return try #require(content.first?["text"] as? String)
}

private func brokerIsError(_ object: [String: Any]) throws -> Bool {
    let result = try #require(object["result"] as? [String: Any])
    return result["isError"] as? Bool ?? false
}

/// The environment variable carrying the withholding marker, spelled out instead
/// of read from `BrokeredConnectorCredentialWithholdingManifest.environmentKey`.
/// These tests have to still compile when the fix is reverted, or "watch it
/// fail" turns into "watch it fail to build", which proves nothing about
/// behaviour.
private let withheldMarkerEnvironmentKey = "ASTRA_CONNECTOR_CREDENTIALS_WITHHELD"

// MARK: - What the broker tells the agent

/// ASTRA once had one word for two situations. A connector the user never set
/// up and a connector the user set up, ASTRA verified, and this run was not
/// allowed to unseal both came back as `api_token_present: false`. In production
/// (task `9D2CC992`, Jira verified with two credentials minutes earlier) the
/// agent read that and told the user their Jira configuration was broken; the
/// user re-saved correct credentials twice. These tests hold the third word.
@Suite("Brokered connector credential withholding", .serialized)
struct BrokeredConnectorCredentialWithholdingTests {
    private static let jiraConnectorID = "6F1C7C2E-4E52-4E1F-9C42-9A0E4C0B7A11"
    private static let redcapConnectorID = "2B58E0D4-9F31-4A7C-8E10-3D6B1F9C4A22"

    /// What the restricted projection actually leaves behind. The connector is
    /// still in the manifest with its route and base URL intact — that is the
    /// offered tier working as designed — and its credentials have no `env` or
    /// `credentials` binding at all, because a withheld credential produces no
    /// binding for the manifest to carry.
    private static let jiraConnectorsJSON = """
    {"connectors":[{"id":"\(jiraConnectorID)","alias":"jira","envPrefix":"JIRA","name":"Jira",\
    "serviceType":"jira","baseURL":"https://example.atlassian.net","authMethod":"basic",\
    "env":{"baseURL":"JIRA_BASE_URL"},"credentials":{},"config":{}}]}
    """

    private static let jiraWithheldMarker = """
    {"version":1,"connectors":[{"connectorID":"\(jiraConnectorID)","alias":"jira","name":"Jira",\
    "serviceType":"jira","toolName":"jira","credentials":[\
    {"key":"JIRA_EMAIL","envKey":"JIRA_EMAIL_ENV","logicalName":"JIRA_EMAIL"},\
    {"key":"JIRA_API_TOKEN","envKey":"JIRA_TOKEN_ENV","logicalName":"JIRA_API_TOKEN"}]}]}
    """

    private static let redcapConnectorsJSON = """
    {"connectors":[{"id":"\(redcapConnectorID)","alias":"registry","envPrefix":"REDCAP",\
    "name":"Registry Export","serviceType":"redcap","baseURL":"https://redcap.example.test/api/",\
    "authMethod":"token","env":{},"credentials":{},"config":{}}]}
    """

    private static let redcapWithheldMarker = """
    {"version":1,"connectors":[{"connectorID":"\(redcapConnectorID)","alias":"registry",\
    "name":"Registry Export","serviceType":"redcap","toolName":"redcap","credentials":[\
    {"key":"REDCAP_API_TOKEN","envKey":"REDCAP_TOKEN_ENV","logicalName":"REDCAP_API_TOKEN"}]}]}
    """

    // MARK: Jira

    @Test("A withheld Jira credential reads as withheld, and an unconfigured one still reads as absent")
    func withheldJiraCredentialReadsAsWithheld() throws {
        let withheld = try brokerResultText(try brokerCall(
            jiraServer(marker: Self.jiraWithheldMarker),
            id: 1,
            tool: "jira",
            arguments: ["operation": "status"]
        ))

        // The third state, in the field the agent already knows how to read.
        #expect(withheld.contains("email_present: withheld"))
        #expect(withheld.contains("api_token_present: withheld"))
        // The names survive the withholding. Without the marker they are gone
        // with the binding, and the agent cannot even say which variables the
        // run would have carried.
        #expect(withheld.contains("email_env_key: JIRA_EMAIL_ENV"))
        #expect(withheld.contains("api_token_env_key: JIRA_TOKEN_ENV"))
        #expect(withheld.contains("credentials_withheld: true"))
        #expect(withheld.contains("credentials_withheld_keys: JIRA_EMAIL_ENV, JIRA_TOKEN_ENV"))
        // The sentence that stops the production failure: the agent must not be
        // able to read this as a broken setup.
        #expect(withheld.contains("the user has configured these credentials and ASTRA still holds them"))
        #expect(withheld.contains("Nothing about the saved configuration is missing, expired, or wrong."))
        #expect(withheld.contains("this needs approval, not reconfiguration"))
        #expect(withheld.contains("do not ask them to re-enter, re-save, or re-verify the credentials."))
        // Still not usable — widening the vocabulary must not widen the access.
        #expect(withheld.contains("ready: false"))

        // Same connector, no marker: a connector nobody ever configured is
        // reported exactly as it always was, with none of the new guidance
        // telling the user to approve something that does not exist.
        let absent = try brokerResultText(try brokerCall(
            jiraServer(marker: nil),
            id: 2,
            tool: "jira",
            arguments: ["operation": "status"]
        ))
        #expect(absent.contains("email_present: false"))
        #expect(absent.contains("api_token_present: false"))
        #expect(!absent.contains("credentials_withheld"))
        #expect(!absent.contains("next_step:"))
    }

    // MARK: REDCap

    /// Jira is where the incident happened; it is not where the bug lives. The
    /// same silence was in every broker-owned connector's status path, so the
    /// third state has to arrive through the shared report rather than through
    /// a Jira special case.
    @Test("REDCap reports the same withheld state, and a blocked read says so in the diagnostics log")
    func redcapReportsTheSameWithheldState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-withheld-redcap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let configuration = HostControlToolConfiguration(
            currentDirectory: "/tmp/not-the-export-destination",
            diagnosticsHostPath: root.path,
            connectorsJSON: Self.redcapConnectorsJSON,
            environment: [
                "ASTRA_CONNECTORS": Self.redcapConnectorsJSON,
                withheldMarkerEnvironmentKey: Self.redcapWithheldMarker
            ]
        )
        let server = HostControlMCPServer(
            configuration: configuration,
            diagnosticsRecorder: HostControlToolDiagnosticsRecorder(configuration: configuration)
        )

        let status = try brokerCall(server, id: 1, tool: "redcap", arguments: ["operation": "status"])
        let statusText = try brokerResultText(status)
        #expect(statusText.contains("api_token_present: withheld"))
        #expect(statusText.contains("api_token_env_key: REDCAP_TOKEN_ENV"))
        #expect(statusText.contains("credentials_withheld: true"))
        #expect(statusText.contains("This turn's wording did not mention REDCap"))
        #expect(statusText.contains("ready: false"))

        // A real read is still refused, and the refusal carries the same
        // guidance rather than a bare failure the agent has to interpret.
        let blocked = try brokerCall(server, id: 2, tool: "redcap", arguments: ["operation": "project"])
        #expect(try brokerIsError(blocked))
        #expect(try brokerResultText(blocked).contains("this needs approval, not reconfiguration"))

        // The log used to agree with the wrong story: "blocked: not configured"
        // written for a connector that was configured. Reading it back
        // confirmed the mistake instead of catching it.
        let diagnostics = try String(
            contentsOf: root.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false),
            encoding: .utf8
        )
        #expect(diagnostics.contains("blocked: credentials withheld from this run"))
        #expect(!diagnostics.contains("blocked: not configured"))
    }

    private func jiraServer(marker: String?) -> HostControlMCPServer {
        var environment = [
            "ASTRA_CONNECTORS": Self.jiraConnectorsJSON,
            "JIRA_BASE_URL": "https://example.atlassian.net"
        ]
        if let marker { environment[withheldMarkerEnvironmentKey] = marker }
        return HostControlMCPServer(configuration: HostControlToolConfiguration(
            connectorsJSON: Self.jiraConnectorsJSON,
            environment: environment
        ))
    }
}

// MARK: - What the app does about it

/// The offered tier hands a run a route and withholds the secret, and until now
/// nothing closed the loop: no narration meant no approval card, no card meant
/// no durable grant, and no grant meant the connector stayed sealed forever. The
/// loop is closed at the far end — the agent's own tool call is the narration —
/// and closing it must not give the offered tier the power to stop a launch.
@Suite("Brokered credential approval loop", .serialized)
@MainActor
struct BrokeredCredentialApprovalLoopTests {
    @Test("An offered connector's withheld credentials are named in the broker environment")
    func offeredConnectorCredentialsAreNamedInTheBrokerEnvironment() throws {
        let fixture = try Fixture()
        // The turn names Jira and nothing else, so REDCap is reachable-only.
        let scope = fixture.scope(for: fixture.jiraTurn)

        let environment = HostControlBrokerSessionRegistry.brokeredConnectorEnvironment(
            task: fixture.task,
            runtime: .claudeCode,
            capabilityScope: scope,
            requiredTools: ["jira", "redcap"],
            secretStore: fixture.store
        )

        // The trade the offered tier makes is unchanged: narrated secret in,
        // offered secret out.
        #expect(environment.values.contains(Fixture.jiraSecret))
        #expect(!environment.values.contains(Fixture.redcapSecret))

        let marker = try #require(environment[withheldMarkerEnvironmentKey])
        // Names only. The whole point of the marker is to let the broker say
        // "this exists and is being held back" without the value travelling
        // alongside the statement that it is being held back.
        #expect(!marker.contains(Fixture.redcapSecret))
        #expect(marker.contains(fixture.redcapConnector.id.uuidString))
        #expect(marker.contains("REDCAP_API_TOKEN"))
        // The narrated connector is not in it: its secret was unsealed, so
        // there is nothing to explain and nothing to approve.
        #expect(!marker.contains(fixture.jiraConnector.id.uuidString))
    }

    @Test("Calling a sealed connector raises a non-blocking approval offer and changes nothing about the run")
    func callingASealedConnectorRaisesANonBlockingApprovalOffer() throws {
        let fixture = try Fixture()
        let run = fixture.finishedRun()
        let server = fixture.brokerServer(taskID: fixture.task.id, runID: run.id)

        // The route is live and the tool answers — that is the offered tier
        // doing its job, and it is also why the withheld case needed a name.
        let text = try brokerResultText(try brokerCall(
            server,
            id: 1,
            tool: "redcap",
            arguments: ["operation": "status"]
        ))
        #expect(text.contains("credentials_withheld: true"))

        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: fixture.task,
            run: run,
            modelContext: fixture.context
        )

        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        let payload = try #require(
            TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: fixture.task).first
        )
        let decoded = try #require(PermissionApprovalEventPayload.decoded(from: payload))
        // A stable id per connector, so a second run of the same task replaces
        // the offer rather than stacking another copy of it in the dock.
        #expect(decoded.requestID == "connector-credentials-\(fixture.redcapConnector.id.uuidString.lowercased())")
        #expect(payload.contains("kept its saved credentials sealed"))
        #expect(payload.contains("without you re-entering anything"))
        #expect(payload.contains(Fixture.redcapCredentialLabel(fixture.redcapConnector.id)))
        #expect(fixture.task.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalRequested.rawValue })

        // The iron rule. An offered connector may widen what a run can reach and
        // may leave an offer behind; it may not fail the run, pause it, or ask
        // the user anything the run is waiting on.
        #expect(fixture.task.status == .completed)
        #expect(run.status == .completed)
    }

    /// The launch reads the grants once, at the start. A grant recorded after
    /// that — the user approved an earlier run's offer while this one was still
    /// going — means the credential was sealed for this run and will not be
    /// sealed for the next one. Offering it again asks for something already
    /// given, and the dock fills up with a card that grants nothing.
    @Test("A connector granted after the launch is not offered again at the boundary")
    func connectorGrantedAfterTheLaunchIsNotOfferedAgain() throws {
        let fixture = try Fixture()
        let run = fixture.finishedRun()
        _ = try brokerCall(
            fixture.brokerServer(taskID: fixture.task.id, runID: run.id),
            id: 1,
            tool: "redcap",
            arguments: ["operation": "status"]
        )

        // Spelled the way `ConnectorRuntimeProjection` spells it. A broker that
        // cannot reproduce the projection's label records a grant that never
        // matches, and the user is asked about the same connector forever.
        _ = TaskRuntimePermissionGrants.record(
            grants: [.credential(label: Fixture.redcapCredentialLabel(fixture.redcapConnector.id))],
            providerID: .claudeCode,
            task: fixture.task,
            modelContext: fixture.context,
            source: "test_precondition"
        )
        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: fixture.task,
            run: run,
            modelContext: fixture.context
        )

        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalRequested.rawValue })

        // And the claim the guard rests on is true: the next launch unseals the
        // connector on the strength of that grant, with nothing left to explain.
        let next = HostControlBrokerSessionRegistry.brokeredConnectorEnvironment(
            task: fixture.task,
            runtime: .claudeCode,
            capabilityScope: fixture.scope(for: fixture.jiraTurn),
            requiredTools: ["jira", "redcap"],
            secretStore: fixture.store
        )
        #expect(next.values.contains(Fixture.redcapSecret))
        #expect(next[withheldMarkerEnvironmentKey] == nil)
    }

    @Test("Approving the offer records the grant for a task that was never paused")
    func approvingTheOfferRecordsTheGrantForATaskThatWasNeverPaused() async throws {
        let fixture = try Fixture()
        let run = fixture.finishedRun()
        _ = try brokerCall(
            fixture.brokerServer(taskID: fixture.task.id, runID: run.id),
            id: 1,
            tool: "redcap",
            arguments: ["operation": "status"]
        )
        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: fixture.task,
            run: run,
            modelContext: fixture.context
        )
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))

        let coordinator = TaskLifecycleCoordinator(
            modelContext: fixture.context,
            taskQueue: TaskQueue(poolSize: 0)
        )
        await coordinator.approveSimilarRuntimePermissionForTask(fixture.task)?.value

        // The grant is the whole point: it is what the next launch reads to
        // unseal the connector. An approval path that only resumes paused tasks
        // renders an offer the user can click and that does nothing.
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(
            for: fixture.task,
            runtime: .claudeCode
        ).contains(Fixture.redcapCredentialLabel(fixture.redcapConnector.id)))
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        // Approving an offer is not a request to rerun the task.
        #expect(fixture.task.status == .completed)
    }

    /// One narrated connector and one reachable-only connector, wired the way a
    /// finished run leaves them: the run is over, the task is not waiting on
    /// anybody, and the broker held one of the two secrets back.
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let store: MockSecretStore
        let workspace: Workspace
        let task: AgentTask
        let jiraConnector: Connector
        let redcapConnector: Connector
        let jiraTurn = "check the open Jira issues for this sprint"
        static let jiraSecret = "jira-secret-token-value"
        static let redcapSecret = "redcap-secret-token-value"

        static func redcapCredentialLabel(_ id: UUID) -> String {
            "connector:\(id.uuidString):REDCAP_API_TOKEN"
        }

        func scope(for turn: String) -> TaskCapabilityPromptScope {
            TaskCapabilityResolutionSnapshot.capture(
                for: task,
                providerLaunchContextText: turn,
                secretStore: store
            ).providerLaunch
        }

        /// A run that ended normally. Nothing here is paused, which is exactly
        /// the state the offer has to survive.
        func finishedRun() -> TaskRun {
            let run = TaskRun(task: task)
            run.status = .completed
            run.completedAt = Date()
            context.insert(run)
            return run
        }

        /// The broker as the run actually saw it: REDCap in the manifest with
        /// its route, its secret withheld, and the observer that turns a tool
        /// call into the narration the launch never had.
        func brokerServer(taskID: UUID, runID: UUID) -> HostControlMCPServer {
            let environment = HostControlBrokerSessionRegistry.brokeredConnectorEnvironment(
                task: task,
                runtime: .claudeCode,
                capabilityScope: scope(for: jiraTurn),
                requiredTools: ["jira", "redcap"],
                secretStore: store
            )
            return HostControlMCPServer(
                configuration: HostControlToolConfiguration(
                    currentDirectory: "/tmp/not-the-export-destination",
                    connectorsJSON: environment["ASTRA_CONNECTORS"] ?? #"{"connectors":[]}"#,
                    environment: environment
                ),
                withholdingObserver: BrokeredCredentialWithholdingRecorder(taskID: taskID, runID: runID)
            )
        }

        init() throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            store = MockSecretStore()
            workspace = Workspace(name: "withheld-credentials", primaryPath: NSTemporaryDirectory())

            let skill = Skill(
                name: "Jira Agent",
                skillDescription: "Review support issues and ticket queues",
                allowedTools: ["Read"],
                behaviorInstructions: "Use Jira to review issues before answering."
            )
            skill.isGlobal = true
            let jira = Connector(
                name: "Jira-new",
                serviceType: "jira",
                connectorDescription: "Atlassian Jira REST API v3",
                baseURL: "https://example.atlassian.net",
                authMethod: "basic"
            )
            jira.isGlobal = true
            jira.skill = skill
            jira.credentialKeys = ["JIRA_API_TOKEN"]
            store.save(
                key: "JIRA_API_TOKEN",
                value: Self.jiraSecret,
                entityID: KeychainSecretStore.connectorEntityID(for: jira.id),
                label: nil
            )
            jiraConnector = jira

            // No skill and no word the turn above can land on, so it is
            // reachable through workspace enablement alone — the production
            // shape of the connector that got called a broken configuration.
            let redcap = Connector(
                name: "Registry Export",
                serviceType: "redcap",
                connectorDescription: "REDCap instrument export endpoint",
                baseURL: "https://redcap.example.edu/api/",
                authMethod: "token"
            )
            redcap.isGlobal = true
            redcap.credentialKeys = ["REDCAP_API_TOKEN"]
            store.save(
                key: "REDCAP_API_TOKEN",
                value: Self.redcapSecret,
                entityID: KeychainSecretStore.connectorEntityID(for: redcap.id),
                label: nil
            )
            redcapConnector = redcap

            workspace.enabledGlobalConnectorIDs = [jira.id.uuidString, redcap.id.uuidString]
            task = AgentTask(
                title: "Support tickets",
                goal: jiraTurn,
                workspace: workspace,
                runtime: .claudeCode
            )
            task.status = .completed
            for model in [workspace, skill, jira, redcap, task] as [any PersistentModel] {
                context.insert(model)
            }
            try context.save()
        }
    }
}
