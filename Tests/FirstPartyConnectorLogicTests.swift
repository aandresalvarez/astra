import Testing
import Foundation
@testable import ASTRA
import ASTRACore

// Pure-logic coverage for first-party connector services: Jira auth-test
// response classification (via a stubbed transport), Cardinal Key subject
// matching, Stanford Outlook mail constants and registry round-trip, and
// Google Docs document parsing. No network, no keychain.

// MARK: - Stub transport

private struct StubJiraTransport: ConnectorHTTPTransport {
    enum Reply {
        case http(Int, Data, headers: [String: String] = [:])
        case failure(Error)
    }

    let replies: [String: Reply]  // keyed by URL path

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        guard let reply = replies[url.path] else {
            throw URLError(.unsupportedURL)
        }
        switch reply {
        case .http(let status, let data, let headers):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

private func permissionsJSON(_ permissions: [String: Bool]) -> Data {
    let body = permissions.map { "\"\($0.key)\":{\"havePermission\":\($0.value)}" }.joined(separator: ",")
    return Data("{\"permissions\":{\(body)}}".utf8)
}

private func makeTester(
    config: [String: String] = [:],
    replies: [String: StubJiraTransport.Reply]
) -> JiraConnectorAuthTester {
    JiraConnectorAuthTester(
        connectorID: UUID(),
        baseURL: URL(string: "https://jira.example.com")!,
        authMethod: "basic",
        credentials: ["JIRA_EMAIL": "u@example.com", "JIRA_API_TOKEN": "t"],
        config: config,
        transport: StubJiraTransport(replies: replies)
    )
}

@Suite("FirstPartyConnector Jira Classification")
struct FirstPartyConnectorJiraClassificationTests {

    @Test("200 with BROWSE_PROJECTS and no configured projects authenticates")
    func authenticatedNoProjects() async {
        let tester = makeTester(replies: [
            "/rest/api/3/mypermissions": .http(200, permissionsJSON(["BROWSE_PROJECTS": true]))
        ])
        let outcome = await tester.test()
        #expect(outcome.success)
        #expect(outcome.level == .info)
        #expect(outcome.fields["result"] == "authenticated")
        #expect(outcome.fields["credential_state"] == "authenticated")
        #expect(outcome.fields["auth_verified"] == "true")
        #expect(outcome.fields["project_count"] == "0")
    }

    @Test("200 without BROWSE_PROJECTS reports missing permission")
    func missingGlobalPermission() async {
        let tester = makeTester(replies: [
            "/rest/api/3/mypermissions": .http(200, permissionsJSON(["BROWSE_PROJECTS": false]))
        ])
        let outcome = await tester.test()
        #expect(!outcome.success)
        #expect(outcome.fields["result"] == "missing_permission")
        #expect(outcome.fields["permission"] == "BROWSE_PROJECTS")
        // Authenticated but underprivileged still counts as verified auth.
        #expect(outcome.fields["credential_state"] == "authenticated")
    }

    @Test("401 on both probes classifies as auth failure with seraph reason")
    func authFailedBothProbes() async {
        let tester = makeTester(replies: [
            "/rest/api/3/mypermissions": .http(401, Data()),
            "/rest/api/3/myself": .http(
                401, Data(), headers: ["X-Seraph-LoginReason": "AUTHENTICATED_FAILED"]
            )
        ])
        let outcome = await tester.test()
        #expect(!outcome.success)
        #expect(outcome.fields["result"] == "auth_failed")
        #expect(outcome.fields["credential_state"] == "rejected")
        #expect(outcome.fields["auth_verified"] == "false")
        #expect(outcome.fields["seraph_loginreason"] == "AUTHENTICATED_FAILED")
        #expect(outcome.fields["primary_http_status"] == "401")
    }

    @Test("403 on permissions with 200 on myself classifies as scope failure")
    func scopeFailureWithMyselfFallback() async {
        let tester = makeTester(replies: [
            "/rest/api/3/mypermissions": .http(403, Data()),
            "/rest/api/3/myself": .http(200, Data("{}".utf8))
        ])
        let outcome = await tester.test()
        #expect(!outcome.success)
        #expect(outcome.fields["result"] == "endpoint_scope_failure")
        #expect(outcome.fields["credential_state"] == "authenticated")
        #expect(outcome.fields["fallback_endpoint_kind"] == "jira.myself")
        #expect(outcome.fields["fallback_http_status"] == "200")
    }

    @Test("Project not visible: configured project missing BROWSE_PROJECTS")
    func projectNotVisible() async {
        // Global probe succeeds; the scoped per-project probe (same path,
        // different query) returns 404 → project_not_visible.
        let scoped404 = JiraConnectorAuthTester(
            connectorID: UUID(),
            baseURL: URL(string: "https://jira.example.com")!,
            authMethod: "basic",
            credentials: ["JIRA_EMAIL": "u", "JIRA_API_TOKEN": "t"],
            config: ["JIRA_PROJECTS": "abc"],
            transport: SequencedJiraTransport(replies: [
                .http(200, permissionsJSON(["BROWSE_PROJECTS": true])),
                .http(404, Data())
            ])
        )
        let outcome = await scoped404.test()
        #expect(!outcome.success)
        #expect(outcome.fields["result"] == "project_not_visible")
        #expect(outcome.fields["endpoint_kind"] == "jira.project_permissions")
        #expect(outcome.fields["project_count"] == "1")
    }

    @Test("Project missing CREATE_ISSUES reports scoped missing permission")
    func projectMissingCreateIssues() async {
        let tester = JiraConnectorAuthTester(
            connectorID: UUID(),
            baseURL: URL(string: "https://jira.example.com")!,
            authMethod: "basic",
            credentials: ["JIRA_EMAIL": "u", "JIRA_API_TOKEN": "t"],
            config: ["JIRA_PROJECTS": " abc , "],
            transport: SequencedJiraTransport(replies: [
                .http(200, permissionsJSON(["BROWSE_PROJECTS": true])),
                .http(200, permissionsJSON(["BROWSE_PROJECTS": true, "CREATE_ISSUES": false]))
            ])
        )
        let outcome = await tester.test()
        #expect(outcome.fields["result"] == "missing_permission")
        #expect(outcome.fields["permission"] == "CREATE_ISSUES")
        #expect(outcome.fields["project_count"] == "1")
    }

    @Test("Transport failure classifies as request_failed with unknown credentials")
    func networkFailure() async {
        let tester = makeTester(replies: [
            "/rest/api/3/mypermissions": .failure(URLError(.notConnectedToInternet))
        ])
        let outcome = await tester.test()
        #expect(!outcome.success)
        #expect(outcome.fields["result"] == "request_failed")
        #expect(outcome.fields["credential_state"] == "unknown")
        #expect(outcome.fields["http_status"] == nil)
    }

    @Test("404 on permission endpoint reports endpoint_unavailable")
    func endpointUnavailable() async {
        let tester = makeTester(replies: [
            "/rest/api/3/mypermissions": .http(404, Data())
        ])
        let outcome = await tester.test()
        #expect(outcome.fields["result"] == "endpoint_unavailable")
        #expect(outcome.fields["http_status"] == "404")
        #expect(outcome.fields["credential_state"] == "unknown")
    }
}

/// Returns canned replies in order regardless of path, so two probes to the
/// same endpoint path can return different responses.
private final class SequencedJiraTransport: ConnectorHTTPTransport, @unchecked Sendable {
    private var replies: [StubJiraTransport.Reply]
    private let lock = NSLock()

    init(replies: [StubJiraTransport.Reply]) {
        self.replies = replies
    }

    private func nextReply() -> StubJiraTransport.Reply? {
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? nil : replies.removeFirst()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let reply = nextReply() else { throw URLError(.unsupportedURL) }
        switch reply {
        case .http(let status, let data, let headers):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

@Suite("FirstPartyConnector Request Builder")
struct FirstPartyConnectorRequestBuilderTests {

    @Test("URL builder joins base path, child path, and query items")
    func urlJoining() {
        let base = URL(string: "https://example.com/jira")!
        let url = ConnectorRequestBuilder.url(
            base: base,
            path: "/rest/api/3/myself?expand=groups",
            queryItems: [URLQueryItem(name: "x", value: "1")]
        )
        #expect(url.path == "/jira/rest/api/3/myself")
        let query = url.query ?? ""
        #expect(query.contains("expand=groups"))
        #expect(query.contains("x=1"))
    }

    @Test("Basic auth header is the base64 email:token pair")
    func basicAuthHeader() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        ConnectorRequestBuilder.applyAuthentication(
            authMethod: "basic",
            credentials: ["JIRA_EMAIL": "u@example.com", "JIRA_API_TOKEN": "tok"],
            to: &request
        )
        let expected = "Basic \(Data("u@example.com:tok".utf8).base64EncodedString())"
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test("Bearer and unknown auth methods")
    func bearerAndUnknownAuth() {
        var bearer = URLRequest(url: URL(string: "https://example.com")!)
        ConnectorRequestBuilder.applyAuthentication(
            authMethod: "bearer", credentials: ["API_TOKEN": "tok"], to: &bearer
        )
        #expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        var none = URLRequest(url: URL(string: "https://example.com")!)
        ConnectorRequestBuilder.applyAuthentication(
            authMethod: "none", credentials: ["API_TOKEN": "tok"], to: &none
        )
        #expect(none.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Suite("FirstPartyConnector Cardinal Key")
struct FirstPartyConnectorCardinalKeyTests {
    // Keychain identity lookup requires real SecIdentity items; only the
    // pure host/subject predicates are testable here.

    @Test("Stanford host matching")
    func stanfordHosts() {
        #expect(CardinalKeyClientCertificateProvider.isStanfordHost("stanford.edu"))
        #expect(CardinalKeyClientCertificateProvider.isStanfordHost("WWW.Stanford.EDU"))
        #expect(CardinalKeyClientCertificateProvider.isStanfordHost("login.stanford.edu"))
        #expect(!CardinalKeyClientCertificateProvider.isStanfordHost("notstanford.edu"))
        #expect(!CardinalKeyClientCertificateProvider.isStanfordHost("stanford.edu.evil.com"))
        #expect(!CardinalKeyClientCertificateProvider.isStanfordHost(""))
    }

    @Test("Cardinal Key subject matching")
    func cardinalKeySubjects() {
        #expect(CardinalKeyClientCertificateProvider.isCardinalKeySubject("jdoe/enrollment"))
        #expect(CardinalKeyClientCertificateProvider.isCardinalKeySubject("Enrollment-2026 jdoe"))
        #expect(CardinalKeyClientCertificateProvider.isCardinalKeySubject("Stanford Cardinal Key (jdoe)"))
        #expect(!CardinalKeyClientCertificateProvider.isCardinalKeySubject("jdoe@stanford.edu"))
        #expect(!CardinalKeyClientCertificateProvider.isCardinalKeySubject("enrollmentless"))
        #expect(!CardinalKeyClientCertificateProvider.isCardinalKeySubject(""))
    }
}

@Suite("FirstPartyConnector Stanford Outlook Mail")
struct FirstPartyConnectorStanfordOutlookMailTests {

    @Test("Constants and pure helpers")
    func constantsAndHelpers() {
        #expect(StanfordOutlookMail.serviceType == "stanford_outlook_mail")
        #expect(StanfordOutlookMail.authMethod == "oauth")
        #expect(StanfordOutlookMail.graphBaseURL == "https://graph.microsoft.com/v1.0")
        #expect(StanfordOutlookMail.accessTokenKey == "ASTRA_MAIL_ACCESS_TOKEN")
        #expect(StanfordOutlookMail.refreshTokenKey == "ASTRA_MAIL_REFRESH_TOKEN")
        #expect(StanfordOutlookMail.scopeString.contains("Mail.Read"))
        #expect(StanfordOutlookMail.scopeString.contains("offline_access"))

        #expect(StanfordOutlookMail.normalizeTenant("  ") == "stanford.edu")
        #expect(StanfordOutlookMail.normalizeTenant(" SHC.ORG ") == "shc.org")
        #expect(StanfordOutlookMail.normalizeConfiguredTenant("  ") == "")
        #expect(StanfordOutlookMail.normalizeConfiguredTenant(" Stanford.EDU ") == "stanford.edu")

        let connectorID = UUID()
        #expect(StanfordOutlookMail.keychainService(for: connectorID).contains(connectorID.uuidString))
        #expect(StanfordOutlookMail.registryURL.lastPathComponent.hasPrefix("mail-accounts-"))
        #expect(StanfordOutlookMail.registryURL.pathExtension == "json")
    }

    @Test("Registry entry JSON round-trips through a temp file")
    func registryRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-mail-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = [
            StanfordOutlookMailRegistry.Entry(
                connectorID: UUID().uuidString,
                name: "Work Mail",
                email: "jdoe@stanford.edu",
                tenantDomain: "stanford.edu",
                clientID: "client-123",
                keychainService: "astra-connector-x",
                channel: "release",
                displayName: "J. Doe",
                updatedAt: "2026-06-11T00:00:00Z"
            ),
            StanfordOutlookMailRegistry.Entry(
                connectorID: UUID().uuidString,
                name: "SHC Mail",
                email: "jdoe@stanfordhealthcare.org",
                tenantDomain: "stanfordhealthcare.org",
                clientID: "client-456",
                keychainService: "astra-connector-y",
                channel: "dev",
                displayName: "",
                updatedAt: "2026-06-11T01:00:00Z"
            )
        ]

        let file = root.appendingPathComponent("registry.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: file)

        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode([StanfordOutlookMailRegistry.Entry].self, from: data)
        #expect(decoded == entries)
        #expect(decoded[0].id == entries[0].connectorID)
    }

    @Test("Microsoft device code response decodes with snake_case keys")
    func deviceCodeResponseDecodes() throws {
        let json = """
        {"user_code":"ABCD-1234","device_code":"dev-1","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5,"message":"Go sign in"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MicrosoftDeviceCodeResponse.self, from: Data(json.utf8))
        #expect(response.userCode == "ABCD-1234")
        #expect(response.deviceCode == "dev-1")
        #expect(response.expiresIn == 900)
        #expect(response.interval == 5)
    }
}

@Suite("FirstPartyConnector Google Docs")
struct FirstPartyConnectorGoogleDocsTests {

    @Test("Document ID extraction from Docs URLs")
    func documentIDExtraction() {
        #expect(GoogleDocsDocumentAPI.documentID(
            from: "https://docs.google.com/document/d/abc123XYZ/edit") == "abc123XYZ")
        #expect(GoogleDocsDocumentAPI.documentID(
            from: "https://docs.google.com/document/d/abc123XYZ") == "abc123XYZ")
        // Non-Docs hosts and malformed paths are rejected.
        #expect(GoogleDocsDocumentAPI.documentID(
            from: "https://drive.google.com/document/d/abc123/edit") == nil)
        #expect(GoogleDocsDocumentAPI.documentID(
            from: "https://docs.google.com/document/") == nil)
        #expect(GoogleDocsDocumentAPI.documentID(from: "not a url") == nil)
        #expect(GoogleDocsDocumentAPI.documentID(
            from: "https://docs.google.com/document/d/") == nil)
    }

    @Test("Document snapshot extraction collects text and end index")
    func snapshotExtraction() throws {
        let object: [String: Any] = [
            "title": "Notes",
            "body": [
                "content": [
                    ["endIndex": 1],
                    [
                        "endIndex": 12,
                        "paragraph": [
                            "elements": [
                                ["endIndex": 7, "textRun": ["content": "Hello "]],
                                ["endIndex": 12, "textRun": ["content": "world\n"]]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let snapshot = try #require(
            GoogleDocsDocumentAPI.extractDocumentSnapshot(documentID: "doc-1", object: object)
        )
        #expect(snapshot.documentID == "doc-1")
        #expect(snapshot.title == "Notes")
        #expect(snapshot.text == "Hello world\n")
        #expect(snapshot.endIndex == 12)
    }

    @Test("Snapshot extraction rejects bodies without content")
    func snapshotRejectsMissingBody() {
        #expect(GoogleDocsDocumentAPI.extractDocumentSnapshot(documentID: "d", object: [:]) == nil)
        #expect(GoogleDocsDocumentAPI.extractDocumentSnapshot(
            documentID: "d", object: ["title": "T", "body": [String: Any]()]) == nil)
    }
}
