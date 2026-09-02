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
        let resolution = resolveConnector(
            alias: clean(arguments["alias"] as? String),
            configuration: configuration
        )
        guard let connector = resolution.connector else {
            return .error(
                code: -32602,
                message: resolution.failureMessage(serviceLabel: "REDCap") ?? "No REDCap connector is available"
            )
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
            return textReply(
                exportFailureText(
                    response: response,
                    operation: operation,
                    configuration: configuration
                ),
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

    /// What a failed record-bearing call is allowed to say out loud.
    ///
    /// `REDCapHTTPResponse.errorBody` is the general path and it is the wrong
    /// one here. For `record` and `report` the response body *is* subject data:
    /// a transfer that drops after the first rows have arrived leaves
    /// `isError` true with a partial export sitting in `body`, and returning
    /// that inline puts PHI in the transcript by exactly the route the
    /// file-only rule exists to close — with nothing in the reply saying so.
    /// The same is true of a 500 that arrives after a streamed export began.
    ///
    /// REDCap's own diagnostics survive because they are structurally
    /// distinct: every request here sets `returnFormat=json`, and an API
    /// refusal comes back as a JSON *object* with an `error` key, never as the
    /// array of rows an export returns. So that object is surfaced and
    /// anything else is counted and dropped.
    private static func exportFailureText(
        response: REDCapHTTPResponse,
        operation: String,
        configuration: HostControlToolConfiguration
    ) -> String {
        var lines = ["status_code: \(response.statusCode)"]
        if let message = response.errorMessage, !message.isEmpty {
            lines.append("error: \(configuration.redacted(message, includingSecretFragments: true))")
        }
        if let diagnostic = redcapErrorDocument(in: response.body) {
            // Redacted because REDCap echoes the token back in some
            // malformed-request errors.
            lines.append("redcap_error: \(configuration.redacted(diagnostic, includingSecretFragments: true))")
        } else if !response.body.isEmpty {
            lines.append("withheld_body_bytes: \(response.body.utf8.count)")
            lines.append(
                "note: the failed \(operation) response was withheld because a record-bearing body can "
                    + "hold subject data even when the request failed. It was not written to a file either."
            )
        }
        if lines.count == 1 { lines.append("error: <empty>") }
        return lines.joined(separator: "\n")
    }

    /// Ceiling on a surfaced REDCap diagnostic. It is a sentence in practice;
    /// this is only here so a misbehaving endpoint cannot use the `error` key
    /// as an inline channel.
    static let exportErrorMessageLimit = 2048

    /// REDCap's documented failure shape. An export is a JSON array, and a
    /// partial one does not parse at all, so this cannot match subject data.
    private static func redcapErrorDocument(in body: String) -> String? {
        guard body.utf8.count <= exportErrorMessageLimit * 8,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String,
              !message.isEmpty else {
            return nil
        }
        return String(message.prefix(exportErrorMessageLimit))
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
        // The task folder or nothing. The two fallbacks that used to be here
        // both put subject data somewhere nobody chose: the working directory
        // is usually a git checkout, one `git add .` from committing PHI, and
        // the temporary directory is world-readable and reaped by the system on
        // a schedule ASTRA does not control. An export with nowhere sanctioned
        // to go is a refusal — the caller already treats a write failure as
        // "the rows stay at REDCap", which is the right outcome.
        guard !configuration.taskFolder.isEmpty else {
            throw REDCapRequestPolicyError(
                "ASTRA did not project a task folder for this run, so there is nowhere to put "
                    + "the export. Subject data will not be written to the working directory."
            )
        }
        let root = URL(fileURLWithPath: configuration.taskFolder, isDirectory: true)
            .resolvingSymlinksInPath()
        let directory = try exportDirectory(beneath: root)

        // Named from the run and a per-run sequence rather than a timestamp, so
        // a second export in the same run does not overwrite the first and the
        // name stays reproducible in tests.
        let data = Data(body.utf8)
        let url = try writeExclusively(
            data,
            in: directory,
            named: { "redcap-\(operation)-\(configuration.runID)-\($0).json" },
            startingAt: exportSequence.next(for: "\(configuration.runID)#\(operation)")
        )
        return ExportedFile(path: url.path, byteCount: data.count, recordCount: recordCount(in: body))
    }

    /// Creates `redcap-exports` under the task folder, refusing to follow a
    /// symlink out of it.
    ///
    /// The rule and its reasoning live in `TaskFolderContainment`, which the
    /// connector-mutation staging directory now shares: the hole was found here
    /// first and was identical there, and a containment rule written twice is a
    /// containment rule enforced once.
    private static func exportDirectory(
        beneath root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try TaskFolderContainment.createDirectory(
            named: exportDirectoryName,
            beneath: root,
            refusal: "write subject data",
            fileManager: fileManager,
            makeError: { REDCapRequestPolicyError($0) }
        )
    }

    /// How many names to try before giving up. Bounded so a directory that
    /// somehow cannot accept a new file fails loudly instead of spinning.
    static let maximumExportNameAttempts = 512

    /// Writes to the first free name, and lets the filesystem decide what free
    /// means.
    ///
    /// `exportSequence` is process-local. A broker restart — or a second broker
    /// instance serving another connection for the same run — starts back at 1,
    /// and a plain write then replaced the earlier export while the earlier
    /// receipt still pointed at that path: the agent reads a file it was told
    /// held one export and finds another. Probing for a free name does not fix
    /// it either, since two brokers can both see the same name free at the same
    /// instant.
    ///
    /// So the name is claimed by `link(2)`, which either creates the entry or
    /// fails with `EEXIST` and cannot do anything in between. The content is
    /// written to a temporary in the same directory first, so what appears
    /// under the claimed name is a complete export rather than a file being
    /// filled in — `Data.WritingOptions` cannot do both halves, since `.atomic`
    /// and `.withoutOverwriting` are mutually exclusive.
    private static func writeExclusively(
        _ data: Data,
        in directory: URL,
        named name: (Int) -> String,
        startingAt start: Int,
        fileManager: FileManager = .default
    ) throws -> URL {
        let temporary = directory.appendingPathComponent(".redcap-export-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        // The link is what the reader sees; this name never appears in a
        // receipt, and it goes whether or not a link was made.
        defer { try? fileManager.removeItem(at: temporary) }

        var index = max(1, start)
        for _ in 0..<maximumExportNameAttempts {
            let url = directory.appendingPathComponent(name(index))
            if link(temporary.path, url.path) == 0 { return url }
            guard errno == EEXIST else {
                throw REDCapRequestPolicyError(
                    "ASTRA could not write the export to \(url.path): "
                        + String(cString: strerror(errno))
                )
            }
            index += 1
        }
        throw REDCapRequestPolicyError(
            "ASTRA could not find a free export filename in \(directory.path) after "
                + "\(maximumExportNameAttempts) attempts."
        )
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

    static func resolveConnector(
        alias: String?,
        configuration: HostControlToolConfiguration
    ) -> HostControlConnectorResolution {
        HostControlBrokeredServices.resolveConnector(
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
                    "alias": [
                        "type": "string",
                        "description": "Connector alias, or its id. Optional when one REDCap connector is "
                            + "projected and required when more than one is: ASTRA refuses the call rather "
                            + "than choosing a study for you, and names the aliases in scope."
                    ],
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
        // Truncation is read back off the buffer, so no flag is needed here —
        // but the cancel is. The buffer stops accumulating at the limit and
        // says so, and discarding that answer left the session downloading the
        // rest of the response anyway: for the 8 MiB export cap that is a whole
        // project's rows pulled over the network and the broker operation held
        // open for as long as it takes, to produce a reply that was already
        // decided. Cancelling surfaces as `NSURLErrorCancelled`, which
        // `didCompleteWithError` below deliberately does not treat as a failure.
        if buffer.append(data) {
            dataTask.cancel()
        }
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
