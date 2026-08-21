import CryptoKit
import Foundation
import Testing
import ASTRACore
@testable import ASTRA
@testable import HostControlToolSupport

/// Covers the half of a connector write the agent is allowed to do: compose a
/// payload and stage it. Nothing here may reach Jira, and the tests assert that
/// directly rather than trusting the handler's shape — `capturedURLs` is empty
/// on every proposal path.
@Suite("Connector Mutation Staging", .serialized)
struct ConnectorMutationStagingTests {
    // MARK: - Staging

    @Test("Proposing an issue stages a payload and sends nothing")
    func proposingAnIssueStagesAPayloadAndSendsNothing() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue",
            "project_key": "STAR",
            "issue_type": "Bug",
            "summary": "De-identification drops the age filter on three domains",
            "description": "dose_era, cost, and specimen have no age filter at all.",
            "labels": ["deid", "privacy", "hipaa"]
        ])

        let text = try resultText(response)
        #expect(text.contains("staged_operation: create_issue"))
        #expect(text.contains("target: STAR / Bug"))
        #expect(text.contains("sent: false"))
        // The whole point: the broker composed a write and did not perform it.
        #expect(JiraProposalCaptureURLProtocol.capturedURLs.isEmpty)

        let path = try #require(value(of: "staged_path", in: text))
        let digest = try #require(value(of: "request_digest", in: text))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest)
    }

    @Test("The staged envelope carries the create request ASTRA will send")
    func stagedEnvelopeCarriesTheCreateRequest() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue",
            "project_key": "STAR",
            "issue_type": "Bug",
            "summary": "Age filter missing",
            "description": "Body text",
            "priority": "Highest",
            "labels": ["age90"],
            "assignee_account_id": "5dc098e4a693ee0df50f941c",
            "parent_key": "STAR-12558"
        ])
        let path = try #require(value(of: "staged_path", in: try resultText(response)))

        let staged = try ConnectorMutationStaging.read(atPath: path, containedIn: folder)
        #expect(staged.serviceType == "jira")
        // Named for what ASTRA will do, not for what the agent called.
        #expect(staged.operation == "create_issue")
        #expect(staged.connectorID == "jira-1")
        #expect(staged.target == "STAR / Bug")
        #expect(staged.requestMethod == "POST")
        // v2, so Jira renders the description instead of demanding ADF JSON.
        #expect(staged.requestPath == "/rest/api/2/issue")

        let body = try #require(
            try JSONSerialization.jsonObject(with: staged.requestBody) as? [String: Any]
        )
        let fields = try #require(body["fields"] as? [String: Any])
        #expect((fields["project"] as? [String: String])?["key"] == "STAR")
        #expect((fields["issuetype"] as? [String: String])?["name"] == "Bug")
        #expect(fields["summary"] as? String == "Age filter missing")
        #expect(fields["description"] as? String == "Body text")
        #expect((fields["priority"] as? [String: String])?["name"] == "Highest")
        #expect(fields["labels"] as? [String] == ["age90"])
        #expect((fields["assignee"] as? [String: String])?["accountId"] == "5dc098e4a693ee0df50f941c")
        #expect((fields["parent"] as? [String: String])?["key"] == "STAR-12558")
    }

    @Test("Two proposals in one run stage two files")
    func twoProposalsInOneRunStageTwoFiles() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let first = try resultText(try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue", "project_key": "STAR", "issue_type": "Bug", "summary": "One"
        ]))
        let second = try resultText(try call(server, id: 2, tool: "jira", arguments: [
            "operation": "propose_issue", "project_key": "STAR", "issue_type": "Bug", "summary": "Two"
        ]))

        // A second proposal must not overwrite the first: the user may still be
        // reading it, and the approval is bound to bytes at a path.
        #expect(value(of: "staged_path", in: first) != value(of: "staged_path", in: second))
        #expect(value(of: "request_digest", in: first) != value(of: "request_digest", in: second))
        #expect(JiraProposalCaptureURLProtocol.capturedURLs.isEmpty)
    }

    @Test("Staging refuses when no task folder is projected")
    func stagingRefusesWithoutATaskFolder() throws {
        let server = try proposalServer(taskFolder: "")
        defer { endCapture() }

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue", "project_key": "STAR", "issue_type": "Bug", "summary": "Nowhere to put it"
        ])

        // No fallback to the working directory: a proposal ASTRA cannot find is
        // one the user can never approve, and staging it anyway would report
        // success for a write that can never happen.
        let text = try resultText(response)
        #expect(text.contains("could not be staged"))
        #expect(text.contains("task folder"))
        #expect(JiraProposalCaptureURLProtocol.capturedURLs.isEmpty)
    }

    // MARK: - Digest binding

    @Test("An approval is bound to the exact staged bytes")
    func approvalIsBoundToTheExactStagedBytes() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let text = try resultText(try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue",
            "project_key": "STAR",
            "issue_type": "Bug",
            "summary": "Reviewed title"
        ]))
        let path = try #require(value(of: "staged_path", in: text))
        let digest = try #require(value(of: "request_digest", in: text))

        // The digest the user approved still reads back before anything changes.
        #expect(try ConnectorMutationStaging.read(
            atPath: path, containedIn: folder, expectedDigest: digest
        ).summary == "Reviewed title")

        let rewritten = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .replacingOccurrences(of: "Reviewed title", with: "Rewritten title")
        try Data(rewritten.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

        #expect(throws: ConnectorMutationStagingError.self) {
            try ConnectorMutationStaging.read(atPath: path, containedIn: folder, expectedDigest: digest)
        }
    }

    @Test("A staged mutation outside the task's staging directory is refused")
    func stagedMutationOutsideTheStagingDirectoryIsRefused() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let stray = URL(fileURLWithPath: folder).appendingPathComponent("stray.json")
        try Data(#"{"schema_version":1}"#.utf8).write(to: stray)

        // Reading a path out of an authorization without proving where it lives
        // is how a rewritten path becomes an arbitrary-file read.
        #expect(throws: ConnectorMutationStagingError.self) {
            try ConnectorMutationStaging.read(atPath: stray.path, containedIn: folder)
        }
    }

    // MARK: - Field gating

    @Test("Proposing refuses arguments it does not understand")
    func proposingRefusesUnknownArguments() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let response = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue",
            "project_key": "STAR",
            "issue_type": "Bug",
            "summary": "Restricted",
            "security": "Internal only"
        ])

        // Refused, not dropped. A silently ignored field is a ticket the agent
        // reports as restricted and the user receives as public.
        #expect(try errorMessage(response).contains("does not accept security"))
    }

    @Test("Proposing rejects malformed fields before anything is staged")
    func proposingRejectsMalformedFields() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let lowercaseProject = try call(server, id: 1, tool: "jira", arguments: [
            "operation": "propose_issue", "project_key": "star", "issue_type": "Bug", "summary": "x"
        ])
        #expect(try errorMessage(lowercaseProject).contains("requires a project_key"))

        let spacedLabel = try call(server, id: 2, tool: "jira", arguments: [
            "operation": "propose_issue", "project_key": "STAR", "issue_type": "Bug",
            "summary": "x", "labels": ["two words"]
        ])
        #expect(try errorMessage(spacedLabel).contains("labels must each be a single word"))

        let multilineSummary = try call(server, id: 3, tool: "jira", arguments: [
            "operation": "propose_issue", "project_key": "STAR", "issue_type": "Bug",
            "summary": "first\nsecond"
        ])
        #expect(try errorMessage(multilineSummary).contains("single-line summary"))

        #expect(!FileManager.default.fileExists(
            atPath: ConnectorMutationStaging.stagingDirectory(taskFolder: folder).path
        ))
        #expect(JiraProposalCaptureURLProtocol.capturedURLs.isEmpty)
    }

    @Test("The read gate still refuses the operation ASTRA commits")
    func readGateStillRefusesTheCommitOperation() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        // `create_issue` is the name of what ASTRA does after approval. The
        // agent naming it directly must stay unsupported, or the propose/commit
        // split is one typo wide.
        for operation in ["create_issue", "create", "request"] {
            let response = try call(server, id: 1, tool: "jira", arguments: ["operation": operation])
            #expect(try errorMessage(response).contains("Unsupported Jira operation '\(operation)'"))
        }
        #expect(JiraProposalCaptureURLProtocol.capturedURLs.isEmpty)
    }

    // MARK: - Grant semantics

    @Test("A mutation approval is single-use and never reaches the provider")
    func mutationApprovalIsSingleUseAndNeverReachesTheProvider() {
        let grant = PermissionGrant.connectorMutation(authorization: authorization())

        // Well-formed, so it is allowed into the ledger at all.
        #expect(PermissionBroker.sanitizeApprovedGrants([grant]) == [grant])
        // ...but it is spent when used. Carrying it into task scope would mean
        // the second ticket is authorized by the user having read the first.
        #expect(PermissionBroker.taskScopedApprovalGrants(for: [grant]).isEmpty)
        // ...and it is never handed to the provider as an allow-string, which
        // would make it durable for the whole run.
        for adapter in [ClaudePolicyAdapter(), CopilotPolicyAdapter()] as [any ProviderPolicyAdapter] {
            #expect(adapter.providerGrantStrings(for: [grant]).isEmpty)
        }
    }

    @Test("A malformed mutation approval never enters the ledger")
    func malformedMutationApprovalNeverEntersTheLedger() {
        let cases: [(String, ConnectorMutationAuthorization)] = [
            ("short digest", authorization(digest: String(repeating: "a", count: 40))),
            ("non-hex digest", authorization(digest: String(repeating: "z", count: 64))),
            // No in-process credential means no commit path, so an approval for
            // it is one the user was asked to read for nothing.
            ("unbrokered service", authorization(serviceType: "github")),
            ("relative path", authorization(path: "connector-mutations/jira-create_issue-r-1.json")),
            ("path outside staging", authorization(path: "/tmp/task/jira-create_issue-r-1.json")),
            ("traversal", authorization(path: "/tmp/task/connector-mutations/../../etc/passwd.json")),
            ("operation with a slash", authorization(operation: "create/issue"))
        ]
        for (label, authorization) in cases {
            let grant = PermissionGrant.connectorMutation(authorization: authorization)
            #expect(PermissionBroker.sanitizeApprovedGrants([grant]).isEmpty, "\(label) was admitted")
        }
    }

    // MARK: - Fixtures

    private func authorization(
        serviceType: String = "jira",
        operation: String = "create_issue",
        path: String = "/tmp/task/connector-mutations/jira-create_issue-run-1.json",
        digest: String = String(repeating: "a", count: 64)
    ) -> ConnectorMutationAuthorization {
        ConnectorMutationAuthorization(
            connectorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            serviceType: serviceType,
            operation: operation,
            target: "STAR / Bug",
            stagedPayloadPath: path,
            requestDigest: digest
        )
    }

    private func temporaryTaskFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-connector-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func proposalServer(taskFolder: String) throws -> HostControlMCPServer {
        JiraProposalCaptureURLProtocol.reset()
        HostControlURLSessionConfiguration.registerTestingProtocolClass(JiraProposalCaptureURLProtocol.self)
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira",\
        "serviceType":"jira","baseURL":"https://jira.proposal.test","authMethod":"basic",\
        "env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},\
        "credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        return HostControlMCPServer(configuration: HostControlToolConfiguration(
            taskFolder: taskFolder,
            runID: "run-1",
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        ))
    }

    private func endCapture() {
        HostControlURLSessionConfiguration.unregisterTestingProtocolClass(JiraProposalCaptureURLProtocol.self)
        JiraProposalCaptureURLProtocol.reset()
    }

    private func value(of key: String, in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)) }
    }

    private func call(
        _ server: HostControlMCPServer, id: Int, tool: String, arguments: [String: Any]
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
        return try #require(
            try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
    }

    private func resultText(_ object: [String: Any]) throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func errorMessage(_ object: [String: Any]) throws -> String {
        let error = try #require(object["error"] as? [String: Any])
        return try #require(error["message"] as? String)
    }
}

/// Fails any request that reaches it. A proposal that produced a URL at all is
/// the bug this suite exists to catch, so the stub returns an error rather than
/// a plausible Jira response.
private final class JiraProposalCaptureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URL] = []

    static var capturedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func reset() {
        lock.lock()
        captured = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "jira.proposal.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.captured.append(url)
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
