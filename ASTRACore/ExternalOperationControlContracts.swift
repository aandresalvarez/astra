import Foundation

// Provider-neutral wire contracts for external-operation control admission.

/// Stable backend kind used at the broker/control boundary. Known kinds are
/// constants, while a syntactically valid future kind remains representable so
/// old clients can fail closed with an explicit `unsupported_backend` reason.
public struct ExternalOperationBackendKindID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let first = rawValue.unicodeScalars.first,
              (97...122).contains(first.value),
              !rawValue.isEmpty,
              rawValue.utf8.count <= 64,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  (97...122).contains(scalar.value)
                      || (48...57).contains(scalar.value)
                      || scalar.value == 95
              }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    private init(staticRawValue: String) {
        self.rawValue = staticRawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Backend kind must be a canonical lowercase identifier"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let localRunSupervisor = Self(staticRawValue: "local_run_supervisor")
    public static let managedDockerJob = Self(staticRawValue: "managed_docker_job")
    public static let sshRemoteOperation = Self(staticRawValue: "ssh_remote_operation")
    public static let importedOperation = Self(staticRawValue: "imported_operation")
    public static let opaqueOperation = Self(staticRawValue: "opaque_operation")
}

public enum ExternalOperationControlContractError: Error, Equatable, Sendable {
    case invalidBackendInstanceID
}

/// Exact backend identity. It deliberately contains no process identifier:
/// reusable PIDs are diagnostics, never execution authority.
public struct ExternalOperationBackendIdentity: Codable, Hashable, Sendable {
    public let kind: ExternalOperationBackendKindID
    public let instanceID: String

    public init(
        kind: ExternalOperationBackendKindID,
        instanceID: String
    ) throws {
        guard Self.isValidInstanceID(instanceID) else {
            throw ExternalOperationControlContractError.invalidBackendInstanceID
        }
        self.kind = kind
        self.instanceID = instanceID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case instanceID
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ExternalOperationBackendKindID.self, forKey: .kind)
        let instanceID = try container.decode(String.self, forKey: .instanceID)
        do {
            try self.init(kind: kind, instanceID: instanceID)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .instanceID,
                in: container,
                debugDescription: "Backend instance ID must be canonical, bounded, and nonempty"
            )
        }
    }

    private static func isValidInstanceID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}

/// Evidence about how ASTRA obtained a backend handle. This is assigned only
/// after the owning adapter authenticates its execution-scoped capability; it
/// is not inferred from a PID, peer UID, backend name, or imported metadata.
public enum ExternalOperationControlOwnership: String, Codable, Hashable, Sendable {
    case authenticatedExecutionScoped = "authenticated_execution_scoped"
    case imported
    case opaque
}

/// Durable binding produced by a trusted backend adapter. The wire shape is
/// versioned and strict because it crosses app/broker/service boundaries.
public struct ExternalOperationControlBinding: Codable, Hashable, Sendable {
    public static let schemaIdentifier = "com.coral.astra.external-operation-control-binding"
    public static let currentSchemaVersion = 1

    public let schemaIdentifier: String
    public let schemaVersion: Int
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let backendIdentity: ExternalOperationBackendIdentity
    public let ownership: ExternalOperationControlOwnership
    public let declaredCapabilities: ExternalOperationBackendCapabilities

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        backendIdentity: ExternalOperationBackendIdentity,
        ownership: ExternalOperationControlOwnership,
        declaredCapabilities: ExternalOperationBackendCapabilities
    ) {
        self.schemaIdentifier = Self.schemaIdentifier
        self.schemaVersion = Self.currentSchemaVersion
        self.executionID = executionID
        self.authority = authority
        self.backendIdentity = backendIdentity
        self.ownership = ownership
        self.declaredCapabilities = declaredCapabilities
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaIdentifier
        case schemaVersion
        case executionID
        case authorityID
        case authorityEpoch
        case backendKind
        case backendInstanceID
        case ownership
        case declaredCapabilitiesRawValue
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaIdentifier = try container.decode(String.self, forKey: .schemaIdentifier)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try validateExternalControlSchema(
            identifier: schemaIdentifier,
            expectedIdentifier: Self.schemaIdentifier,
            version: schemaVersion,
            expectedVersion: Self.currentSchemaVersion,
            codingPath: decoder.codingPath
        )
        self.schemaIdentifier = schemaIdentifier
        self.schemaVersion = schemaVersion
        self.executionID = RunBrokerExecutionID(
            rawValue: try container.decode(UUID.self, forKey: .executionID)
        )
        self.authority = RunBrokerAuthority(
            id: RunBrokerAuthorityID(
                rawValue: try container.decode(UUID.self, forKey: .authorityID)
            ),
            epoch: RunBrokerAuthorityEpoch(
                rawValue: try container.decode(UInt64.self, forKey: .authorityEpoch)
            )
        )
        let backendKind = try container.decode(
            ExternalOperationBackendKindID.self,
            forKey: .backendKind
        )
        let backendInstanceID = try container.decode(String.self, forKey: .backendInstanceID)
        do {
            self.backendIdentity = try ExternalOperationBackendIdentity(
                kind: backendKind,
                instanceID: backendInstanceID
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .backendInstanceID,
                in: container,
                debugDescription: "Backend instance ID must be canonical, bounded, and nonempty"
            )
        }
        self.ownership = try container.decode(
            ExternalOperationControlOwnership.self,
            forKey: .ownership
        )
        self.declaredCapabilities = ExternalOperationBackendCapabilities(
            rawValue: try container.decode(UInt8.self, forKey: .declaredCapabilitiesRawValue)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaIdentifier, forKey: .schemaIdentifier)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(executionID.rawValue, forKey: .executionID)
        try container.encode(authority.id.rawValue, forKey: .authorityID)
        try container.encode(authority.epoch.rawValue, forKey: .authorityEpoch)
        try container.encode(backendIdentity.kind, forKey: .backendKind)
        try container.encode(backendIdentity.instanceID, forKey: .backendInstanceID)
        try container.encode(ownership, forKey: .ownership)
        try container.encode(
            declaredCapabilities.rawValue,
            forKey: .declaredCapabilitiesRawValue
        )
    }
}

/// Exact target the caller intends to observe or cancel. The policy never
/// searches for a nearby execution/backend and never falls back to a PID.
public struct ExternalOperationControlTarget: Codable, Hashable, Sendable {
    public static let schemaIdentifier = "com.coral.astra.external-operation-control-target"
    public static let currentSchemaVersion = 1

    public let schemaIdentifier: String
    public let schemaVersion: Int
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let backendIdentity: ExternalOperationBackendIdentity

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        backendIdentity: ExternalOperationBackendIdentity
    ) {
        self.schemaIdentifier = Self.schemaIdentifier
        self.schemaVersion = Self.currentSchemaVersion
        self.executionID = executionID
        self.authority = authority
        self.backendIdentity = backendIdentity
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaIdentifier
        case schemaVersion
        case executionID
        case authorityID
        case authorityEpoch
        case backendKind
        case backendInstanceID
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaIdentifier = try container.decode(String.self, forKey: .schemaIdentifier)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try validateExternalControlSchema(
            identifier: schemaIdentifier,
            expectedIdentifier: Self.schemaIdentifier,
            version: schemaVersion,
            expectedVersion: Self.currentSchemaVersion,
            codingPath: decoder.codingPath
        )
        self.schemaIdentifier = schemaIdentifier
        self.schemaVersion = schemaVersion
        self.executionID = RunBrokerExecutionID(
            rawValue: try container.decode(UUID.self, forKey: .executionID)
        )
        self.authority = RunBrokerAuthority(
            id: RunBrokerAuthorityID(
                rawValue: try container.decode(UUID.self, forKey: .authorityID)
            ),
            epoch: RunBrokerAuthorityEpoch(
                rawValue: try container.decode(UInt64.self, forKey: .authorityEpoch)
            )
        )
        let backendKind = try container.decode(
            ExternalOperationBackendKindID.self,
            forKey: .backendKind
        )
        let backendInstanceID = try container.decode(String.self, forKey: .backendInstanceID)
        do {
            self.backendIdentity = try ExternalOperationBackendIdentity(
                kind: backendKind,
                instanceID: backendInstanceID
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .backendInstanceID,
                in: container,
                debugDescription: "Backend instance ID must be canonical, bounded, and nonempty"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaIdentifier, forKey: .schemaIdentifier)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(executionID.rawValue, forKey: .executionID)
        try container.encode(authority.id.rawValue, forKey: .authorityID)
        try container.encode(authority.epoch.rawValue, forKey: .authorityEpoch)
        try container.encode(backendIdentity.kind, forKey: .backendKind)
        try container.encode(backendIdentity.instanceID, forKey: .backendInstanceID)
    }
}

public enum ExternalOperationControlDecisionKind: String, Codable, Equatable, Sendable {
    case allowed
    case monitoringOnly = "monitoring_only"
    case blocked
}

public enum ExternalOperationControlDecisionReason: String, Codable, Equatable, Sendable {
    case observationCapabilityVerified = "observation_capability_verified"
    case authenticatedCancellationHandleVerified = "authenticated_cancellation_handle_verified"
    case sshRequiresReviewedRemoteHelper = "ssh_requires_reviewed_remote_helper"
    case importedOperationIsMonitoringOnly = "imported_operation_is_monitoring_only"
    case opaqueOperationIsMonitoringOnly = "opaque_operation_is_monitoring_only"
    case staleExecution = "stale_execution"
    case staleAuthority = "stale_authority"
    case staleBackendIdentity = "stale_backend_identity"
    case unsupportedCapabilityDeclaration = "unsupported_capability_declaration"
    case observationCapabilityMissing = "observation_capability_missing"
    case cancellationCapabilityMissing = "cancellation_capability_missing"
    case authenticatedOwnershipMissing = "authenticated_ownership_missing"
    case cancellationCapabilityOverclaim = "cancellation_capability_overclaim"
    case unsupportedBackend = "unsupported_backend"
}

public struct ExternalOperationControlDecision: Codable, Equatable, Sendable {
    public let kind: ExternalOperationControlDecisionKind
    public let reason: ExternalOperationControlDecisionReason

    public init(
        kind: ExternalOperationControlDecisionKind,
        reason: ExternalOperationControlDecisionReason
    ) {
        self.kind = kind
        self.reason = reason
    }
}

/// Observation and cancellation are evaluated separately. A backend may be
/// observable without being cancellable, or cancellable without exposing an
/// observation API. Neither capability is inferred from the other.
public struct ExternalOperationControlAssessment: Codable, Equatable, Sendable {
    public let observation: ExternalOperationControlDecision
    public let cancellation: ExternalOperationControlDecision

    public init(
        observation: ExternalOperationControlDecision,
        cancellation: ExternalOperationControlDecision
    ) {
        self.observation = observation
        self.cancellation = cancellation
    }
}

private struct ExternalOperationControlDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownExternalControlKeys(
    _ decoder: Decoder,
    allowed: [String]
) throws {
    let container = try decoder.container(keyedBy: ExternalOperationControlDynamicCodingKey.self)
    let allowedKeys = Set(allowed)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowedKeys.contains($0) }
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unsupported external-operation control fields: \(unknown.sorted().joined(separator: ", "))"
        ))
    }
}

private func validateExternalControlSchema(
    identifier: String,
    expectedIdentifier: String,
    version: Int,
    expectedVersion: Int,
    codingPath: [CodingKey]
) throws {
    guard identifier == expectedIdentifier, version == expectedVersion else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "Unsupported external-operation control schema"
        ))
    }
}
