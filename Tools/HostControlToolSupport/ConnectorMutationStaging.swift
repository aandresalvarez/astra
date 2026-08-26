import CryptoKit
import Foundation

/// The file a brokered connector writes when it has composed a mutation it is
/// not allowed to send.
///
/// Every brokered operation before this one was a read, and the safety argument
/// was that the set of things an agent could ask for was a list in this module.
/// A write cannot join that list: the per-tool grant that authorizes `jira` is
/// collected once, before any content exists, so it cannot consent to content.
/// So a mutation is split in two — the agent composes and stages, the user
/// approves, and the app sends using the credential that never left it.
///
/// This is the seam between those halves, and the file is deliberately the
/// whole channel. The broker cannot call the app: it is a separate process
/// speaking MCP, and the observation the app receives for a tool call carries
/// input *keys* only, never values or results (`PolicyObservedEvent`). What the
/// app can do is read the task folder it projected. So the staged file carries
/// everything the commit needs, and its SHA-256 is the name the approval is
/// bound to.
///
/// Both halves live here on purpose. `ASTRA` depends on `HostControlToolSupport`,
/// so the app reads this envelope with `read(atPath:containedIn:)` rather than
/// reimplementing the format — a mutation format parsed by two hand-written
/// decoders is a mutation format with two meanings, and the digest would be
/// binding the user's approval to only one of them.
public enum ConnectorMutationStaging {
    /// Bumped when the envelope's shape changes. The reader refuses anything
    /// it does not recognise instead of best-effort decoding: a field it
    /// silently ignored would be a field the user reviewed and the app did not
    /// send, or worse, did not review and the app did.
    public static let schemaVersion = 1

    /// Where staged mutations land, relative to the task folder.
    public static let directoryName = "connector-mutations"

    /// Ceiling on a staged envelope. A Jira description is prose; anything past
    /// this is not a ticket anyone will review.
    public static let envelopeByteLimit = 1024 * 1024

    // MARK: - Staged mutation

    /// A staged mutation, as written or as read back. One type for both
    /// directions so the writer cannot express something the reader cannot
    /// recover.
    public struct StagedConnectorMutation: Equatable, Sendable {
        /// Absolute path to the envelope on the host.
        public var path: String
        /// SHA-256 over the envelope's exact bytes, lowercase hex.
        public var digest: String
        public var byteCount: Int

        /// Lowercased connector service type, e.g. `jira`.
        public var serviceType: String
        /// The mutating operation the app will perform, e.g. `create_issue`.
        /// Not the `propose_issue` the agent called: proposing and committing
        /// are different acts by different parties.
        public var operation: String
        /// Connector identity as the app projected it, so the commit resolves
        /// the same credential the proposal was composed against.
        public var connectorID: String
        public var connectorAlias: String
        /// Human-readable destination, e.g. `STAR / Bug`. Scope, not content.
        public var target: String
        /// One-line description of the mutation, for the approval row.
        public var summary: String

        public var requestMethod: String
        public var requestPath: String
        /// Canonical JSON body, ready to send. Derived from the envelope, so it
        /// changes if and only if the digest does.
        public var requestBody: Data

        public init(
            path: String,
            digest: String,
            byteCount: Int,
            serviceType: String,
            operation: String,
            connectorID: String,
            connectorAlias: String,
            target: String,
            summary: String,
            requestMethod: String,
            requestPath: String,
            requestBody: Data
        ) {
            self.path = path
            self.digest = digest
            self.byteCount = byteCount
            self.serviceType = serviceType
            self.operation = operation
            self.connectorID = connectorID
            self.connectorAlias = connectorAlias
            self.target = target
            self.summary = summary
            self.requestMethod = requestMethod
            self.requestPath = requestPath
            self.requestBody = requestBody
        }
    }

    // MARK: - Writing

    /// Renders and writes an envelope, returning the digest the approval will
    /// be bound to. Sends nothing.
    ///
    /// - Parameter body: the request payload as `JSONSerialization` types.
    static func stage(
        serviceType: String,
        operation: String,
        connector: HostControlConnector,
        target: String,
        summary: String,
        requestMethod: String,
        requestPath: String,
        body: [String: Any],
        configuration: HostControlToolConfiguration
    ) throws -> StagedConnectorMutation {
        // No fallback to the working directory, and none to a temp dir. A
        // REDCap export is useful wherever it lands, so it falls back; a
        // proposal is only useful where the app will look for it, and one
        // written somewhere else is a mutation the user can never approve and
        // never knows is pending. Fail where it can be fixed.
        guard !configuration.taskFolder.isEmpty else {
            throw ConnectorMutationStagingError(
                "No task folder is projected, so a proposal cannot be staged where ASTRA would find it"
            )
        }
        let directory = stagingDirectory(taskFolder: configuration.taskFolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let envelope: [String: Any] = [
            "schema_version": schemaVersion,
            "service_type": serviceType,
            "operation": operation,
            "connector_id": connector.id,
            "connector_alias": connector.alias,
            "target": target,
            "summary": summary,
            "request": [
                "method": requestMethod,
                "path": requestPath,
                "body": body
            ]
        ]
        let data = try canonicalJSON(envelope, prettyPrinted: true)
        guard data.count <= envelopeByteLimit else {
            throw ConnectorMutationStagingError(
                "Staged \(serviceType) \(operation) is \(data.count) bytes, over the \(envelopeByteLimit)-byte limit"
            )
        }

        // Named from the run and a per-run sequence rather than a timestamp, so
        // a second proposal in the same run does not overwrite the first and
        // the name stays reproducible in tests.
        //
        // The name is also the proposal's identity to the app, which reads the
        // directory rather than being told what landed in it. So the counter
        // alone is not enough: it lives in this process, and a broker restarted
        // mid-run would hand out `1` again and overwrite a proposal the app has
        // already recorded and the user may be about to approve. Probing for a
        // free name makes the identity a property of the directory instead.
        let key = "\(configuration.runID)#\(serviceType)#\(operation)"
        var url = directory.appendingPathComponent(
            "\(serviceType)-\(operation)-\(configuration.runID)-\(sequence.next(for: key)).json"
        )
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                "\(serviceType)-\(operation)-\(configuration.runID)-\(sequence.next(for: key)).json"
            )
        }
        try data.write(to: url, options: .atomic)

        return StagedConnectorMutation(
            path: url.path,
            digest: sha256Hex(data),
            byteCount: data.count,
            serviceType: serviceType,
            operation: operation,
            connectorID: connector.id,
            connectorAlias: connector.alias,
            target: target,
            summary: summary,
            requestMethod: requestMethod,
            requestPath: requestPath,
            requestBody: try canonicalJSON(body, prettyPrinted: false)
        )
    }

    // MARK: - Reading

    /// The directory the app scans for pending proposals.
    public static func stagingDirectory(taskFolder: String) -> URL {
        URL(fileURLWithPath: taskFolder, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Reads a staged envelope back, verifying it still lives where it was
    /// staged and still hashes to `expectedDigest` when one is supplied.
    ///
    /// `containedIn` is not optional, and that is the point. The path in an
    /// authorization is a string that has been through the permission ledger;
    /// reading it without proving it is still inside the task folder is how a
    /// rewritten path becomes an arbitrary-file read. Callers must name the
    /// directory the file is allowed to be in.
    public static func read(
        atPath path: String,
        containedIn taskFolder: String,
        expectedDigest: String? = nil
    ) throws -> StagedConnectorMutation {
        let directory = stagingDirectory(taskFolder: taskFolder).resolvingSymlinksInPath()
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw ConnectorMutationStagingError(
                "Staged mutation is not inside this task's \(directoryName) directory"
            )
        }
        let data = try Data(contentsOf: url)
        guard data.count <= envelopeByteLimit else {
            throw ConnectorMutationStagingError("Staged mutation is larger than the \(envelopeByteLimit)-byte limit")
        }
        let digest = sha256Hex(data)
        // Checked before decoding, so a rewritten envelope is refused as a
        // mismatch rather than reported as whatever it now says it is.
        if let expectedDigest, digest != expectedDigest.lowercased() {
            throw ConnectorMutationStagingError(
                "Staged mutation changed after it was approved: expected \(expectedDigest.lowercased()), found \(digest)"
            )
        }
        return try decode(data: data, digest: digest, path: url.path)
    }

    private static func decode(data: Data, digest: String, path: String) throws -> StagedConnectorMutation {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorMutationStagingError("Staged mutation is not a JSON object")
        }
        guard let version = envelope["schema_version"] as? Int, version == schemaVersion else {
            throw ConnectorMutationStagingError(
                "Staged mutation uses an unsupported schema version; expected \(schemaVersion)"
            )
        }
        guard let request = envelope["request"] as? [String: Any],
              let body = request["body"] as? [String: Any] else {
            throw ConnectorMutationStagingError("Staged mutation has no request body")
        }
        return StagedConnectorMutation(
            path: path,
            digest: digest,
            byteCount: data.count,
            serviceType: try string(envelope["service_type"], field: "service_type"),
            operation: try string(envelope["operation"], field: "operation"),
            connectorID: try string(envelope["connector_id"], field: "connector_id"),
            connectorAlias: try string(envelope["connector_alias"], field: "connector_alias"),
            target: try string(envelope["target"], field: "target"),
            summary: try string(envelope["summary"], field: "summary"),
            requestMethod: try string(request["method"], field: "request.method"),
            requestPath: try string(request["path"], field: "request.path"),
            requestBody: try canonicalJSON(body, prettyPrinted: false)
        )
    }

    private static func string(_ value: Any?, field: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw ConnectorMutationStagingError("Staged mutation is missing '\(field)'")
        }
        return value
    }

    // MARK: - Canonical form

    /// Sorted keys, so the same proposal always produces the same bytes and the
    /// same digest. Pretty-printed for the envelope because a human reads it
    /// before approving; compact for the request body because a server does.
    private static func canonicalJSON(_ object: Any, prettyPrinted: Bool) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            options.insert(.prettyPrinted)
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ConnectorMutationStagingError("Staged mutation is not representable as JSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let sequence = ConnectorMutationSequence()
}

public struct ConnectorMutationStagingError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

final class ConnectorMutationSequence: @unchecked Sendable {
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
