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
    private static let betaToken = "FEDCBA9876543210FEDCBA9876543210"

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

    /// The task folder is agent-writable and this broker is not sandboxed to
    /// it, so the agent can put the link there before the first export is ever
    /// asked for. `createDirectory` has no don't-follow option and succeeds
    /// against the link target, which is how every export after it lands
    /// outside the folder the user granted.
    @Test("A symlinked export directory is refused rather than followed")
    func symlinkedExportDirectoryIsRefused() throws {
        let directory = try temporaryDirectory()
        let elsewhere = try temporaryDirectory()
        defer {
            Self.endCapture()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        Self.beginCapture()
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(REDCapHostControlPolicy.exportDirectoryName),
            withDestinationURL: elsewhere
        )
        let phi = #"[{"record_id":"1","dob":"1970-01-01","mrn":"ABC-99887"}]"#
        REDCapCaptureURLProtocol.body = phi

        let text = try resultText(try call(
            server(taskFolder: directory.path),
            id: 1,
            arguments: ["operation": "record"]
        ))

        #expect(text.contains("symbolic link"))
        #expect(!text.contains("export_path:"))
        // The refusal must not become the other leak.
        #expect(!text.contains("ABC-99887"))
        #expect(!text.contains("1970-01-01"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty,
            "Subject data was written through the link into \(elsewhere.path)"
        )
    }

    /// `exportSequence` is process-local, so a broker restart — or a second
    /// broker instance serving the same run — starts back at 1 while sequence 1
    /// is already on disk under a receipt the agent still holds.
    @Test("An export never replaces a file an earlier receipt points at")
    func exportNeverReplacesAnExistingFile() throws {
        let directory = try temporaryDirectory()
        defer {
            Self.endCapture()
            try? FileManager.default.removeItem(at: directory)
        }
        Self.beginCapture()
        // A run ID this process has not exported under, so the in-memory
        // sequence really does start at 1, the way a restart leaves it.
        let runID = "run-\(UUID().uuidString)"
        let exports = directory.appendingPathComponent(
            REDCapHostControlPolicy.exportDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let taken = exports.appendingPathComponent("redcap-record-\(runID)-1.json")
        try Data(#"[{"record_id":"earlier"}]"#.utf8).write(to: taken)

        REDCapCaptureURLProtocol.body = #"[{"record_id":"later"}]"#
        let text = try resultText(try call(
            server(taskFolder: directory.path, runID: runID),
            id: 1,
            arguments: ["operation": "record"]
        ))

        let path = try #require(value(of: "export_path", in: text))
        #expect(path != taken.path)
        #expect(
            try String(contentsOf: taken, encoding: .utf8).contains("earlier"),
            "The earlier export was replaced, so its receipt now points at another run's rows"
        )
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("later"))
    }

    /// `isError` does not mean the body is safe. A transfer that drops after
    /// the first rows arrive, or a 500 raised mid-export, leaves partial
    /// subject data in `body` — and the general error path returns the body
    /// inline, which is the one thing exports exist to prevent.
    @Test("A failed export withholds the body instead of returning it inline")
    func failedExportWithholdsTheBody() throws {
        let directory = try temporaryDirectory()
        defer {
            Self.endCapture()
            try? FileManager.default.removeItem(at: directory)
        }
        Self.beginCapture()
        REDCapCaptureURLProtocol.statusCode = 500
        // A partial export: the array never closes, which is what a dropped
        // transfer looks like.
        REDCapCaptureURLProtocol.body = #"[{"record_id":"1","dob":"1970-01-01","mrn":"ABC-99887"}"#

        let text = try resultText(try call(
            server(taskFolder: directory.path),
            id: 1,
            arguments: ["operation": "record"]
        ))

        #expect(!text.contains("ABC-99887"), "Partial subject data reached the transcript: \(text)")
        #expect(!text.contains("1970-01-01"))
        #expect(text.contains("status_code: 500"))
        #expect(text.contains("withheld_body_bytes: "))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(REDCapHostControlPolicy.exportDirectoryName).path
            ),
            "A failed export must not be written to a file either"
        )
    }

    /// Withholding must not go so far that the agent is told "403" with no
    /// reason. Every request sets `returnFormat=json`, and REDCap's refusals
    /// come back as a JSON object with an `error` key — never the array an
    /// export returns — so that shape is safe to surface.
    @Test("A REDCap error document still comes back from a failed export")
    func failedExportSurfacesTheREDCapDiagnostic() throws {
        let directory = try temporaryDirectory()
        defer {
            Self.endCapture()
            try? FileManager.default.removeItem(at: directory)
        }
        Self.beginCapture()
        REDCapCaptureURLProtocol.statusCode = 403
        REDCapCaptureURLProtocol.body = #"{"error":"You do not have Export Rights for this project"}"#

        let text = try resultText(try call(
            server(taskFolder: directory.path),
            id: 1,
            arguments: ["operation": "record"]
        ))

        #expect(text.contains("redcap_error: You do not have Export Rights for this project"))
        #expect(!text.contains("withheld_body_bytes"))
    }

    /// The buffer stops accumulating at the limit and says so; discarding that
    /// answer left the session downloading the rest anyway, which for the 8 MiB
    /// export cap is a whole project's rows pulled over the network to produce
    /// a reply that was already decided.
    @Test("A response past the cap is cancelled, not drained")
    func responsePastTheCapIsCancelled() throws {
        defer { Self.endCapture() }
        Self.beginCapture()
        REDCapCaptureURLProtocol.body = String(repeating: "a", count: 20 * 1024)
        REDCapCaptureURLProtocol.chunkCount = 20

        _ = try resultText(try call(
            server(processLimits: HostControlProcessLimits(outputByteLimit: 512)),
            id: 1,
            arguments: ["operation": "project"]
        ))

        #expect(
            REDCapCaptureURLProtocol.deliveredChunks < 20,
            "The whole response was downloaded after the buffer was already full"
        )
    }

    // MARK: - Which connector the call meant

    /// Picking the first match sends the export to whichever study sorts first
    /// in the manifest. A silently arbitrary answer is worse than an error the
    /// agent is told how to fix.
    @Test("Two REDCap connectors in scope refuse an unaliased call")
    func twoConnectorsRefuseAnUnaliasedCall() throws {
        defer { Self.endCapture() }
        Self.beginCapture()

        let message = try errorMessage(try call(
            twoConnectorServer(),
            id: 1,
            arguments: ["operation": "project"]
        ))

        #expect(message.contains("will not"))
        #expect(message.contains("alpha"))
        #expect(message.contains("beta"))
        #expect(REDCapCaptureURLProtocol.requests.isEmpty, "The ambiguous call still reached REDCap")
    }

    @Test("An alias picks one of two connectors in scope")
    func aliasPicksOneOfTwoConnectors() throws {
        defer { Self.endCapture() }
        Self.beginCapture()
        REDCapCaptureURLProtocol.body = #"{"project_id":7}"#

        let text = try resultText(try call(
            twoConnectorServer(),
            id: 1,
            arguments: ["operation": "project", "alias": "beta"]
        ))

        #expect(text.contains("project_id"))
        let request = try #require(REDCapCaptureURLProtocol.requests.first)
        #expect(request.body.contains("token=\(Self.betaToken)"))
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
        taskFolder: String = "",
        runID: String = "unknown-run",
        processLimits: HostControlProcessLimits = .standard
    ) -> HostControlMCPServer {
        let connectors = """
        {"connectors":[{"id":"redcap-1","alias":"redcap","envPrefix":"REDCAP","name":"REDCap",\
        "serviceType":"redcap","baseURL":"https://redcap.example.test/api/","authMethod":"token",\
        "env":{"REDCAP_API_TOKEN":"REDCAP_TOKEN_ENV"},\
        "credentials":{"REDCAP_API_TOKEN":"REDCAP_TOKEN_ENV"},"config":{}}]}
        """
        var resolved = environment ?? ["REDCAP_TOKEN_ENV": Self.token]
        resolved["ASTRA_CONNECTORS"] = connectors
        return HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                currentDirectory: "/tmp/not-the-export-destination",
                taskFolder: taskFolder,
                runID: runID,
                connectorsJSON: connectors,
                environment: resolved
            ),
            processLimits: processLimits
        )
    }

    /// Two studies on one REDCap host, which is the ordinary shape of a
    /// multi-project account rather than an edge case.
    private func twoConnectorServer() -> HostControlMCPServer {
        let connectors = """
        {"connectors":[\
        \(Self.connectorJSON(id: "redcap-a", alias: "alpha", tokenVariable: "REDCAP_ALPHA_ENV")),\
        \(Self.connectorJSON(id: "redcap-b", alias: "beta", tokenVariable: "REDCAP_BETA_ENV"))\
        ]}
        """
        return HostControlMCPServer(configuration: HostControlToolConfiguration(
            currentDirectory: "/tmp/not-the-export-destination",
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "REDCAP_ALPHA_ENV": Self.token,
                "REDCAP_BETA_ENV": Self.betaToken
            ]
        ))
    }

    private static func connectorJSON(id: String, alias: String, tokenVariable: String) -> String {
        """
        {"id":"\(id)","alias":"\(alias)","envPrefix":"REDCAP","name":"REDCap \(alias)",\
        "serviceType":"redcap","baseURL":"https://redcap.example.test/api/","authMethod":"token",\
        "env":{"REDCAP_API_TOKEN":"\(tokenVariable)"},\
        "credentials":{"REDCAP_API_TOKEN":"\(tokenVariable)"},"config":{}}
        """
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
    private static var chunks = 1
    private static var delivered = 0
    private var stopped = false

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

    /// Delivers the body in this many pieces, pausing between them so a cancel
    /// has somewhere to land. One piece — the default — is the single `didLoad`
    /// every other test expects.
    static var chunkCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return chunks
        }
        set {
            lock.lock()
            chunks = max(1, newValue)
            lock.unlock()
        }
    }

    /// How many pieces made it out before `stopLoading` arrived.
    static var deliveredChunks: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    static func reset() {
        lock.lock()
        captured = []
        responseBody = "{}"
        responseStatusCode = 200
        chunks = 1
        delivered = 0
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
        let pieces = Self.chunks
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let data = Data(payload.utf8)
        let size = max(1, Int((Double(data.count) / Double(pieces)).rounded(.up)))
        var offset = 0
        while offset < data.count {
            if isStopped { return }
            let end = min(offset + size, data.count)
            client?.urlProtocol(self, didLoad: Data(data[offset..<end]))
            Self.lock.lock()
            Self.delivered += 1
            Self.lock.unlock()
            offset = end
            if offset < data.count { Thread.sleep(forTimeInterval: 0.01) }
        }
        if isStopped { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        stopped = true
        Self.lock.unlock()
    }

    private var isStopped: Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return stopped
    }

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
