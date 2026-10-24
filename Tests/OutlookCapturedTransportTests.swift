import CryptoKit
import Foundation
import Testing
import ASTRACore
import ASTRAModels
import HostControlToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Captured Outlook backend transport", .serialized)
struct OutlookCapturedTransportTests {
    @Test("The helper's file-drop client reads the captured generation and preserves a large message as an artifact")
    func actualBackendThroughFileDrop() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture()
            defer { fixture.removeFiles() }
            let record = PluginAccountRecord(fixture.account)
            let vaultPath = try #require(AstraSecureKeychainStore.keychainPathOverride)
            let bootstrap = try #require(AstraSecureKeychainStore.bootstrapServiceOverride)
            let body = try JSONSerialization.data(withJSONObject: ["id": "original-message", "body": ["content": String(repeating: "mail text ", count: 30_000)]])
            let stub = OutlookBackendHTTPStub { request in
                if request.url?.host == "login.microsoftonline.com" {
                    return OutlookBackendHTTPStub.json(request, #"{"access_token":"captured-renewed-access","expires_in":3600}"#)
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer captured-renewed-access")
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let captured = StanfordOutlookMailRuntimeAccess.Snapshot(accounts: [record], withheldAccountCount: 1)
            let reader = captured.makeReader { account, request in
                // A transport callback starts a new Task; carry the private
                // test vault explicitly rather than touching the app's vault.
                try await AstraSecureKeychainStore.$keychainPathOverride.withValue(vaultPath) {
                    try await AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                        try await StanfordOutlookMailGraphService(transport: stub).read(account: account, request: request)
                    }
                }
            }
            defer { reader.closeMailAccess() }
            fixture.account.credentialNamespaceID = UUID()
            fixture.account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "later-live-client")
            let server = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"],
                taskFolder: fixture.env.workspace.primaryPath), mailReader: reader)
            let token = HostControlBrokerFileDrop.newToken()
            let listener = HostControlBrokerDropListener(token: token, authorize: { $0 == Int32(ProcessInfo.processInfo.processIdentifier) },
                handle: { server.handleLine($0) ?? "" })
            let directory = try #require(listener.start(candidateDirectory: "/tmp/astra-outlook-drop-\(UUID().uuidString)"))
            defer { listener.invalidate() }
            let payload = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"mail","arguments":{"operation":"get","message_id":"original-message"}}}"#
            let line = try await exchange(payload, directory: directory, token: token)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let result = try #require(envelope["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            let receiptText = try #require(content.first?["text"] as? String)
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(receiptText.utf8)) as? [String: Any])
            let path = try #require(receipt["output_file"] as? String)
            #expect(path.hasPrefix(URL(fileURLWithPath: fixture.env.workspace.primaryPath).resolvingSymlinksInPath().path + "/mail-reads/"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == body)
            #expect(receipt["byte_count"] as? Int == body.count)
            #expect(receipt["sha256"] as? String == SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
            #expect(try fixture.load(record)?.accessToken == "captured-renewed-access")
            #expect(!line.contains("captured-renewed-access"))
            let calls = await stub.calls()
            #expect(calls.count == 2)
            #expect(String(data: calls[0].request.httpBody!, encoding: .utf8)?.contains("synthetic-client") == true)
            #expect(calls[1].request.url?.path == "/v1.0/me/messages/original-message")
        }
    }

    private func exchange(_ line: String, directory: String, token: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try HostControlBrokerFileDropClient.exchange(line,
                        directory: directory, token: token, timeout: 10))
                } catch { continuation.resume(throwing: error) }
            }
            thread.name = "captured-outlook-drop-client"
            thread.start()
        }
    }
}
