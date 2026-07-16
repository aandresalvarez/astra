import Foundation

public enum WorkspaceManagedJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .succeeded, .failed, .cancelled, .timedOut:
            true
        }
    }
}

public enum WorkspaceManagedJobContractError: LocalizedError, Equatable, Sendable {
    case invalidTaskID
    case invalidRunID
    case invalidInvocationID
    case invalidContainerName
    case invalidJobID
    case invalidExternalIdentity
    case invalidSchema
    case missingStartReceipt
    case receiptJobMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidTaskID: "Invalid workspace managed-job task id."
        case .invalidRunID: "Invalid workspace managed-job run id."
        case .invalidInvocationID: "Invalid workspace managed-job invocation id."
        case .invalidContainerName: "Invalid workspace managed-job container name."
        case .invalidJobID: "Invalid workspace managed-job id."
        case .invalidExternalIdentity: "Invalid workspace managed-job external identity."
        case .invalidSchema: "Unsupported workspace managed-job result schema."
        case .missingStartReceipt: "A running workspace managed job requires a trusted start receipt."
        case .receiptJobMismatch: "Workspace managed-job receipt does not match its job record."
        }
    }
}

public struct WorkspaceManagedJobStartReceipt: Codable, Equatable, Sendable {
    public static let backend = "docker_workspace_job"

    public var taskID: UUID
    public var runID: UUID
    public var invocationID: String
    public var containerName: String
    public var externalIdentity: String

    public init(
        taskID: UUID,
        runID: UUID,
        invocationID: String,
        containerName: String,
        externalIdentity: String
    ) throws {
        self.taskID = taskID
        self.runID = runID
        self.invocationID = invocationID
        self.containerName = containerName
        self.externalIdentity = externalIdentity
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case taskID
        case runID
        case invocationID
        case containerName
        case externalIdentity
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownManagedJobKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        runID = try container.decode(UUID.self, forKey: .runID)
        invocationID = try container.decode(String.self, forKey: .invocationID)
        containerName = try container.decode(String.self, forKey: .containerName)
        externalIdentity = try container.decode(String.self, forKey: .externalIdentity)
        try validate()
    }

    public static func make(
        taskID: String,
        runID: String,
        invocationID: String,
        containerName: String,
        jobID: String
    ) throws -> WorkspaceManagedJobStartReceipt {
        guard let taskUUID = UUID(uuidString: taskID) else {
            throw WorkspaceManagedJobContractError.invalidTaskID
        }
        guard let runUUID = UUID(uuidString: runID) else {
            throw WorkspaceManagedJobContractError.invalidRunID
        }
        let canonicalJobID = try canonicalIdentifier(jobID, error: .invalidJobID)
        return try WorkspaceManagedJobStartReceipt(
            taskID: taskUUID,
            runID: runUUID,
            invocationID: invocationID,
            containerName: containerName,
            externalIdentity: externalIdentity(
                taskID: taskUUID,
                runID: runUUID,
                jobID: canonicalJobID
            )
        )
    }

    public func validate(jobID: String? = nil) throws {
        let trimmedInvocationID = invocationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInvocationID.isEmpty,
              trimmedInvocationID.count <= 256,
              trimmedInvocationID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw WorkspaceManagedJobContractError.invalidInvocationID
        }
        guard containerName.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw WorkspaceManagedJobContractError.invalidContainerName
        }
        if let jobID {
            let canonicalJobID = try Self.canonicalIdentifier(jobID, error: .invalidJobID)
            guard externalIdentity == Self.externalIdentity(
                taskID: taskID,
                runID: runID,
                jobID: canonicalJobID
            ) else {
                throw WorkspaceManagedJobContractError.receiptJobMismatch
            }
        } else {
            guard externalIdentity.hasPrefix(Self.backend + ":"),
                  externalIdentity.count <= 256 else {
                throw WorkspaceManagedJobContractError.invalidExternalIdentity
            }
        }
    }

    public func belongsTo(taskID: String, runID: String, containerName: String) -> Bool {
        guard let taskUUID = UUID(uuidString: taskID),
              let runUUID = UUID(uuidString: runID) else {
            return false
        }
        return self.taskID == taskUUID
            && self.runID == runUUID
            && self.containerName == containerName
    }

    private static func externalIdentity(taskID: UUID, runID: UUID, jobID: String) -> String {
        [
            backend,
            taskID.uuidString.lowercased(),
            runID.uuidString.lowercased(),
            jobID.lowercased()
        ].joined(separator: ":")
    }

    private static func canonicalIdentifier(
        _ value: String,
        error: WorkspaceManagedJobContractError
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (65...90).contains(value)
                      || (97...122).contains(value)
                      || (48...57).contains(value)
                      || value == 45
                      || value == 95
              }) else {
            throw error
        }
        return trimmed.lowercased()
    }
}

/// The only job-start/status shape allowed across the MCP boundary. It omits
/// executor commands, log paths, messages, and other backend-private data.
public struct WorkspaceManagedJobStructuredResult: Codable, Equatable, Sendable {
    public static let schemaIdentifier = "com.coral.astra.workspace-managed-job-result"
    public static let schemaVersion = 1

    public var schemaIdentifier: String
    public var schemaVersion: Int
    public var jobID: String
    public var status: WorkspaceManagedJobStatus
    public var backend: String
    public var startReceipt: WorkspaceManagedJobStartReceipt?

    public init(
        jobID: String,
        status: WorkspaceManagedJobStatus,
        backend: String = WorkspaceManagedJobStartReceipt.backend,
        startReceipt: WorkspaceManagedJobStartReceipt?
    ) throws {
        self.schemaIdentifier = Self.schemaIdentifier
        self.schemaVersion = Self.schemaVersion
        self.jobID = jobID
        self.status = status
        self.backend = backend
        self.startReceipt = startReceipt
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaIdentifier
        case schemaVersion
        case jobID
        case status
        case backend
        case startReceipt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownManagedJobKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaIdentifier = try container.decode(String.self, forKey: .schemaIdentifier)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        jobID = try container.decode(String.self, forKey: .jobID)
        status = try container.decode(WorkspaceManagedJobStatus.self, forKey: .status)
        backend = try container.decode(String.self, forKey: .backend)
        startReceipt = try container.decodeIfPresent(
            WorkspaceManagedJobStartReceipt.self,
            forKey: .startReceipt
        )
        try validate()
    }

    public func validate() throws {
        guard schemaIdentifier == Self.schemaIdentifier,
              schemaVersion == Self.schemaVersion,
              backend == WorkspaceManagedJobStartReceipt.backend else {
            throw WorkspaceManagedJobContractError.invalidSchema
        }
        guard !jobID.isEmpty, jobID.count <= 80,
              jobID.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (65...90).contains(value)
                      || (97...122).contains(value)
                      || (48...57).contains(value)
                      || value == 45
                      || value == 95
              }) else {
            throw WorkspaceManagedJobContractError.invalidJobID
        }
        if status == .queued || status == .running || status == .succeeded {
            guard let startReceipt else {
                throw WorkspaceManagedJobContractError.missingStartReceipt
            }
            try startReceipt.validate(jobID: jobID)
        } else if let startReceipt {
            try startReceipt.validate(jobID: jobID)
        }
    }
}

/// Authoritative Docker-backend record stored inside the trusted task job
/// directory. This is not task control-plane state: callers must project only
/// `WorkspaceManagedJobStructuredResult` across event and prompt boundaries.
public struct WorkspaceManagedJobRecord: Codable, Equatable, Sendable {
    public var jobID: String
    public var command: String
    public var label: String?
    public var progressProbe: String?
    public var runtime: String
    public var status: WorkspaceManagedJobStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var updatedAt: Date
    public var completedAt: Date?
    public var lastHeartbeatAt: Date?
    public var lastOutputAt: Date?
    public var timeoutSeconds: TimeInterval?
    public var exitCode: Int32?
    public var stdoutLogPath: String
    public var stderrLogPath: String
    public var heartbeatPath: String
    public var resultPath: String
    public var message: String?
    public var startReceipt: WorkspaceManagedJobStartReceipt?

    public init(
        jobID: String,
        command: String,
        label: String? = nil,
        progressProbe: String? = nil,
        runtime: String,
        status: WorkspaceManagedJobStatus,
        createdAt: Date,
        startedAt: Date? = nil,
        updatedAt: Date,
        completedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        lastOutputAt: Date? = nil,
        timeoutSeconds: TimeInterval? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String,
        stderrLogPath: String,
        heartbeatPath: String,
        resultPath: String,
        message: String? = nil,
        startReceipt: WorkspaceManagedJobStartReceipt? = nil
    ) {
        self.jobID = jobID
        self.command = command
        self.label = label
        self.progressProbe = progressProbe
        self.runtime = runtime
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastOutputAt = lastOutputAt
        self.timeoutSeconds = timeoutSeconds
        self.exitCode = exitCode
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
        self.heartbeatPath = heartbeatPath
        self.resultPath = resultPath
        self.message = message
        self.startReceipt = startReceipt
    }

    public var isTerminal: Bool { status.isTerminal }
}

private struct WorkspaceManagedJobDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownManagedJobKeys(_ decoder: Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: WorkspaceManagedJobDynamicCodingKey.self)
    let allowedKeys = Set(allowed)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowedKeys.contains($0) }
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unsupported workspace managed-job fields: \(unknown.sorted().joined(separator: ", "))"
        ))
    }
}
