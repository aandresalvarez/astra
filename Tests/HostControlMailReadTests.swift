import Foundation
import Testing
import ASTRACore
@testable import HostControlToolSupport

@Suite("Host-control read-only mail contract")
struct HostControlMailReadTests {
    @Test("Each read accepts only its own bounded parameters")
    func validOperations() throws {
        #expect(MailReadRequest.parse(["operation": "accounts"])?.operation == .accounts)
        #expect(MailReadRequest.parse(["operation": "folders"])?.limit == 50)
        let search = try #require(MailReadRequest.parse(["operation": "search", "query": "protocol", "account": "account@example.test", "limit": 5]))
        #expect(search.query == "protocol")
        #expect(search.account == "account@example.test")
        #expect(search.limit == 5)
        #expect(MailReadRequest.parse(["operation": "get", "message_id": "a/b+id"])?.messageID == "a/b+id")
    }

    @Test("A request cannot choose another keychain, endpoint or write operation")
    func refusesAuthorityAndWrites() {
        for key in ["keychainService", "namespace", "url", "tenant", "client_id", "token", "task_id", "run_id"] {
            #expect(MailReadRequest.parse(["operation": "accounts", key: "untrusted"]) == nil)
        }
        for operation in ["send", "delete", "move", "refresh", "sign_in", "GET", ""] {
            #expect(MailReadRequest.parse(["operation": operation]) == nil)
        }
        #expect(MailReadRequest.parse(["operation": "accounts", "account": "other"]) == nil)
        #expect(MailReadRequest.parse(["operation": "get", "message_id": "id", "limit": 1]) == nil)
    }

    @Test("Malformed or oversized parameters are refused rather than coerced")
    func refusesMalformedParameters() {
        let invalidLimits: [Any] = [true, 0, -1, 101, 1.5, Double.infinity, "10"]
        for limit in invalidLimits {
            #expect(MailReadRequest.parse(["operation": "folders", "limit": limit]) == nil)
        }
        for query in ["", "  ", String(repeating: "a", count: 2_049), "a\0b"] {
            #expect(MailReadRequest.parse(["operation": "search", "query": query]) == nil)
        }
        #expect(MailReadRequest.parse(["operation": "search"])?.query == nil)
        #expect(MailReadRequest.parse(["operation": "search", "limit": 26]) == nil)
        #expect(MailReadRequest.parse(["operation": "get"]) == nil)
        #expect(MailReadRequest.parse(["operation": "folders", "account": 12]) == nil)
    }
    @Test("The transport needs both mail admission and a captured reader")
    func readerAndAdmissionAreBothRequired() throws {
        let payload = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail","arguments":{"operation":"accounts"}}}"#
        let admitted = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"]), mailReader: FixtureReader())
        #expect(try #require(admitted.handleLine(payload)).contains("captured-account"))
        let denied = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: []), mailReader: FixtureReader())
        #expect(!((denied.handleLine(payload) ?? "").contains("captured-account")))
        let absent = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"]))
        #expect(try #require(absent.handleLine(payload)).contains("unavailable"))
    }

    @Test("Mail replies reject oversized content, malformed JSON and raw provider errors")
    func unsafeResponsesAreNotReturned() throws {
        let payload = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail","arguments":{"operation":"accounts"}}}"#
        for result in [Data("not JSON".utf8), try JSONSerialization.data(withJSONObject: ["body": String(repeating: "x", count: MailReadArtifact.maximumBytes)])] {
            let server = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"]), mailReader: FixtureReader(data: result))
            #expect(try #require(server.handleLine(payload)).contains("within its limit"))
        }
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"]), mailReader: FailingReader())
        let reply = try #require(server.handleLine(payload))
        #expect(reply.contains("could not read"))
        #expect(!reply.contains("synthetic-sensitive-token"))
    }

    @Test("An escape-heavy mail reply fits both complete relay envelopes")
    func escapedReplyFitsTransport() throws {
        let text = String(repeating: "\\", count: (MailReadHostControlPolicy.maximumResponseBytes - 20) / 2)
        let data = try JSONSerialization.data(withJSONObject: ["body": text])
        #expect(data.count <= MailReadHostControlPolicy.maximumResponseBytes)
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"]), mailReader: FixtureReader(data: data))
        let payload = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail","arguments":{"operation":"accounts"}}}"#
        let line = try #require(server.handleLine(payload))
        #expect(!line.contains("within its limit"))
        #expect(line.contains("body"))
        #expect(line.utf8.count + 1 <= HostControlBrokerFileDrop.maximumMessageBytes)
        let envelope = HostControlBrokerFileDrop.Response(token: String(repeating: "t", count: 64), line: line)
        let bytes = try JSONEncoder().encode(envelope)
        #expect(bytes.count <= HostControlBrokerFileDrop.maximumMessageBytes)
        #expect(try JSONDecoder().decode(HostControlBrokerFileDrop.Response.self, from: bytes).line == line)
    }

    @Test("A mail body larger than the inline limit is saved whole under the task folder")
    func largeReplyIsNotTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try JSONSerialization.data(withJSONObject: ["body": String(repeating: "message", count: 50_000)])
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"], taskFolder: root.path), mailReader: FixtureReader(data: data))
        let payload = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail","arguments":{"operation":"accounts"}}}"#
        let line = try #require(server.handleLine(payload))
        #expect(line.utf8.count < HostControlBrokerFileDrop.maximumMessageBytes)
        let reply = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try #require(reply["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let receipt = try #require(content.first?["text"] as? String)
        let document = try #require(JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any])
        let path = try #require(document["output_file"] as? String)
        #expect(path.hasPrefix(root.resolvingSymlinksInPath().path + "/mail-reads/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        #expect(document["byte_count"] as? Int == data.count)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("A mail output directory cannot redirect a reply outside the task")
    func outputSymlinkIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-links-\(UUID().uuidString)")
        let task = root.appendingPathComponent("task"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: task.appendingPathComponent("mail-reads"), withDestinationURL: outside)
        #expect(throws: MailReadFailure.outputUnavailable) {
            try MailReadArtifact.store(Data("{}".utf8), configuration: HostControlToolConfiguration(taskFolder: task.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("The compatibility CLI and MCP share operation parsing")
    func cliUsesTheSameContract() throws {
        let values = try #require(MailReadRequest.arguments(fromCLI: ["search", "--query", "protocol", "--account", "A", "--limit", "50"]))
        #expect(MailReadRequest.parse(values)?.limit == 25)
        #expect(MailReadRequest.parse(values)?.account == "A")
        #expect(MailReadRequest.arguments(fromCLI: ["accounts"]) != nil)
        #expect(MailReadRequest.arguments(fromCLI: ["get", "--message-id", "M"]) != nil)
        for args in [["accounts", "--keychain-service", "other"], ["folders", "--account", "A", "--account", "B"], ["folders", "--account", "   "], ["get"], ["delete"], ["search", "--limit"]] {
            #expect(MailReadRequest.arguments(fromCLI: args) == nil)
        }
    }

    private final class FixtureReader: BrokeredMailReading {
        let data: Data
        init(data: Data = Data(#"{"accounts":[{"name":"captured-account"}]}"#.utf8)) { self.data = data }
        func readMail(_ request: MailReadRequest) throws -> Data { data }
        func cancelPendingReads() {}
        func closeMailAccess() {}
    }

    private final class FailingReader: BrokeredMailReading {
        struct Failure: LocalizedError {
            var errorDescription: String? { "synthetic-sensitive-token" }
        }
        func readMail(_ request: MailReadRequest) throws -> Data { throw Failure() }
        func cancelPendingReads() {}
        func closeMailAccess() {}
    }

}
