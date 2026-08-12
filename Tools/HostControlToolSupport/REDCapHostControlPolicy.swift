import Foundation
import MCPServerKit

/// Typed, read-only REDCap access held on the host.
///
/// The connector this replaces projected `REDCAP_API_TOKEN` straight into the
/// agent's environment. That is a project API token: whoever holds it can
/// export every record in the project, and the agent had it in a variable it
/// could echo. Brokering it means the token stays in this process, the agent
/// names an operation instead of composing a request, and the set of things it
/// can ask for is a list in this file rather than whatever `curl` accepts.
///
/// Two response paths, because REDCap content types are not equally sensitive:
///
/// - `project`, `metadata`, `user` describe the *shape* of a study — the data
///   dictionary, the field types, who holds export rights. That is precisely
///   what a data-privacy attestation is made of, and it carries no subject
///   data, so it comes back inline.
/// - `record` and `report` return subject data. Those never enter the
///   transcript: the body is written to a file in the task's working directory
///   and the tool returns a receipt. A transcript is persisted, replayed into
///   later prompts, and exported with the workspace; PHI that reaches it is
///   PHI in all three places.
public enum REDCapHostControlPolicy {
    public static let toolName = "redcap"
    public static let serviceType = "redcap"

    /// Content types that return subject data. Anything here is exported to a
    /// file rather than returned inline.
    public static let recordBearingOperations: Set<String> = ["record", "report"]

    public static let readOperations: Set<String> = [
        "status", "project", "metadata", "user", "record", "report"
    ]

    /// Ceiling on an exported body. Well above the inline cap — an export is
    /// the whole point of the call — but still bounded, so a project with a
    /// million rows fails loudly instead of exhausting the broker.
    static let exportByteLimit = 8 * 1024 * 1024

    /// Where exports land, relative to the task's working directory.
    static let exportDirectoryName = "redcap-exports"

    // MARK: - Entry point

    static func handle(
        arguments: [String: Any],
        configuration: HostControlToolConfiguration,
        processLimits: HostControlProcessLimits,
        cancellationRegistry: HostControlOperationCancellationRegistry,
        diagnostics: HostControlToolDiagnosticsRecorder?
    ) -> MCPServerReply {
        let operation = (clean(arguments["operation"] as? String) ?? "status").lowercased()
        guard let connector = connector(
            alias: clean(arguments["alias"] as? String),
            configuration: configuration
        ) else {
            return .error(code: -32602, message: "No REDCap connector is projected into ASTRA_CONNECTORS")
        }
        guard readOperations.contains(operation) else {
            return .error(code: -32602, message: "Unsupported REDCap operation '\(operation)'")
        }

        let status = status(connector: connector, configuration: configuration)
        if operation == "status" {
            diagnostics?.record(toolName: toolName, summary: "redcap status \(connector.alias)", result: nil)
            return textReply(formatted(status), isError: !status.ready)
        }
        guard status.ready else {
            diagnostics?.record(
                toolName: toolName,
                summary: "redcap \(operation) \(connector.alias) blocked: not configured",
                result: nil
            )
            return textReply(formatted(status), isError: true)
        }

        let form: REDCapFormRequest
        do {
            form = try REDCapRequestPolicy.readRequest(operation: operation, arguments: arguments)
        } catch {
            return .error(code: -32602, message: error.localizedDescription)
        }

        let isRecordBearing = recordBearingOperations.contains(operation)
        let byteLimit = isRecordBearing ? exportByteLimit : processLimits.outputByteLimit
        let response = REDCapHTTPClient(
            configuration: configuration,
            cancellationRegistry: cancellationRegistry
        ).request(
            connector: connector,
            form: form,
            token: status.tokenValue,
            timeoutSeconds: timeoutSeconds(from: arguments["timeout_seconds"], limits: processLimits),
            outputByteLimit: byteLimit
        )
        // The summary names the operation, never a parameter: `records` and
        // `fields` can carry study identifiers, and diagnostics are persisted.
        diagnostics?.record(
            toolName: toolName,
            summary: "redcap \(operation) \(connector.alias)",
            result: response.diagnosticResult
        )

        guard isRecordBearing else {
            let formatted = response.formattedPayload(
                configuration: configuration,
                outputByteLimit: processLimits.outputByteLimit
            )
            return textReply(formatted.text, isError: response.isError || formatted.bodyTruncated)
        }
        return exportReply(
            response: response,
            operation: operation,
            configuration: configuration
        )
    }

    // MARK: - Export

    private static func exportReply(
        response: REDCapHTTPResponse,
        operation: String,
        configuration: HostControlToolConfiguration
    ) -> MCPServerReply {
        guard !response.isError else {
            // An error body is REDCap's own message, not subject data, so it is
            // safe to surface — after redaction, since REDCap echoes the token
            // back in some malformed-request errors.
            let message = configuration.redacted(response.errorBody, includingSecretFragments: true)
            return textReply(
                "status_code: \(response.statusCode)\nerror:\n\(message.isEmpty ? "<empty>" : message)",
                isError: true
            )
        }
        do {
            let file = try writeExport(
                body: response.body,
                operation: operation,
                configuration: configuration
            )
            return textReply([
                "status_code: \(response.statusCode)",
                "export_path: \(file.path)",
                "export_bytes: \(file.byteCount)",
                "record_count: \(file.recordCount.map(String.init) ?? "<unknown>")",
                "body_truncated: \(response.bodyTruncated)",
                "note: subject data was written to the file above and deliberately "
                    + "not included here. Read the file if you need the rows."
            ].joined(separator: "\n"), isError: response.bodyTruncated)
        } catch {
            // No inline fallback. Failing to write the file is not a reason to
            // put PHI in the transcript instead.
            return textReply(
                "REDCap export could not be written: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private struct ExportedFile {
        var path: String
        var byteCount: Int
        var recordCount: Int?
    }

    private static func writeExport(
        body: String,
        operation: String,
        configuration: HostControlToolConfiguration
    ) throws -> ExportedFile {
        // Task folder first: the working directory is usually a git checkout,
        // and an export dropped there is one `git add .` from being committed.
        let destination = configuration.taskFolder.isEmpty
            ? configuration.currentDirectory
            : configuration.taskFolder
        let root = destination.isEmpty
            ? FileManager.default.temporaryDirectory
            : URL(fileURLWithPath: destination, isDirectory: true)
        let directory = root.appendingPathComponent(exportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Named from the run and a per-run sequence rather than a timestamp, so
        // a second export in the same run does not overwrite the first and the
        // name stays reproducible in tests.
        let index = exportSequence.next(for: "\(configuration.runID)#\(operation)")
        let name = "redcap-\(operation)-\(configuration.runID)-\(index).json"
        let url = directory.appendingPathComponent(name)
        let data = Data(body.utf8)
        try data.write(to: url, options: .atomic)
        return ExportedFile(path: url.path, byteCount: data.count, recordCount: recordCount(in: body))
    }

    /// Best-effort row count for the receipt. `nil` when the body is not a JSON
    /// array — a truncated export, or a format the caller asked for that is not
    /// JSON. Deliberately does not decode the elements: parsing PHI into memory
    /// to count it defeats the point of keeping it in a file.
    private static func recordCount(in body: String) -> Int? {
        guard let data = body.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return array.count
    }

    private static let exportSequence = REDCapExportSequence()

    // MARK: - Connector and readiness

    static func connector(
        alias: String?,
        configuration: HostControlToolConfiguration
    ) -> HostControlConnector? {
        HostControlBrokeredServices.connector(
            forServiceType: serviceType,
            alias: alias,
            in: configuration
        )
    }

    struct Status {
        var alias: String
        var baseURL: String
        var baseURLReady: Bool
        var tokenEnvKey: String?
        var tokenValue: String

        var tokenReady: Bool { !tokenValue.isEmpty }
        var ready: Bool { baseURLReady && tokenReady }
    }

    static func status(
        connector: HostControlConnector,
        configuration: HostControlToolConfiguration
    ) -> Status {
        let scheme = URL(string: connector.baseURL)?.scheme?.lowercased()
        let tokenEnvKey = envKey(named: "REDCAP_API_TOKEN", in: connector)
            ?? envKey(named: "API_TOKEN", in: connector)
            ?? envKey(named: "TOKEN", in: connector)
        let token = tokenEnvKey
            .flatMap { configuration.environment[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Status(
            alias: connector.alias,
            baseURL: connector.baseURL,
            baseURLReady: scheme == "http" || scheme == "https",
            tokenEnvKey: tokenEnvKey,
            tokenValue: token
        )
    }

    /// Reports the *name* of the variable holding the token and whether it is
    /// populated. Never the value — this is the call an agent makes when it is
    /// trying to work out why REDCap is unavailable, so it is the one most
    /// likely to end up quoted in a transcript.
    static func formatted(_ status: Status) -> String {
        [
            "alias: \(status.alias)",
            "base_url: \(status.baseURLReady ? status.baseURL : "<missing or invalid>")",
            "api_token_env_key: \(status.tokenEnvKey ?? "<missing>")",
            "api_token_present: \(status.tokenReady)",
            "ready: \(status.ready)"
        ].joined(separator: "\n")
    }

    private static func envKey(named logicalName: String, in connector: HostControlConnector) -> String? {
        if let key = connector.credentials[logicalName] ?? connector.env[logicalName] {
            return key
        }
        let normalized = logicalName.uppercased()
        return (Array(connector.credentials.values) + Array(connector.env.values)).first {
            $0.uppercased().hasSuffix(normalized) || $0.uppercased() == normalized
        }
    }

    // MARK: - Schema

    /// The caps come from the server that owns the process limits, so the
    /// description an agent reads matches what the broker will actually
    /// enforce rather than a second copy of the numbers.
    static func toolSchema(timeoutDescription: String) -> [String: Any] {
        [
            "name": toolName,
            "description": "Use typed, read-only ASTRA-projected REDCap operations on the host. The API token "
                + "stays on the host and is never returned. Record and report exports are written to a file in "
                + "the task directory instead of being returned inline.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "operation": [
                        "type": "string",
                        "enum": readOperations.sorted(),
                        "description": "status reports readiness; project, metadata and user return study "
                            + "structure; record and report export subject data to a file."
                    ],
                    "alias": ["type": "string", "description": "Connector alias when more than one REDCap connector is projected."],
                    "fields": ["type": "array", "items": ["type": "string"], "description": "For metadata and record: field names to limit the export to."],
                    "forms": ["type": "array", "items": ["type": "string"], "description": "For metadata and record: instrument names to limit the export to."],
                    "records": ["type": "array", "items": ["type": "string"], "description": "For record: record IDs to limit the export to."],
                    "report_id": ["type": "string", "description": "For report: the numeric REDCap report ID."],
                    "raw_or_label": ["type": "string", "enum": ["raw", "label"], "description": "For record and report: return raw coded values or their labels. Defaults to raw."],
                    "timeout_seconds": ["type": "number", "description": timeoutDescription]
                ],
                "required": ["operation"],
                "additionalProperties": false
            ]
        ]
    }

    // MARK: - Small helpers

    private static func textReply(_ text: String, isError: Bool) -> MCPServerReply {
        .result([
            "content": [["type": "text", "text": text]],
            "isError": isError
        ])
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func timeoutSeconds(from value: Any?, limits: HostControlProcessLimits) -> TimeInterval {
        let requested: TimeInterval
        switch value {
        case let number as Double: requested = number
        case let number as Int: requested = TimeInterval(number)
        case let text as String: requested = TimeInterval(text) ?? limits.maximumTimeoutSeconds
        default: requested = limits.maximumTimeoutSeconds
        }
        return limits.clampedTimeout(requested)
    }
}

/// Per-run export counter. A plain incrementing integer behind a lock; the
/// broker handles one request at a time per connection but the registry is
/// process-wide.
final class REDCapExportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]

    func next(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = (counters[key] ?? 0) + 1
        counters[key] = value
        return value
    }
}

// MARK: - Request policy

struct REDCapFormRequest: Equatable {
    /// REDCap's `content` parameter — the whole API is one endpoint switched on
    /// this value.
    var content: String
    /// Everything except `token`. The token is added by the client so it cannot
    /// be logged from here by accident.
    var parameters: [String: String]

    var diagnosticSummary: String { "content=\(content)" }
}

public enum REDCapRequestPolicy {
    /// REDCap identifiers — field, form, and record names — are alphanumeric
    /// with underscores and hyphens. Anything else is a caller trying to smuggle
    /// a second parameter through a comma-joined list.
    public static let identifierPattern = "^[A-Za-z0-9_.-]{1,64}$"
    public static let maximumIdentifiers = 200

    static func readRequest(operation: String, arguments: [String: Any]) throws -> REDCapFormRequest {
        var parameters = ["format": "json", "returnFormat": "json"]
        switch operation {
        case "project", "user":
            return REDCapFormRequest(content: operation, parameters: parameters)
        case "metadata":
            parameters.merge(try identifierList(arguments["fields"], named: "fields")) { _, new in new }
            parameters.merge(try identifierList(arguments["forms"], named: "forms")) { _, new in new }
            return REDCapFormRequest(content: "metadata", parameters: parameters)
        case "record":
            parameters["type"] = "flat"
            parameters["rawOrLabel"] = try rawOrLabel(arguments["raw_or_label"])
            parameters.merge(try identifierList(arguments["fields"], named: "fields")) { _, new in new }
            parameters.merge(try identifierList(arguments["forms"], named: "forms")) { _, new in new }
            parameters.merge(try identifierList(arguments["records"], named: "records")) { _, new in new }
            return REDCapFormRequest(content: "record", parameters: parameters)
        case "report":
            guard let reportID = (arguments["report_id"] as? String)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                ?? (arguments["report_id"] as? Int).map(String.init),
                  !reportID.isEmpty,
                  reportID.allSatisfy(\.isNumber) else {
                throw REDCapRequestPolicyError("redcap report requires a numeric report_id")
            }
            parameters["report_id"] = reportID
            parameters["rawOrLabel"] = try rawOrLabel(arguments["raw_or_label"])
            return REDCapFormRequest(content: "report", parameters: parameters)
        default:
            throw REDCapRequestPolicyError("Unsupported REDCap operation '\(operation)'")
        }
    }

    private static func rawOrLabel(_ value: Any?) throws -> String {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "raw"
        }
        guard ["raw", "label"].contains(raw.lowercased()) else {
            throw REDCapRequestPolicyError("redcap raw_or_label must be 'raw' or 'label'")
        }
        return raw.lowercased()
    }

    /// REDCap takes repeated parameters as `fields[0]`, `fields[1]`, … Building
    /// them here — rather than accepting a caller-supplied joined string — is
    /// what keeps a value from carrying a `&` and appending a parameter of its
    /// own to the form body.
    private static func identifierList(_ value: Any?, named name: String) throws -> [String: String] {
        guard let value else { return [:] }
        guard let list = value as? [String] else {
            throw REDCapRequestPolicyError("redcap \(name) must be an array of strings")
        }
        guard list.count <= maximumIdentifiers else {
            throw REDCapRequestPolicyError("redcap \(name) accepts at most \(maximumIdentifiers) entries")
        }
        var parameters: [String: String] = [:]
        for (index, rawEntry) in list.enumerated() {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.range(of: identifierPattern, options: .regularExpression) != nil else {
                throw REDCapRequestPolicyError("redcap \(name) entries must be REDCap identifiers")
            }
            parameters["\(name)[\(index)]"] = entry
        }
        return parameters
    }
}

struct REDCapRequestPolicyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Transport

struct REDCapHTTPResponse {
    var statusCode: Int
    var body: String
    var errorMessage: String?
    var bodyTruncated: Bool = false

    var isError: Bool {
        if errorMessage != nil { return true }
        return statusCode < 200 || statusCode >= 300
    }

    /// The body when the request failed. REDCap returns its diagnostics as the
    /// response body, so a caller that only saw `errorMessage` would be told
    /// "400" with no reason.
    var errorBody: String {
        [errorMessage, body.isEmpty ? nil : body]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var diagnosticResult: HostControlCommandResult {
        HostControlCommandResult(
            command: "redcap",
            arguments: ["request"],
            exitCode: isError ? 1 : 0,
            stdout: body,
            stderr: errorMessage ?? "",
            stdoutTruncated: bodyTruncated
        )
    }

    func formattedPayload(
        configuration: HostControlToolConfiguration,
        outputByteLimit: Int
    ) -> (text: String, bodyTruncated: Bool) {
        let redactedBody = configuration.redacted(body, includingSecretFragments: bodyTruncated)
        let formattedBody = HostControlRedactedBody.capped(
            redactedBody,
            label: "REDCap response body",
            byteLimit: outputByteLimit,
            configuration: configuration,
            includeSecretFragments: bodyTruncated
        )
        var lines = [
            "status_code: \(statusCode)",
            "body:",
            formattedBody.value.isEmpty ? "<empty>" : formattedBody.value,
            "error:",
            errorMessage.map { configuration.redacted($0, includingSecretFragments: bodyTruncated) } ?? "<empty>"
        ]
        if bodyTruncated || formattedBody.truncated {
            lines.insert("body_truncated: true", at: 1)
        }
        return (lines.joined(separator: "\n"), bodyTruncated || formattedBody.truncated)
    }
}

final class REDCapHTTPClient {
    private let configuration: HostControlToolConfiguration
    private let cancellationRegistry: HostControlOperationCancellationRegistry

    init(
        configuration: HostControlToolConfiguration,
        cancellationRegistry: HostControlOperationCancellationRegistry
    ) {
        self.configuration = configuration
        self.cancellationRegistry = cancellationRegistry
    }

    func request(
        connector: HostControlConnector,
        form: REDCapFormRequest,
        token: String,
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int
    ) -> REDCapHTTPResponse {
        guard let url = URL(string: connector.baseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return REDCapHTTPResponse(statusCode: 0, body: "", errorMessage: "Invalid REDCap API URL")
        }
        guard !token.isEmpty else {
            return REDCapHTTPResponse(statusCode: 0, body: "", errorMessage: "REDCap connector credentials are not projected")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // REDCap authenticates on a body parameter, not a header. Building the
        // body here is the last point at which the token exists in this flow;
        // nothing upstream of the URLRequest has seen it.
        var fields = form.parameters
        fields["content"] = form.content
        fields["token"] = token
        request.httpBody = Data(Self.formEncoded(fields).utf8)

        let semaphore = DispatchSemaphore(value: 0)
        let delegate = BoundedREDCapHTTPDelegate(semaphore: semaphore, outputByteLimit: outputByteLimit)
        let session = URLSession(
            configuration: HostControlURLSessionConfiguration.brokeredHTTPConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        task.resume()
        let cancelled = LockedFlag()
        let cancellationRegistration = cancellationRegistry.register {
            _ = cancelled.setIfUnset()
            task.cancel()
            session.invalidateAndCancel()
            semaphore.signal()
        }
        defer { cancellationRegistry.unregister(cancellationRegistration) }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return REDCapHTTPResponse(statusCode: 0, body: "", errorMessage: "Timed out after \(Int(timeoutSeconds))s")
        }
        if cancelled.isSet {
            return REDCapHTTPResponse(statusCode: 0, body: "", errorMessage: "Cancelled by ASTRA.")
        }
        session.finishTasksAndInvalidate()
        return delegate.response
    }

    /// Sorted so a request is reproducible in tests, and percent-encoded per
    /// key and value so no identifier can introduce a separator.
    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = (fields[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}

final class BoundedREDCapHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let buffer: BoundedProcessOutput
    private let lock = NSLock()
    private var statusCode = 0
    private var errorMessage: String?

    init(semaphore: DispatchSemaphore, outputByteLimit: Int) {
        self.semaphore = semaphore
        self.buffer = BoundedProcessOutput(label: "REDCap response body", byteLimit: outputByteLimit)
    }

    var response: REDCapHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = buffer.cappedStringValue
        return REDCapHTTPResponse(
            statusCode: statusCode,
            body: snapshot.value,
            errorMessage: errorMessage,
            bodyTruncated: snapshot.truncated || buffer.isTruncated
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Truncation is read back off the buffer, so the flag is not needed here.
        _ = buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let error, (error as NSError).code != NSURLErrorCancelled {
            errorMessage = error.localizedDescription
        }
        lock.unlock()
        semaphore.signal()
    }
}
