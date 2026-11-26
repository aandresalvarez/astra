import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// A turn that never names a connector gets its route and not its secret. In
/// Auto, which asks nothing, that used to cost the user the whole turn: ASTRA
/// allowed the connector only after the reply had ended without it. A read now
/// opens it when the agent asks, once ASTRA has saved that it allowed it.
@Suite("Brokered credential opening", .serialized)
@MainActor
struct BrokeredCredentialOpeningTests {
    private typealias Fixture = BrokeredCredentialApprovalLoopTests.Fixture

    private static let openedNotice = "Auto allowed Registry Export to use its saved credentials for this task."

    @Test("Auto opens a held-back connector for a read in the same run, once, and says so")
    func autoOpensAHeldBackConnectorForARead() async throws {
        let session = try Session(level: .autonomous)

        let first = try await session.call("redcap", ["operation": "status"])
        let second = try await session.call("redcap", ["operation": "status"])

        for text in [first, second] {
            #expect(text.contains("api_token_present: true"))
            #expect(text.contains("ready: true"))
            #expect(!text.contains("credentials_withheld"))
            #expect(!text.contains(Fixture.redcapSecret))
        }
        #expect(session.saves.count == 1, "ASTRA is asked once, and saves before the broker uses the value")
        #expect(session.grantedLabels == [session.redcapLabel])
        #expect(session.notices == [Self.openedNotice])

        // The boundary finds the connector already allowed: no second line, no offer.
        RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: session.fixture.task,
            run: session.run,
            modelContext: session.fixture.context,
            policyLevel: .autonomous,
            runFinishedCleanly: true
        )
        #expect(session.notices == [Self.openedNotice])
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: session.fixture.task))
    }

    @Test("Where the level asks, the broker is given nothing to open", arguments: [AgentPolicyLevel.review, .custom])
    func askingLevelsOpenNothing(level: AgentPolicyLevel) async throws {
        let session = try Session(level: level)

        #expect(session.inputs.sealed == nil)
        let text = try await session.call("redcap", ["operation": "status"])

        #expect(text.contains("api_token_present: withheld"))
        #expect(text.contains("ask the user to approve it in ASTRA"))
        #expect(session.saves.count == 0)
        #expect(session.grantedLabels.isEmpty)
        // And the handler itself refuses, whatever it is handed.
        let withheld = try #require(session.withholding(named: "Registry Export"))
        #expect(!session.handler.allowHeldBackConnector(withheld))
        #expect(session.grantedLabels.isEmpty)
    }

    @Test("A grant that cannot be saved, or a run that has ended, opens nothing",
          arguments: [(false, RunStatus.running), (true, RunStatus.completed)])
    func nothingOpensWithoutASavedGrantOnALiveRun(saves: Bool, status: RunStatus) async throws {
        let session = try Session(level: .autonomous, saves: saves)
        session.run.status = status

        let text = try await session.call("redcap", ["operation": "status"])

        #expect(text.contains("api_token_present: withheld"))
        // Auto never sends the user looking for an approval that is not there.
        #expect(text.contains("ask the user to send another message"))
        #expect(!text.contains("ask the user to approve it"))
        #expect(session.saves.count == (status == .running ? 1 : 0))
        #expect(session.grantedLabels.isEmpty)
        #expect(session.notices.isEmpty)
    }

    /// The grant store drops a label it will not keep, and opening unseals every
    /// value of the connector, so a grant for only some of them opens none.
    @Test("A connector with a credential the grant store would drop stays held back")
    func aPartialGrantOpensNothing() async throws {
        let session = try Session(level: .autonomous, extraREDCapKey: "REDCAP_" + String(repeating: "X", count: 200))
        let withheld = try #require(session.withholding(named: "Registry Export"))
        #expect(withheld.credentials.count == 2)

        let text = try await session.call("redcap", ["operation": "status"])

        #expect(text.contains("api_token_present: withheld"))
        #expect(session.saves.count == 0)
        #expect(session.grantedLabels.isEmpty)
        #expect(session.notices.isEmpty)
    }

    @Test("A Jira write stays held back for the run, before and after a read opens the connector")
    func writesStayHeldBack() async throws {
        let session = try Session(level: .autonomous)
        let proposal = ["operation": "propose_comment", "issue_key": "ABC-1", "body": "Looking into it."]

        let before = try await session.call("jira", proposal)
        #expect(before.contains("credentials_withheld: true"))
        #expect(session.saves.count == 0, "composing a write never opens a connector")

        let read = try await session.call("jira", ["operation": "status"])
        #expect(read.contains("api_token_present: true"))
        #expect(session.saves.count == 1)

        // Still held back, and no longer claiming the connector is not allowed.
        let alias = try #require(session.withholding(named: "Jira-new")).alias
        let after = try await session.call("jira", proposal)
        #expect(after.contains("credentials_withheld: true"))
        #expect(after.contains("ASTRA has already allowed '\(alias)' for this task"))
        #expect(after.contains("ask the user to send another message"))
        #expect(session.saves.count == 1)
    }

    /// `status` only shows a value is there. These send requests, so a handler
    /// that opened the connector and then served the read, or redacted its
    /// reply, with the launch's configuration fails here.
    @Test("An opened read authenticates with the connector's credential and never repeats it")
    func openedReadsAuthenticateAndRedact() async throws {
        HostControlURLSessionConfiguration.registerTestingProtocolClass(OpeningEchoURLProtocol.self)
        defer { HostControlURLSessionConfiguration.unregisterTestingProtocolClass(OpeningEchoURLProtocol.self) }
        let session = try Session(level: .autonomous)

        let jira = try await session.call("jira", ["operation": "get_issue", "issue_key": "ABC-1"])
        let redcap = try await session.call("redcap", ["operation": "project"])

        // The stub answers with whatever credential the request carried.
        #expect(jira.contains("echo [redacted]"), "\(jira)")
        #expect(!jira.contains(Fixture.jiraSecret))
        #expect(redcap.contains("echo [redacted]"), "\(redcap)")
        #expect(!redcap.contains(Fixture.redcapSecret))
        #expect(session.saves.count == 2)
    }

    /// The relay stops listening 305 seconds after a call. A wait for ASTRA added
    /// on top of a 300-second read would outlast it.
    @Test("The time spent opening a connector comes out of the read's timeout", arguments: ["jira", "redcap"])
    func openingTimeComesOutOfTheReadTimeout(tool: String) async throws {
        HostControlURLSessionConfiguration.registerTestingProtocolClass(OpeningEchoURLProtocol.self)
        defer { HostControlURLSessionConfiguration.unregisterTestingProtocolClass(OpeningEchoURLProtocol.self) }
        let session = try Session(level: .autonomous, whileSaving: { Thread.sleep(forTimeInterval: 1.1) })
        var arguments = tool == "jira" ? ["operation": "get_issue", "issue_key": "ABC-1"] : ["operation": "project"]
        arguments["timeout_seconds"] = "300"

        let opening = try await session.call(tool, arguments)
        let afterwards = try await session.call(tool, arguments)

        // A busier machine only waits longer, so the bound holds under load.
        let shortened = try #require(Self.timeoutTheStubSaw(opening), "\(opening)")
        #expect(shortened <= 298)
        #expect(Self.timeoutTheStubSaw(afterwards) == 300, "\(afterwards)")

        let limits = HostControlProcessLimits.standard
        #expect(limits.readTimeout(300, afterWaiting: 60) == 240)
        #expect(limits.readTimeout(120, afterWaiting: 60) == 120, "a shorter read still fits")
        #expect(limits.readTimeout(300, afterWaiting: 400) == 1)
    }

    private static func timeoutTheStubSaw(_ reply: String) -> Int? {
        reply.firstMatch(of: #/timeout (\d+)/#).flatMap { Int($0.1) }
    }

    @Test("A second account of one service stays held back until it is read too")
    func openingOneAccountLeavesTheOtherHeldBack() async throws {
        let session = try Session(level: .autonomous, secondREDCapSecret: "second-redcap-secret-value")
        let second = try #require(session.withholding(named: "Study Export"))
        let first = try #require(session.withholding(named: "Registry Export"))

        let sealed = try #require(session.inputs.sealed)
        let opened = try #require(session.launch.opening(first, from: sealed))
        #expect(!opened.environment.values.contains("second-redcap-secret-value"))

        _ = try await session.call("redcap", ["operation": "status", "alias": first.alias])
        #expect(session.saves.count == 1)
        let reply = try await session.call("redcap", ["operation": "status", "alias": second.alias])
        #expect(reply.contains("api_token_present: true"))
        #expect(session.saves.count == 2, "each account is allowed by its own read")
    }

    /// The broker's wait is bounded, so the save can land after it gave up. That
    /// grant is durable, and the next call must use it without a second one.
    @Test("A grant that lands after the broker stopped waiting serves the next call")
    func lateGrantServesTheNextCall() async throws {
        let brokerAnswered = DispatchSemaphore(value: 0)
        let session = try Session(level: .autonomous, timeout: 0.2, whileSaving: {
            // Holds the main actor until the broker has replied without it.
            _ = brokerAnswered.wait(timeout: .now() + 30)
        })

        let first = try await session.call("redcap", ["operation": "status"], replied: brokerAnswered)
        // Counts calls, not seconds: a busy main actor may miss the short wait again.
        var next = ""
        for _ in 0..<100 where !next.contains("api_token_present: true") {
            next = try await session.call("redcap", ["operation": "status"])
        }

        #expect(first.contains("api_token_present: withheld"))
        #expect(next.contains("api_token_present: true"))
        #expect(session.saves.count == 1)
        #expect(session.notices == [Self.openedNotice])
    }

    /// Aliases and display names are user-entered and can collide, so the account
    /// already chosen is opened by its ID rather than looked up again by name.
    @Test("An account whose alias is another account's display name still opens")
    func openingKeepsTheChosenAccount() throws {
        let held = try Self.collidingAccounts(requester: StubRequester())

        let access = held.opener.access(toRead: held.chosen, in: held.launch)

        #expect(access.connector.id == "c1")
        #expect(access.configuration.environment["A_TOKEN"] == "held-value")
    }

    /// A connector can be usable as launched and still hold something back, so
    /// the wait comes out of that read's timeout even when nothing is allowed.
    @Test("A refused opening still counts the time it waited")
    func aRefusedOpeningStillCountsTheWait() throws {
        let held = try Self.collidingAccounts(requester: StubRequester(allows: false, delay: 0.05))

        let access = held.opener.access(toRead: held.chosen, in: held.launch)

        #expect(access.configuration.environment["A_TOKEN"] == nil)
        #expect(access.waitedSeconds >= 0.049)
    }

    /// Two accounts built by hand, the first held back and the second named with
    /// the first's alias.
    private static func collidingAccounts(
        requester: StubRequester
    ) throws -> (opener: BrokeredCredentialOpener, launch: HostControlToolConfiguration, chosen: HostControlConnector) {
        func manifest(credentials: String) -> String {
            """
            {"connectors":[{"id":"c1","alias":"study","envPrefix":"A","name":"Registry","serviceType":"redcap",\
            "baseURL":"https://redcap.opening.test/api/","authMethod":"token","env":{},\
            "credentials":{\(credentials)},"config":{}},{"id":"c2","alias":"other","envPrefix":"B","name":"study",\
            "serviceType":"redcap","baseURL":"https://redcap.opening.test/api/","authMethod":"token","env":{},\
            "credentials":{},"config":{}}]}
            """
        }
        let held = manifest(credentials: "")
        let marker = """
        {"version":1,"connectors":[{"connectorID":"c1","alias":"study","name":"Registry","serviceType":"redcap",\
        "toolName":"redcap","credentials":[{"key":"REDCAP_API_TOKEN","envKey":"A_TOKEN",\
        "logicalName":"REDCAP_API_TOKEN"}]}]}
        """
        let launch = HostControlToolConfiguration(
            connectorsJSON: held,
            environment: [BrokeredConnectorCredentialWithholdingManifest.environmentKey: marker]
        )
        let chosen = try #require(HostControlBrokeredServices.resolveConnector(
            forServiceType: "redcap", alias: "c1", in: launch
        ).connector)
        let opener = BrokeredCredentialOpener(
            sealed: BrokeredSealedCredentials(
                connectorsJSON: manifest(credentials: #""REDCAP_API_TOKEN":"A_TOKEN""#),
                environment: ["A_TOKEN": "held-value"]
            ),
            requester: requester
        )
        return (opener, launch, chosen)
    }

    private struct StubRequester: BrokeredExternalActionRequesting {
        var allows = true
        var delay: TimeInterval = 0
        var mayAllowHeldBackConnectors: Bool { true }

        func allowHeldBackConnector(_: BrokeredConnectorCredentialWithholding) -> Bool {
            Thread.sleep(forTimeInterval: delay)
            return allows
        }
        func sendStagedConnectorMutation(_: StagedConnectorMutationRequest) -> BrokeredExternalActionOutcome {
            .awaitingReview
        }
        func postGitHubReview(_: GitHubReviewPostRequest) -> BrokeredExternalActionOutcome { .awaitingReview }
    }

    @Test("Held-back values stay out of the broker's environment, and opening one adds only its own")
    func openingAddsOnlyThatConnectorsValues() throws {
        let session = try Session(level: .autonomous)
        let sealed = try #require(session.inputs.sealed)

        // What every host process the broker starts would inherit.
        #expect(!session.inputs.environment.values.contains(Fixture.redcapSecret))
        #expect(!session.inputs.environment.values.contains(Fixture.jiraSecret))

        let withheld = try #require(session.withholding(named: "Registry Export"))
        let opened = try #require(session.launch.opening(withheld, from: sealed))
        #expect(opened.environment.values.contains(Fixture.redcapSecret))
        #expect(!opened.environment.values.contains(Fixture.jiraSecret))
        // An opened value is redacted like any other.
        #expect(opened.redacted("token=\(Fixture.redcapSecret)") == "token=[redacted]")
    }

    /// One live run on a turn that names neither connector, with the broker built
    /// the way `HostControlBrokerSessionRegistry` builds it.
    @MainActor
    private struct Session {
        let fixture: Fixture
        let run: TaskRun
        let handler: BrokeredExternalActionHandler
        let inputs: HostControlBrokerSessionRegistry.BrokeredConnectorBrokerInputs
        let launch: HostControlToolConfiguration
        let saves: SaveCount
        private let server: ServerBox

        init(
            level: AgentPolicyLevel,
            saves shouldSave: Bool = true,
            timeout: TimeInterval = BrokeredExternalActionBridge.defaultTimeoutSeconds,
            secondREDCapSecret: String? = nil,
            extraREDCapKey: String? = nil,
            whileSaving: @escaping @MainActor () -> Void = {}
        ) throws {
            fixture = try Fixture()
            // Hosts only this suite's stub answers, and the email Jira needs
            // beside its token before a read can be sent.
            fixture.jiraConnector.baseURL = "https://jira.opening.test"
            fixture.redcapConnector.baseURL = "https://redcap.opening.test/api/"
            fixture.jiraConnector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
            fixture.store.save(
                key: "JIRA_EMAIL",
                value: "someone@example.test",
                entityID: KeychainSecretStore.connectorEntityID(for: fixture.jiraConnector.id),
                label: nil
            )
            if let secondREDCapSecret {
                let second = Connector(
                    name: "Study Export",
                    serviceType: "redcap",
                    connectorDescription: "Second REDCap export endpoint",
                    baseURL: "https://redcap.opening.test/api/",
                    authMethod: "token"
                )
                second.isGlobal = true
                second.credentialKeys = ["REDCAP_API_TOKEN"]
                fixture.store.save(
                    key: "REDCAP_API_TOKEN",
                    value: secondREDCapSecret,
                    entityID: KeychainSecretStore.connectorEntityID(for: second.id),
                    label: nil
                )
                fixture.context.insert(second)
                fixture.workspace.enabledGlobalConnectorIDs.append(second.id.uuidString)
            }
            if let extraREDCapKey {
                fixture.redcapConnector.credentialKeys.append(extraREDCapKey)
                fixture.store.save(
                    key: extraREDCapKey,
                    value: "extra-redcap-secret-value",
                    entityID: KeychainSecretStore.connectorEntityID(for: fixture.redcapConnector.id),
                    label: nil
                )
            }
            let run = TaskRun(task: fixture.task)
            fixture.context.insert(run)
            try fixture.context.save()
            self.run = run
            let saves = SaveCount()
            self.saves = saves
            handler = BrokeredExternalActionHandler(
                modelContext: fixture.context,
                taskID: fixture.task.id,
                runID: run.id,
                policyLevel: level,
                persistGrant: { _, _ in
                    saves.count += 1
                    whileSaving()
                    return shouldSave
                }
            )
            let bridge = BrokeredExternalActionBridge(handler: handler, timeoutSeconds: timeout)
            inputs = HostControlBrokerSessionRegistry.brokeredConnectorInputs(
                task: fixture.task,
                runtime: .claudeCode,
                capabilityScope: fixture.scope(for: Fixture.unrelatedTurn),
                requiredTools: ["jira", "redcap"],
                opensWithoutApproval: bridge.mayAllowHeldBackConnectors,
                secretStore: fixture.store
            )
            launch = HostControlToolConfiguration(
                currentDirectory: "/tmp/not-the-export-destination",
                connectorsJSON: inputs.environment["ASTRA_CONNECTORS"] ?? #"{"connectors":[]}"#,
                environment: inputs.environment
            )
            server = ServerBox(server: HostControlMCPServer(
                configuration: launch,
                withholdingObserver: BrokeredCredentialWithholdingRecorder(taskID: fixture.task.id, runID: run.id),
                externalActionRequester: bridge,
                sealedCredentials: inputs.sealed
            ))
        }

        var redcapLabel: String { Fixture.redcapCredentialLabel(fixture.redcapConnector.id) }

        var grantedLabels: [String] {
            TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .claudeCode)
        }

        var notices: [String] {
            fixture.task.events.map(\.payload).filter { $0.hasPrefix("Auto allowed") }
        }

        func withholding(named name: String) -> BrokeredConnectorCredentialWithholding? {
            launch.withheldConnectorCredentials.connectors.first { $0.name == name }
        }

        /// Off the main thread, as the broker calls: opening waits on it.
        func call(
            _ tool: String,
            _ arguments: [String: String],
            replied: DispatchSemaphore? = nil
        ) async throws -> String {
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": tool, "arguments": arguments]
            ]
            let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            let server = server
            let reply: String = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let reply = server.server.handleLine(line) ?? ""
                    replied?.signal()
                    continuation.resume(returning: reply)
                }
            }
            let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let result = try #require(object["result"] as? [String: Any], "\(reply)")
            let content = try #require(result["content"] as? [[String: Any]])
            return try #require(content.first?["text"] as? String)
        }
    }

    @MainActor
    private final class SaveCount {
        var count = 0
    }

    private struct ServerBox: @unchecked Sendable {
        let server: HostControlMCPServer
    }
}

/// Answers this suite's two hosts, repeating back the credential the request
/// carried, so a reply that is not redacted shows it, and its timeout.
private final class OpeningEchoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["jira.opening.test", "redcap.opening.test"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            return
        }
        let credential = url.host == "jira.opening.test" ? jiraToken() : redcapToken()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("echo \(credential) timeout \(Int(request.timeoutInterval))".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The token half of the Basic header.
    private func jiraToken() -> String {
        guard let header = request.value(forHTTPHeaderField: "Authorization"),
              let data = Data(base64Encoded: String(header.dropFirst("Basic ".count))) else {
            return "<none>"
        }
        return String(decoding: data, as: UTF8.self).split(separator: ":").last.map(String.init) ?? "<none>"
    }

    /// The `token` field of the form body, which URLSession hands over as a stream.
    private func redcapToken() -> String {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let fields = String(decoding: body, as: UTF8.self).split(separator: "&")
        return fields.first { $0.hasPrefix("token=") }.map { String($0.dropFirst("token=".count)) } ?? "<none>"
    }
}
