import Foundation
import Testing
import ASTRACore
import ASTRAModels
import HostControlToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Captured Outlook Graph backend", .serialized)
struct OutlookGraphBackendTests {
    @Test("The actual Graph loader uses captured tokens, fixed paths and bounded operation parameters")
    func actualGraphRequestsStayTypedAndCaptured() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let captured = PluginAccountRecord(fixture.account)
            let transport = OutlookBackendHTTPStub { request in
                OutlookBackendHTTPStub.json(request, #"{"value":[],"id":"synthetic"}"#)
            }
            let graph = StanfordOutlookMailGraphService(transport: transport)
            let requests: [[String: Any]] = [
                ["operation": "folders", "limit": 100], ["operation": "search", "limit": 25, "query": "mail from:\"team\""],
                ["operation": "get", "message_id": "abc/def+%?=#id"], ["operation": "search"]]
            fixture.account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "different-live-client")
            fixture.account.credentialNamespaceID = UUID()
            try fixture.env.context.save()
            for arguments in requests {
                _ = try await graph.read(account: captured, request: #require(MailReadRequest.parse(arguments)))
            }
            let calls = await transport.calls()
            #expect(calls.count == 4)
            for call in calls {
                #expect(call.request.url?.host == "graph.microsoft.com")
                #expect(call.request.url?.scheme == "https")
                #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer original-access")
                #expect(call.maximumBytes == 8 * 1_024 * 1_024)
            }
            let folders = try #require(URLComponents(url: calls[0].request.url!, resolvingAgainstBaseURL: false))
            #expect(folders.path == "/v1.0/me/mailFolders")
            #expect(folders.queryItems?.contains { $0.name == "$top" && $0.value == "100" } == true)
            #expect(calls[1].request.value(forHTTPHeaderField: "ConsistencyLevel") == "eventual")
            let get = try #require(URLComponents(url: calls[2].request.url!, resolvingAgainstBaseURL: false))
            #expect(get.percentEncodedPath == "/v1.0/me/messages/abc%2Fdef%2B%25%3F%3D%23id")
            #expect(calls[2].request.value(forHTTPHeaderField: "Prefer") == "outlook.body-content-type=\"text\"")
            #expect(calls[3].request.url?.query?.contains("receivedDateTime") == true)
        }
    }

    @Test("A large mail body remains complete for the existing task-artifact transport")
    func largeBodyIsNotTruncated() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let content = String(repeating: "body-line\n", count: 40_000)
            let data = try JSONSerialization.data(withJSONObject: ["id": "message", "body": ["contentType": "text", "content": content]])
            let transport = OutlookBackendHTTPStub { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let request = try #require(MailReadRequest.parse(["operation": "get", "message_id": "message"]))
            let result = try await StanfordOutlookMailGraphService(transport: transport).read(account: PluginAccountRecord(fixture.account), request: request)
            #expect(result == data)
            let parsed = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
            #expect((parsed["body"] as? [String: String])?["content"] == content)
        }
    }

    @Test("Connection facts preserve exact generation and first-match format")
    func connectionFactsCarryExactIdentity() {
        let id = UUID(), namespace = UUID()
        let facts = ConnectorOutlookFacts(id: id, name: "Outlook", serviceType: OutlookCredentialIdentity.serviceType,
            configKeys: [OutlookCredentialIdentity.formatKey, OutlookCredentialIdentity.formatKey],
            configValues: [OutlookCredentialIdentity.generationFormat, "future-unknown"], credentialNamespaceID: namespace)
        #expect(facts.credentialNamespaceID == namespace)
        #expect(facts.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
    }
}
