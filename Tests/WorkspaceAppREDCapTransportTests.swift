import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// Locks down the REAL REDCap Import-Records client's API contract (request shape + response parsing
/// + transport round-trip) with a mock transport — the verifiable part of the live-connector path
/// that doesn't need a live server.
@Suite("Workspace App REDCap HTTP Transport")
struct WorkspaceAppREDCapTransportTests {
    private final class RecordingTransport: ConnectorHTTPTransport, @unchecked Sendable {
        var lastRequest: URLRequest?
        let result: (Data, URLResponse)
        init(_ result: (Data, URLResponse)) { self.result = result }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lastRequest = request
            return result
        }
    }

    private func formParams(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let string = String(data: body, encoding: .utf8) else { return [:] }
        var params: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                params[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        return params
    }

    private func httpResponse(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://redcap.example.org/api/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("importRequest builds the correct REDCap content=record POST")
    func buildsImportRequest() {
        let request = WorkspaceAppREDCapImportAPI.importRequest(
            baseURL: URL(string: "https://redcap.example.org/api/")!,
            token: "TKN123",
            record: ["first_name": .text("Ada"), "record_id": .integer(1)],
            overwrite: false
        )
        #expect(request.httpMethod == "POST")
        let params = formParams(request)
        #expect(params["token"] == "TKN123")
        #expect(params["content"] == "record")
        #expect(params["format"] == "json")
        #expect(params["type"] == "flat")
        #expect(params["overwriteBehavior"] == "normal")
        #expect(params["returnContent"] == "count")
        #expect(params["data"] == #"[{"first_name":"Ada","record_id":1}]"#)
    }

    @Test("parseCount reads the success count, a bare number, and surfaces a REDCap error")
    func parsesResponses() throws {
        #expect(try WorkspaceAppREDCapImportAPI.parseCount(Data(#"{"count":3}"#.utf8)) == 3)
        #expect(try WorkspaceAppREDCapImportAPI.parseCount(Data("5".utf8)) == 5)
        #expect(throws: WorkspaceAppREDCapAPIError.self) {
            try WorkspaceAppREDCapImportAPI.parseCount(Data(#"{"error":"You do not have permissions"}"#.utf8))
        }
    }

    @Test("submit imports through the transport and returns the count")
    func submitImports() async throws {
        let transport = RecordingTransport((Data(#"{"count":1}"#.utf8), httpResponse(200)))
        let client = WorkspaceAppREDCapHTTPTransport(
            endpoint: URL(string: "https://redcap.example.org/api/")!, token: "TKN", transport: transport
        )
        let result = try await client.submit(record: ["first_name": .text("Grace")])
        #expect(result.outputSummary.contains("Imported 1 record"))
        #expect(formParams(transport.lastRequest ?? URLRequest(url: URL(string: "x:")!))["content"] == "record")
    }

    @Test("submit surfaces a REDCap server error and an HTTP failure")
    func submitErrors() async {
        let errorClient = WorkspaceAppREDCapHTTPTransport(
            endpoint: URL(string: "https://redcap.example.org/api/")!, token: "TKN",
            transport: RecordingTransport((Data(#"{"error":"Invalid token"}"#.utf8), httpResponse(200)))
        )
        await #expect(throws: WorkspaceAppREDCapAPIError.self) {
            try await errorClient.submit(record: ["a": .text("b")])
        }
        let httpFailClient = WorkspaceAppREDCapHTTPTransport(
            endpoint: URL(string: "https://redcap.example.org/api/")!, token: "TKN",
            transport: RecordingTransport((Data(), httpResponse(403)))
        )
        await #expect(throws: WorkspaceAppREDCapAPIError.self) {
            try await httpFailClient.submit(record: ["a": .text("b")])
        }
    }
}
