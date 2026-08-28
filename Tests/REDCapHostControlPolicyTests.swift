import Foundation
import Testing
@testable import ASTRA
@testable import HostControlToolSupport

/// The REDCap broker exists because the connector used to hand
/// `REDCAP_API_TOKEN` to the agent as an environment variable. These tests hold
/// the two properties that make brokering worth the code: the token never comes
/// back out, and subject data never reaches the transcript.
@Suite("REDCap host control", .serialized)
struct REDCapHostControlPolicyTests {
    private static let token = "0123456789ABCDEF0123456789ABCDEF"

    // MARK: - The token stays on the host

    @Test("Status reports the variable name and presence, never the token")
    func statusReportsPresenceNeverTheToken() throws {
        let server = server()
        let text = try resultText(try call(server, id: 1, arguments: ["operation": "status"]))

        #expect(text.contains("api_token_env_key: REDCAP_TOKEN_ENV"))
        #expect(text.contains("api_token_present: true"))
        #expect(text.contains("ready: true"))
        #expect(!text.contains(Self.token))
    }

    @Test("Status reports not-ready without a projected token")
    func statusReportsNotReadyWithoutAToken() throws {
        let server = server(environment: [:])
        let response = try call(server, id: 1, arguments: ["operation": "status"])
        let text = try resultText(response)

        #expect(text.contains("api_token_present: false"))
        #expect(text.contains("ready: false"))
        #expect(try isError(response))
    }

    @Test("A read blocked for missing credentials never reaches the network")
    func blockedReadNeverReachesTheNetwork() throws {
        let server = server(environment: [:])
        defer { Self.endCapture() }
        Self.beginCapture()

        let response = try call(server, id: 1, arguments: ["operation": "project"])

        #expect(try isError(response))
        #expect(REDCapCaptureURLProtocol.requests.isEmpty)
    }

    @Test("The token travels in the request body, not the URL")
    func tokenTravelsInTheRequestBody() throws {
        defer { Self.endCapture() }
        Self.beginCapture()
        REDCapCaptureURLProtocol.body = #"{"project_id":42}"#

        let text = try resultText(try call(server(), id: 1, arguments: ["operation": "project"]))
        let request = try #require(REDCapCaptureURLProtocol.requests.last)

        #expect(!request.url.absoluteString.contains(Self.token))
        #expect(request.url.query == nil)
        #expect(request.body.contains("token=\(Self.token)"))
        #expect(request.body.contains("content=project"))
        #expect(!text.contains(Self.token))
        #expect(text.contains("project_id"))
    }

    /// REDCap echoes the submitted token back in some malformed-request errors.
    /// The error body is worth surfacing; the token in it is not.
    @Test("A token echoed in an error body is redacted")
    func tokenEchoedInAnErrorBodyIsRedacted() throws {
        defer { Self.endCapture() }
        Self.beginCapture()
        REDCapCaptureURLProtocol.statusCode = 400
        REDCapCaptureURLProtocol.body = #"{"error":"The value \"\#(Self.token)\" is not a valid token"}"#

        let text = try resultText(try call(server(), id: 1, arguments: ["operation": "project"]))

        #expect(!text.contains(Self.token))
        #expect(text.contains("[redacted]"))
        #expect(text.contains("not a valid token"))
    }

    // MARK: - Subject data stays out of the transcript

    @Test("Record exports write rows to a file and return only a receipt")
    func recordExportsWriteRowsToAFile() throws {
        let directory = try temporaryDirectory()
        defer {
            Self.endCapture()
            try? FileManager.default.removeItem(at: directory)
        }
        Self.beginCapture()
        let phi = #"[{"record_id":"1","dob":"1970-01-01","mrn":"ABC-99887"}]"#
        REDCapCaptureURLProtocol.body = phi

        let text = try resultText(try call(
            server(taskFolder: directory.path),
            id: 1,
            arguments: ["operation": "record"]
        ))

        #expect(!text.contains("ABC-99887"), "Subject data must not be returned inline: \(text)")
        #expect(!text.contains("1970-01-01"))
        #expect(text.contains("record_count: 1"))
        #expect(text.contains("export_bytes: \(phi.utf8.count)"))

        let path = try #require(value(of: "export_path", in: text))
        #expect(path.hasPrefix(directory.path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == phi)
    }

    @Test("A second export in the same run does not overwrite the first")
    func secondExportDoesNotOverwriteTheFirst() throws {
        let directory = try temporaryDirectory()
        defer {
            Self.endCapture()
            try? FileManager.default.removeItem(at: directory)
        }
        Self.beginCapture()
        let server = server(taskFolder: directory.path)

        REDCapCaptureURLProtocol.body = #"[{"record_id":"1"}]"#
        let first = try resultText(try call(server, id: 1, arguments: ["operation": "record"]))
        REDCapCaptureURLProtocol.body = #"[{"record_id":"2"},{"record_id":"3"}]"#
        let second = try resultText(try call(server, id: 2, arguments: ["operation": "record"]))

        let firstPath = try #require(value(of: "export_path", in: first))
        let secondPath = try #require(value(of: "export_path", in: second))
        #expect(firstPath != secondPath)
        #expect(second.contains("record_count: 2"))
        #expect(try String(contentsOfFile: firstPath, encoding: .utf8).contains(#""1""#))
    }

    /// The export used to fall back to the working directory, which is the
    /// workspace the agent is operating in — normally a git checkout. A run
    /// that reached the broker without a projected task folder therefore wrote
    /// subject data into the repository, one `git add .` from committing it.
    /// There is no safe default here, so there is no default.
    @Test("An export with no task folder is refused rather than redirected")
    func exportWithoutATaskFolderIsRefused() throws {
        defer { Self.endCapture() }
        Self.beginCapture()
        let phi = #"[{"record_id":"1","dob":"1970-01-01","mrn":"ABC-99887"}]"#
        REDCapCaptureURLProtocol.body = phi

        // `server(taskFolder:)` defaults to none, and its `currentDirectory` is
        // the destination the old fallback would have chosen.
        let text = try resultText(try call(
            server(),
            id: 1,
            arguments: ["operation": "record"]
        ))

        #expect(text.contains("could not be written"))
        #expect(text.contains("task folder"))
        #expect(!text.contains("export_path:"), "Nothing was written, so there is no path to hand back")
        // The refusal must not become the other leak: no inline PHI either.
        #expect(!text.contains("ABC-99887"))
        #expect(!text.contains("1970-01-01"))
        #expect(
            !FileManager.default.fileExists(atPath: "/tmp/not-the-export-destination"),
            "Subject data was written to the working directory the fallback used to pick"
        )
    }

    @Test("Structural operations still come back inline")
    func structuralOperationsComeBackInline() throws {
        defer { Self.endCapture() }
        Self.beginCapture()
        REDCapCaptureURLProtocol.body = #"[{"field_name":"dob","field_type":"text"}]"#

        for operation in ["project", "metadata", "user"] {
            let text = try resultText(try call(server(), id: 1, arguments: ["operation": operation]))
            #expect(text.contains("field_type"), "\(operation) should return structure inline")
        }
    }

    // MARK: - The request the agent can compose

    @Test("Unsupported operations are refused")
    func unsupportedOperationsAreRefused() throws {
        let server = server()
        for operation in ["import", "delete", "export_pdf", "record; rm -rf /"] {
            let message = try errorMessage(try call(server, id: 1, arguments: ["operation": operation]))
            #expect(message.contains("Unsupported REDCap operation"))
        }
    }

    @Test("Identifier lists become indexed parameters and reject separators")
    func identifierListsBecomeIndexedParameters() throws {
        let request = try REDCapRequestPolicy.readRequest(
            operation: "record",
            arguments: ["fields": ["record_id", "dob"], "records": ["101"]]
        )

        #expect(request.content == "record")
        #expect(request.parameters["fields[0]"] == "record_id")
        #expect(request.parameters["fields[1]"] == "dob")
        #expect(request.parameters["records[0]"] == "101")
        #expect(request.parameters["token"] == nil)

        #expect(throws: (any Error).self) {
            try REDCapRequestPolicy.readRequest(
                operation: "record",
                arguments: ["fields": ["dob&content=user"]]
            )
        }
        #expect(throws: (any Error).self) {
            try REDCapRequestPolicy.readRequest(operation: "record", arguments: ["fields": "dob"])
        }
        #expect(throws: (any Error).self) {
            try REDCapRequestPolicy.readRequest(
                operation: "metadata",
                arguments: ["forms": Array(repeating: "form", count: REDCapRequestPolicy.maximumIdentifiers + 1)]
            )
        }
    }

    @Test("Reports require a numeric identifier")
    func reportsRequireANumericIdentifier() throws {
        let request = try REDCapRequestPolicy.readRequest(
            operation: "report",
            arguments: ["report_id": "77", "raw_or_label": "label"]
        )
        #expect(request.parameters["report_id"] == "77")
        #expect(request.parameters["rawOrLabel"] == "label")

        #expect(throws: (any Error).self) {
            try REDCapRequestPolicy.readRequest(operation: "report", arguments: [:])
        }
        #expect(throws: (any Error).self) {
            try REDCapRequestPolicy.readRequest(operation: "report", arguments: ["report_id": "7 OR 1=1"])
        }
        #expect(throws: (any Error).self) {
            try REDCapRequestPolicy.readRequest(
                operation: "record",
                arguments: ["raw_or_label": "everything"]
            )
        }
    }

    @Test("Form encoding escapes every key and value")
    func formEncodingEscapesEveryKeyAndValue() {
        let encoded = REDCapHTTPClient.formEncoded([
            "content": "record",
            "fields[0]": "a b&c=d",
            "token": Self.token
        ])

        #expect(encoded == "content=record&fields%5B0%5D=a%20b%26c%3Dd&token=\(Self.token)")
    }

    // MARK: - Relay and CLI admission

    @Test("The CLI relay allows only typed REDCap invocations")
    func cliRelayAllowsOnlyTypedInvocations() {
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control redcap --operation status"))
        #expect(HostControlCLIRelayPolicy.allows(
            "astra-host-control redcap --operation record --fields record_id,dob"
        ))
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control redcap --operation report --report-id 12"))

        #expect(!HostControlCLIRelayPolicy.allows("astra-host-control redcap --operation import"))
        #expect(!HostControlCLIRelayPolicy.allows("astra-host-control redcap --operation report"))
        #expect(!HostControlCLIRelayPolicy.allows("astra-host-control redcap --operation record --fields 'a b'"))
        #expect(!HostControlCLIRelayPolicy.allows("astra-host-control redcap --token \(Self.token)"))
        #expect(!HostControlCLIRelayPolicy.allows("astra-host-control redcap --operation record --raw-or-label all"))
    }

    // MARK: - Fixtures

    private func server(
        environment: [String: String]? = nil,
        taskFolder: String = ""
    ) -> HostControlMCPServer {
        let connectors = """
        {"connectors":[{"id":"redcap-1","alias":"redcap","envPrefix":"REDCAP","name":"REDCap",\
        "serviceType":"redcap","baseURL":"https://redcap.example.test/api/","authMethod":"token",\
        "env":{"REDCAP_API_TOKEN":"REDCAP_TOKEN_ENV"},\
        "credentials":{"REDCAP_API_TOKEN":"REDCAP_TOKEN_ENV"},"config":{}}]}
        """
        var resolved = environment ?? ["REDCAP_TOKEN_ENV": Self.token]
        resolved["ASTRA_CONNECTORS"] = connectors
        return HostControlMCPServer(configuration: HostControlToolConfiguration(
            currentDirectory: "/tmp/not-the-export-destination",
            taskFolder: taskFolder,
            connectorsJSON: connectors,
            environment: resolved
        ))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-redcap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The stub registry is a single process-wide list shared with the Jira
    /// capture tests, so this adds and removes itself rather than replacing
    /// whatever is already installed.
    private static func beginCapture() {
        REDCapCaptureURLProtocol.reset()
        HostControlURLSessionConfiguration.registerTestingProtocolClass(REDCapCaptureURLProtocol.self)
    }

    private static func endCapture() {
        HostControlURLSessionConfiguration.unregisterTestingProtocolClass(REDCapCaptureURLProtocol.self)
        REDCapCaptureURLProtocol.reset()
    }

    private func call(_ server: HostControlMCPServer, id: Int, arguments: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": "redcap", "arguments": arguments]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: data, encoding: .utf8))
        let line = try #require(server.handleLine(requestLine))
        let responseData = try #require(line.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func resultText(_ object: [String: Any]) throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func isError(_ object: [String: Any]) throws -> Bool {
        let result = try #require(object["result"] as? [String: Any])
        return result["isError"] as? Bool == true
    }

    private func errorMessage(_ object: [String: Any]) throws -> String {
        let error = try #require(object["error"] as? [String: Any])
        return try #require(error["message"] as? String)
    }

    private func value(of key: String, in text: String) -> String? {
        text
            .split(separator: "\n")
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)) }
    }
}

private final class REDCapCaptureURLProtocol: URLProtocol {
    struct Request {
        var url: URL
        var body: String
    }

    private static let lock = NSLock()
    private static var captured: [Request] = []
    private static var responseBody = "{}"
    private static var responseStatusCode = 200

    static var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static var body: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return responseBody
        }
        set {
            lock.lock()
            responseBody = newValue
            lock.unlock()
        }
    }

    static var statusCode: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return responseStatusCode
        }
        set {
            lock.lock()
            responseStatusCode = newValue
            lock.unlock()
        }
    }

    static func reset() {
        lock.lock()
        captured = []
        responseBody = "{}"
        responseStatusCode = 200
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "redcap.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // URLSession moves an httpBody onto a stream by the time the protocol
        // sees it, so read whichever one survived.
        let bodyData = request.httpBody ?? Self.drain(request.httpBodyStream)

        Self.lock.lock()
        Self.captured.append(Request(url: url, body: String(decoding: bodyData, as: UTF8.self)))
        let payload = Self.responseBody
        let status = Self.responseStatusCode
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
