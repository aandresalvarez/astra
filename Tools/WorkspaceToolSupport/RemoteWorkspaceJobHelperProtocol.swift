import Foundation

/// Versioned wire contract for a future reviewed remote managed-job helper.
///
/// The contract deliberately carries no command text and no filesystem paths.
/// A trusted installer owns the helper and job roots; a separate staging step
/// writes `command.sh`, and `start` binds that file to a SHA-256 digest. This
/// keeps provider-controlled data out of SSH command lines and prevents the
/// helper from becoming a general remote-shell escape hatch.
public enum RemoteWorkspaceJobHelperProtocol {
    public static let version = 1
    public static let maximumTimeoutSeconds: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumTailLines = 500
    public static let maximumTailBytes = 64 * 1024
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumResponseBytes = 96 * 1024

    public static let helperInstallRelativePath = ".local/share/astra/helpers/v1/astra-remote-job-helper"
    public static let jobRootRelativePath = ".local/state/astra/jobs"
    public static let ownerOnlyDirectoryMode = 0o700
    public static let ownerOnlyFileMode = 0o600
    public static let ownerExecutableFileMode = 0o700

    public static let requestKeys: Set<String> = [
        "protocolVersion",
        "operationID",
        "operation",
        "jobID",
        "generation",
        "commandSHA256",
        "timeoutSeconds",
        "stream",
        "lines"
    ]

    public static let responseKeys: Set<String> = [
        "protocolVersion",
        "operationID",
        "helperSHA256",
        "outcome",
        "job",
        "tail",
        "error"
    ]

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encodeRequest(_ request: RemoteWorkspaceJobHelperRequest) throws -> Data {
        try request.validate()
        let data = try makeEncoder().encode(request)
        try validateEnvelopeSize(data, maximumBytes: maximumRequestBytes)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> RemoteWorkspaceJobHelperRequest {
        try validateEnvelopeSize(data, maximumBytes: maximumRequestBytes)
        try rejectUnknownTopLevelKeys(in: data, allowed: requestKeys)
        let request = try makeDecoder().decode(RemoteWorkspaceJobHelperRequest.self, from: data)
        try request.validate()
        return request
    }

    public static func encodeResponse(_ response: RemoteWorkspaceJobHelperResponse) throws -> Data {
        try response.validate()
        let data = try makeEncoder().encode(response)
        try validateEnvelopeSize(data, maximumBytes: maximumResponseBytes)
        return data
    }

    public static func decodeResponse(_ data: Data) throws -> RemoteWorkspaceJobHelperResponse {
        try validateEnvelopeSize(data, maximumBytes: maximumResponseBytes)
        try rejectUnknownTopLevelKeys(in: data, allowed: responseKeys)
        let response = try makeDecoder().decode(RemoteWorkspaceJobHelperResponse.self, from: data)
        try response.validate()
        return response
    }

    public static func validate(
        response: RemoteWorkspaceJobHelperResponse,
        for request: RemoteWorkspaceJobHelperRequest,
        expectedHelperSHA256: String
    ) throws {
        try request.validate()
        try response.validate()
        try validateSHA256(expectedHelperSHA256)
        guard response.operationID == request.operationID,
              response.helperSHA256 == expectedHelperSHA256 else {
            throw RemoteWorkspaceJobHelperProtocolError.responseBindingMismatch
        }
        guard response.outcome == .accepted else { return }
        if request.operation != .handshake {
            guard let generation = request.generation,
                  response.job?.generation == generation else {
                throw RemoteWorkspaceJobHelperProtocolError.responseBindingMismatch
            }
        }
        switch request.operation {
        case .handshake:
            guard response.job == nil, response.tail == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.responseBindingMismatch
            }
        case .start, .status, .cancel:
            guard let job = response.job, response.tail == nil,
                  job.jobID == request.jobID else {
                throw RemoteWorkspaceJobHelperProtocolError.responseBindingMismatch
            }
        case .tail:
            guard let job = response.job, let tail = response.tail,
                  job.jobID == request.jobID, tail.stream == request.stream else {
                throw RemoteWorkspaceJobHelperProtocolError.responseBindingMismatch
            }
        }
    }

    static func validateJobID(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.count <= 80,
              value.unicodeScalars.allSatisfy({ scalar in
                  let code = scalar.value
                  return (97...122).contains(code) || (48...57).contains(code) || code == 45 || code == 95
              }) else {
            throw RemoteWorkspaceJobHelperProtocolError.invalidJobID
        }
    }

    static func validateSHA256(_ value: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  let code = scalar.value
                  return (48...57).contains(code) || (97...102).contains(code)
              }) else {
            throw RemoteWorkspaceJobHelperProtocolError.invalidSHA256
        }
    }

    private static func rejectUnknownTopLevelKeys(in data: Data, allowed: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteWorkspaceJobHelperProtocolError.invalidEnvelope
        }
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw RemoteWorkspaceJobHelperProtocolError.unknownFields(unknown.sorted())
        }
    }

    private static func validateEnvelopeSize(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else {
            throw RemoteWorkspaceJobHelperProtocolError.envelopeTooLarge
        }
    }
}

public enum RemoteWorkspaceJobHelperOperation: String, Codable, Sendable {
    case handshake
    case start
    case status
    case tail
    case cancel
}

public enum RemoteWorkspaceJobHelperStream: String, Codable, Sendable {
    case stdout
    case stderr
}

public struct RemoteWorkspaceJobHelperRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operationID: UUID
    public let operation: RemoteWorkspaceJobHelperOperation
    public let jobID: String?
    public let generation: UUID?
    public let commandSHA256: String?
    public let timeoutSeconds: TimeInterval?
    public let stream: RemoteWorkspaceJobHelperStream?
    public let lines: Int?

    public init(
        protocolVersion: Int = RemoteWorkspaceJobHelperProtocol.version,
        operationID: UUID,
        operation: RemoteWorkspaceJobHelperOperation,
        jobID: String? = nil,
        generation: UUID? = nil,
        commandSHA256: String? = nil,
        timeoutSeconds: TimeInterval? = nil,
        stream: RemoteWorkspaceJobHelperStream? = nil,
        lines: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.operationID = operationID
        self.operation = operation
        self.jobID = jobID
        self.generation = generation
        self.commandSHA256 = commandSHA256
        self.timeoutSeconds = timeoutSeconds
        self.stream = stream
        self.lines = lines
    }

    public func validate() throws {
        guard protocolVersion == RemoteWorkspaceJobHelperProtocol.version else {
            throw RemoteWorkspaceJobHelperProtocolError.unsupportedVersion(protocolVersion)
        }
        if let jobID {
            try RemoteWorkspaceJobHelperProtocol.validateJobID(jobID)
        }
        switch operation {
        case .handshake:
            guard jobID == nil, generation == nil, commandSHA256 == nil,
                  timeoutSeconds == nil, stream == nil, lines == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.unexpectedFields(operation.rawValue)
            }
        case .start:
            guard jobID != nil, generation != nil, let commandSHA256,
                  stream == nil, lines == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.missingOrUnexpectedFields(operation.rawValue)
            }
            try RemoteWorkspaceJobHelperProtocol.validateSHA256(commandSHA256)
            if let timeoutSeconds {
                guard timeoutSeconds.isFinite, timeoutSeconds > 0,
                      timeoutSeconds <= RemoteWorkspaceJobHelperProtocol.maximumTimeoutSeconds else {
                    throw RemoteWorkspaceJobHelperProtocolError.invalidTimeout
                }
            }
        case .status:
            guard jobID != nil, generation != nil, commandSHA256 == nil,
                  timeoutSeconds == nil, stream == nil, lines == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.missingOrUnexpectedFields(operation.rawValue)
            }
        case .tail:
            guard jobID != nil, generation != nil, commandSHA256 == nil,
                  timeoutSeconds == nil, stream != nil, let lines,
                  (1...RemoteWorkspaceJobHelperProtocol.maximumTailLines).contains(lines) else {
                throw RemoteWorkspaceJobHelperProtocolError.invalidTailRequest
            }
        case .cancel:
            guard jobID != nil, generation != nil, commandSHA256 == nil,
                  timeoutSeconds == nil, stream == nil, lines == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.missingOrUnexpectedFields(operation.rawValue)
            }
        }
    }
}

public enum RemoteWorkspaceJobHelperOutcome: String, Codable, Sendable {
    case accepted
    case rejected
}

public struct RemoteWorkspaceJobProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let processGroupID: Int32
    /// Remote boot identifier. Prevents a PID from being trusted after reboot.
    public let bootID: String
    /// Kernel process start marker (for Linux, `/proc/<pid>/stat` starttime).
    public let startMarker: String

    public init(pid: Int32, processGroupID: Int32, bootID: String, startMarker: String) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.bootID = bootID
        self.startMarker = startMarker
    }

    public func validate() throws {
        guard pid > 1, processGroupID == pid,
              !bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !startMarker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteWorkspaceJobHelperProtocolError.invalidProcessIdentity
        }
    }
}

public struct RemoteWorkspaceJobFileSet: Codable, Equatable, Sendable {
    public let metadata: String
    public let command: String
    public let standardOutput: String
    public let standardError: String
    public let heartbeat: String
    public let result: String
    public let processIdentity: String

    public init(
        metadata: String = "job.json",
        command: String = "command.sh",
        standardOutput: String = "stdout.log",
        standardError: String = "stderr.log",
        heartbeat: String = "heartbeat.json",
        result: String = "result.json",
        processIdentity: String = "process.json"
    ) {
        self.metadata = metadata
        self.command = command
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.heartbeat = heartbeat
        self.result = result
        self.processIdentity = processIdentity
    }
}

public struct RemoteWorkspaceJobTailPayload: Codable, Equatable, Sendable {
    public let stream: RemoteWorkspaceJobHelperStream
    public let text: String
    public let truncated: Bool

    public init(stream: RemoteWorkspaceJobHelperStream, text: String, truncated: Bool) {
        self.stream = stream
        self.text = text
        self.truncated = truncated
    }

    public func validate() throws {
        guard text.utf8.count <= RemoteWorkspaceJobHelperProtocol.maximumTailBytes else {
            throw RemoteWorkspaceJobHelperProtocolError.tailTooLarge
        }
    }
}

public struct RemoteWorkspaceJobSnapshot: Codable, Equatable, Sendable {
    public let jobID: String
    public let generation: UUID
    public let status: WorkspaceManagedJobStatus
    public let observedAt: Date
    public let acceptedAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let lastHeartbeatAt: Date?
    public let lastOutputAt: Date?
    public let exitCode: Int32?
    public let process: RemoteWorkspaceJobProcessIdentity?
    public let files: RemoteWorkspaceJobFileSet
    public let message: String?

    public init(
        jobID: String,
        generation: UUID,
        status: WorkspaceManagedJobStatus,
        observedAt: Date,
        acceptedAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        lastOutputAt: Date? = nil,
        exitCode: Int32? = nil,
        process: RemoteWorkspaceJobProcessIdentity? = nil,
        files: RemoteWorkspaceJobFileSet = .init(),
        message: String? = nil
    ) {
        self.jobID = jobID
        self.generation = generation
        self.status = status
        self.observedAt = observedAt
        self.acceptedAt = acceptedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastOutputAt = lastOutputAt
        self.exitCode = exitCode
        self.process = process
        self.files = files
        self.message = message
    }

    public func validate() throws {
        try RemoteWorkspaceJobHelperProtocol.validateJobID(jobID)
        if status == .running {
            guard let process else {
                throw RemoteWorkspaceJobHelperProtocolError.missingProcessIdentity
            }
            try process.validate()
        } else if let process {
            try process.validate()
        }
        guard observedAt >= acceptedAt else {
            throw RemoteWorkspaceJobHelperProtocolError.invalidTimestamps
        }
        if status == .queued || status == .running {
            guard completedAt == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.invalidTerminalState
            }
        } else {
            guard completedAt != nil else {
                throw RemoteWorkspaceJobHelperProtocolError.invalidTerminalState
            }
        }
        guard files == RemoteWorkspaceJobFileSet() else {
            throw RemoteWorkspaceJobHelperProtocolError.invalidFileLayout
        }
    }
}

public struct RemoteWorkspaceJobHelperFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RemoteWorkspaceJobHelperResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operationID: UUID
    public let helperSHA256: String
    public let outcome: RemoteWorkspaceJobHelperOutcome
    public let job: RemoteWorkspaceJobSnapshot?
    public let tail: RemoteWorkspaceJobTailPayload?
    public let error: RemoteWorkspaceJobHelperFailure?

    public init(
        protocolVersion: Int = RemoteWorkspaceJobHelperProtocol.version,
        operationID: UUID,
        helperSHA256: String,
        outcome: RemoteWorkspaceJobHelperOutcome,
        job: RemoteWorkspaceJobSnapshot? = nil,
        tail: RemoteWorkspaceJobTailPayload? = nil,
        error: RemoteWorkspaceJobHelperFailure? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.operationID = operationID
        self.helperSHA256 = helperSHA256
        self.outcome = outcome
        self.job = job
        self.tail = tail
        self.error = error
    }

    public func validate() throws {
        guard protocolVersion == RemoteWorkspaceJobHelperProtocol.version else {
            throw RemoteWorkspaceJobHelperProtocolError.unsupportedVersion(protocolVersion)
        }
        try RemoteWorkspaceJobHelperProtocol.validateSHA256(helperSHA256)
        switch outcome {
        case .accepted:
            guard error == nil else {
                throw RemoteWorkspaceJobHelperProtocolError.invalidOutcome
            }
            try job?.validate()
            try tail?.validate()
        case .rejected:
            guard job == nil, tail == nil, let error,
                  !error.code.isEmpty, !error.message.isEmpty else {
                throw RemoteWorkspaceJobHelperProtocolError.invalidOutcome
            }
        }
    }
}

public struct RemoteWorkspaceJobHelperDeploymentManifest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let helperSHA256: String
    public let helperInstallRelativePath: String
    public let jobRootRelativePath: String
    public let helperFileMode: Int
    public let jobRootMode: Int
    public let rejectsSymlinks: Bool

    public init(helperSHA256: String) throws {
        try RemoteWorkspaceJobHelperProtocol.validateSHA256(helperSHA256)
        self.protocolVersion = RemoteWorkspaceJobHelperProtocol.version
        self.helperSHA256 = helperSHA256
        self.helperInstallRelativePath = RemoteWorkspaceJobHelperProtocol.helperInstallRelativePath
        self.jobRootRelativePath = RemoteWorkspaceJobHelperProtocol.jobRootRelativePath
        self.helperFileMode = RemoteWorkspaceJobHelperProtocol.ownerExecutableFileMode
        self.jobRootMode = RemoteWorkspaceJobHelperProtocol.ownerOnlyDirectoryMode
        self.rejectsSymlinks = true
    }
}

public enum RemoteWorkspaceJobHelperProtocolError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidEnvelope
    case envelopeTooLarge
    case unknownFields([String])
    case invalidJobID
    case invalidSHA256
    case invalidTimeout
    case invalidTailRequest
    case unexpectedFields(String)
    case missingOrUnexpectedFields(String)
    case invalidProcessIdentity
    case missingProcessIdentity
    case invalidTimestamps
    case invalidTerminalState
    case invalidOutcome
    case invalidFileLayout
    case tailTooLarge
    case responseBindingMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported remote job helper protocol version: \(version)."
        case .invalidEnvelope: "Remote job helper message must be a JSON object."
        case .envelopeTooLarge: "Remote job helper message exceeded the bounded envelope size."
        case .unknownFields(let fields): "Remote job helper message contains unknown fields: \(fields.joined(separator: ", "))."
        case .invalidJobID: "Remote job id must be lowercase ASCII and path-free."
        case .invalidSHA256: "Remote job helper SHA-256 values must be 64 lowercase hexadecimal characters."
        case .invalidTimeout: "Remote job timeout is outside the supported bounded range."
        case .invalidTailRequest: "Remote job tail request is missing a stream or uses an invalid line limit."
        case .unexpectedFields(let operation): "Remote job helper operation \(operation) contains unexpected fields."
        case .missingOrUnexpectedFields(let operation): "Remote job helper operation \(operation) has an invalid field set."
        case .invalidProcessIdentity: "Remote job process identity is not safe for later cancellation."
        case .missingProcessIdentity: "A running remote job must include restart-safe process identity evidence."
        case .invalidTimestamps: "Remote job observation predates launch acceptance."
        case .invalidTerminalState: "Remote job status and completion timestamp disagree."
        case .invalidOutcome: "Remote job helper response outcome and payload disagree."
        case .invalidFileLayout: "Remote job helper response attempted to override the fixed durable file layout."
        case .tailTooLarge: "Remote job helper tail exceeded the bounded response size."
        case .responseBindingMismatch: "Remote job helper response does not match the signed request or installed helper."
        }
    }
}
