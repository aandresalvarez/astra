import Foundation

public enum ExecutionLaunchContractError: Error, Equatable, Sendable {
    case invalidArgumentsSHA256Digest
    case redactedArgumentCountMustBePositive
}

/// A one-way fingerprint of the exact ephemeral argv payload. Raw arguments
/// belong only in supervisor IPC and must never enter durable launch records.
public struct ExecutionLaunchArgumentsSHA256: Codable, Equatable, Hashable, Sendable {
    public let hexValue: String

    public init(hexValue: String) throws {
        let normalized = hexValue.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ExecutionLaunchContractError.invalidArgumentsSHA256Digest
        }
        self.hexValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(hexValue: encoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Launch argument digest must be 64 hexadecimal SHA-256 characters"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexValue)
    }
}

/// Durable metadata about ephemeral launch arguments. This shape can express
/// that arguments existed and verify their identity without storing values.
public struct ExecutionLaunchArgumentSummary: Codable, Equatable, Hashable, Sendable {
    public static let none = ExecutionLaunchArgumentSummary(
        argumentCount: 0,
        argumentsSHA256: nil
    )

    public let argumentCount: UInt
    public let argumentsSHA256: ExecutionLaunchArgumentsSHA256?

    public init(
        redactedArgumentCount argumentCount: UInt,
        argumentsSHA256: ExecutionLaunchArgumentsSHA256
    ) throws {
        guard argumentCount > 0 else {
            throw ExecutionLaunchContractError.redactedArgumentCountMustBePositive
        }
        self.argumentCount = argumentCount
        self.argumentsSHA256 = argumentsSHA256
    }

    private init(
        argumentCount: UInt,
        argumentsSHA256: ExecutionLaunchArgumentsSHA256?
    ) {
        self.argumentCount = argumentCount
        self.argumentsSHA256 = argumentsSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case argumentCount
        case argumentsSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count = try container.decode(UInt.self, forKey: .argumentCount)
        let digest = try container.decodeIfPresent(
            ExecutionLaunchArgumentsSHA256.self,
            forKey: .argumentsSHA256
        )
        switch (count, digest) {
        case (0, nil):
            self = .none
        case (let count, let digest?) where count > 0:
            try self.init(redactedArgumentCount: count, argumentsSHA256: digest)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .argumentCount,
                in: container,
                debugDescription: "A nonzero argument count requires a digest; zero arguments must not carry one"
            )
        }
    }
}

/// Secret-free, resolved configuration captured at the execution boundary.
/// Runtime preference changes create a future configuration; they never mutate
/// the snapshot held by an already-active execution.
public struct ExecutionLaunchConfigurationSnapshot: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: AgentRuntimeID
    public let modelID: String?
    public let executablePath: String
    public let launchArguments: ExecutionLaunchArgumentSummary
    public let workingDirectory: String
    public let environmentVariableNames: [String]
    public let configurationRevision: String

    public init(
        runtimeID: AgentRuntimeID,
        modelID: String? = nil,
        executablePath: String,
        launchArguments: ExecutionLaunchArgumentSummary = .none,
        workingDirectory: String,
        environmentVariableNames: [String] = [],
        configurationRevision: String
    ) {
        self.runtimeID = runtimeID
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.executablePath = executablePath
        self.launchArguments = launchArguments
        self.workingDirectory = workingDirectory
        self.environmentVariableNames = Array(Set(environmentVariableNames)).sorted()
        self.configurationRevision = configurationRevision
    }
}

/// Immutable launch truth for one execution attempt. The manifest contains
/// references and declarations only; resolved secret values do not belong in a
/// durable manifest.
public struct ExecutionLaunchManifest: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let executionID: RunBrokerExecutionID
    public let taskID: UUID
    public let authority: RunBrokerAuthority
    public let configuration: ExecutionLaunchConfigurationSnapshot
    public let declaredEffects: [ExecutionEffectClaim]
    public let createdAt: Date

    public init(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        executionID: RunBrokerExecutionID,
        taskID: UUID,
        authority: RunBrokerAuthority,
        configuration: ExecutionLaunchConfigurationSnapshot,
        declaredEffects: [ExecutionEffectClaim],
        createdAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.installationID = installationID
        self.storeID = storeID
        self.executionID = executionID
        self.taskID = taskID
        self.authority = authority
        self.configuration = configuration
        self.declaredEffects = declaredEffects
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case installationID
        case storeID
        case executionID
        case taskID
        case authority
        case configuration
        case declaredEffects
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported execution launch manifest schema version: \(schemaVersion)"
            )
        }
        self.schemaVersion = schemaVersion
        self.installationID = try container.decode(RunBrokerInstallationID.self, forKey: .installationID)
        self.storeID = try container.decode(RunBrokerStoreID.self, forKey: .storeID)
        self.executionID = try container.decode(RunBrokerExecutionID.self, forKey: .executionID)
        self.taskID = try container.decode(UUID.self, forKey: .taskID)
        self.authority = try container.decode(RunBrokerAuthority.self, forKey: .authority)
        self.configuration = try container.decode(
            ExecutionLaunchConfigurationSnapshot.self,
            forKey: .configuration
        )
        self.declaredEffects = try container.decode([ExecutionEffectClaim].self, forKey: .declaredEffects)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Runtime actually owned by an active immutable manifest.
public struct ActiveExecutionRuntime: Codable, Equatable, Hashable, Sendable {
    public let executionID: RunBrokerExecutionID
    public let runtimeID: AgentRuntimeID

    public init(executionID: RunBrokerExecutionID, runtimeID: AgentRuntimeID) {
        self.executionID = executionID
        self.runtimeID = runtimeID
    }

    public init(manifest: ExecutionLaunchManifest) {
        self.init(
            executionID: manifest.executionID,
            runtimeID: manifest.configuration.runtimeID
        )
    }
}

/// Separates immutable active-runtime truth from the user's preference for the
/// next execution. This state belongs to one logical task/thread: its singular
/// `active` does not prohibit non-overlapping executions in other threads.
/// Selecting a runtime never rewrites `active`.
public struct ExecutionRuntimeIntentState: Codable, Equatable, Hashable, Sendable {
    public let active: ActiveExecutionRuntime?
    public let nextRuntimeID: AgentRuntimeID

    public init(active: ActiveExecutionRuntime? = nil, nextRuntimeID: AgentRuntimeID) {
        self.active = active
        self.nextRuntimeID = nextRuntimeID
    }
}

public enum ExecutionRuntimeIntentEvent: Equatable, Sendable {
    case selectNextRuntime(AgentRuntimeID)
    case executionStarted(ActiveExecutionRuntime)
    case executionFinished(RunBrokerExecutionID)
}

public enum ExecutionRuntimeIntentDisposition: String, Codable, Equatable, Sendable {
    case applied
    case idempotent
    case rejectedActiveExecution = "rejected_active_execution"
    case staleExecutionIgnored = "stale_execution_ignored"
}

public struct ExecutionRuntimeIntentReduction: Equatable, Sendable {
    public let state: ExecutionRuntimeIntentState
    public let disposition: ExecutionRuntimeIntentDisposition

    public init(state: ExecutionRuntimeIntentState, disposition: ExecutionRuntimeIntentDisposition) {
        self.state = state
        self.disposition = disposition
    }
}

/// Pure reducer for runtime picker intent and active execution observations.
public enum ExecutionRuntimeIntentReducer {
    public static func reduce(
        _ state: ExecutionRuntimeIntentState,
        event: ExecutionRuntimeIntentEvent
    ) -> ExecutionRuntimeIntentReduction {
        switch event {
        case .selectNextRuntime(let runtimeID):
            guard runtimeID != state.nextRuntimeID else {
                return .init(state: state, disposition: .idempotent)
            }
            return .init(
                state: .init(active: state.active, nextRuntimeID: runtimeID),
                disposition: .applied
            )

        case .executionStarted(let assignment):
            guard let active = state.active else {
                return .init(
                    state: .init(active: assignment, nextRuntimeID: state.nextRuntimeID),
                    disposition: .applied
                )
            }
            return .init(
                state: state,
                disposition: active == assignment ? .idempotent : .rejectedActiveExecution
            )

        case .executionFinished(let executionID):
            guard let active = state.active, active.executionID == executionID else {
                return .init(state: state, disposition: .staleExecutionIgnored)
            }
            return .init(
                state: .init(active: nil, nextRuntimeID: state.nextRuntimeID),
                disposition: .applied
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
