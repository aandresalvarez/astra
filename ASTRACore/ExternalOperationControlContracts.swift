import Foundation

/// Stable backend kind used at the broker/control boundary. A syntactically
/// valid future kind remains representable so older clients can fail closed.
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

/// Policy-level capabilities are exact operations, not a generic cancellation
/// bit. Immediate termination never satisfies a graceful request.
public struct ExternalOperationControlCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let observe = Self(rawValue: 1 << 0)
    public static let gracefulCancellation = Self(rawValue: 1 << 1)
    public static let immediateTermination = Self(rawValue: 1 << 2)
    public static let monitoringOnly: Self = [.observe]

    public var canObserve: Bool { contains(.observe) }
    public var canGracefullyCancel: Bool { contains(.gracefulCancellation) }
    public var canImmediatelyTerminate: Bool { contains(.immediateTermination) }
    public var declaresDestructiveControl: Bool {
        canGracefullyCancel || canImmediatelyTerminate
    }
}

public enum ExternalOperationControlContractError: Error, Equatable, Sendable {
    case invalidBackendInstanceID
    case supervisorIdentityRequired
    case supervisorIdentityForbidden
    case invalidSupervisorAuthorityEpoch
}

/// Full identity authenticated by RunSupervisor discovery/control. Every field
/// participates in cancellation authorization; no display alias or PID can
/// stand in for installation, store, execution, and fenced authority.
public struct ExternalOperationSupervisorIdentity: Codable, Hashable, Sendable {
    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority

    public init(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority
    ) throws {
        guard authority.epoch.rawValue > 0 else {
            throw ExternalOperationControlContractError.invalidSupervisorAuthorityEpoch
        }
        self.installationID = installationID
        self.storeID = storeID
        self.executionID = executionID
        self.authority = authority
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case installationID
        case storeID
        case executionID
        case authorityID
        case authorityEpoch
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                installationID: RunBrokerInstallationID(
                    rawValue: try container.decode(UUID.self, forKey: .installationID)
                ),
                storeID: RunBrokerStoreID(
                    rawValue: try container.decode(UUID.self, forKey: .storeID)
                ),
                executionID: RunBrokerExecutionID(
                    rawValue: try container.decode(UUID.self, forKey: .executionID)
                ),
                authority: RunBrokerAuthority(
                    id: RunBrokerAuthorityID(
                        rawValue: try container.decode(UUID.self, forKey: .authorityID)
                    ),
                    epoch: RunBrokerAuthorityEpoch(
                        rawValue: try container.decode(UInt64.self, forKey: .authorityEpoch)
                    )
                )
            )
        } catch ExternalOperationControlContractError.invalidSupervisorAuthorityEpoch {
            throw DecodingError.dataCorruptedError(
                forKey: .authorityEpoch,
                in: container,
                debugDescription: "Supervisor authority epoch must be positive"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(installationID.rawValue, forKey: .installationID)
        try container.encode(storeID.rawValue, forKey: .storeID)
        try container.encode(executionID.rawValue, forKey: .executionID)
        try container.encode(authority.id.rawValue, forKey: .authorityID)
        try container.encode(authority.epoch.rawValue, forKey: .authorityEpoch)
    }
}

/// Backend descriptor carried by IPC and durable records. It is untrusted
/// metadata, never ownership proof. Supervisor cancellation requires the full
/// typed supervisor identity; monitoring-only backends retain an opaque ID.
public struct ExternalOperationBackendIdentity: Codable, Hashable, Sendable {
    public let kind: ExternalOperationBackendKindID
    public let instanceID: String?
    public let supervisorIdentity: ExternalOperationSupervisorIdentity?

    public init(supervisorIdentity: ExternalOperationSupervisorIdentity) {
        self.kind = .localRunSupervisor
        self.instanceID = nil
        self.supervisorIdentity = supervisorIdentity
    }

    public init(
        monitoringKind kind: ExternalOperationBackendKindID,
        instanceID: String
    ) throws {
        guard kind != .localRunSupervisor else {
            throw ExternalOperationControlContractError.supervisorIdentityRequired
        }
        guard Self.isValidInstanceID(instanceID) else {
            throw ExternalOperationControlContractError.invalidBackendInstanceID
        }
        self.kind = kind
        self.instanceID = instanceID
        self.supervisorIdentity = nil
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case instanceID
        case supervisorIdentity
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ExternalOperationBackendKindID.self, forKey: .kind)
        let instanceID = try container.decodeIfPresent(String.self, forKey: .instanceID)
        let supervisorIdentity = try container.decodeIfPresent(
            ExternalOperationSupervisorIdentity.self,
            forKey: .supervisorIdentity
        )

        if kind == .localRunSupervisor {
            guard instanceID == nil, let supervisorIdentity else {
                throw DecodingError.dataCorruptedError(
                    forKey: .supervisorIdentity,
                    in: container,
                    debugDescription: "Local supervisor requires its full typed identity and no alias"
                )
            }
            self.init(supervisorIdentity: supervisorIdentity)
        } else {
            guard supervisorIdentity == nil, let instanceID else {
                throw DecodingError.dataCorruptedError(
                    forKey: .instanceID,
                    in: container,
                    debugDescription: "Monitoring backend requires one opaque instance ID"
                )
            }
            do {
                try self.init(monitoringKind: kind, instanceID: instanceID)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .instanceID,
                    in: container,
                    debugDescription: "Backend instance ID must be canonical, bounded, and nonempty"
                )
            }
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

/// Untrusted durable/IPC declaration. Authentication evidence is deliberately
/// absent and cannot be deserialized into this value.
public struct ExternalOperationControlBinding: Codable, Hashable, Sendable {
    public static let schemaIdentifier = "com.coral.astra.external-operation-control-binding"
    public static let currentSchemaVersion = 1

    public let schemaIdentifier: String
    public let schemaVersion: Int
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let backendIdentity: ExternalOperationBackendIdentity
    public let declaredCapabilities: ExternalOperationControlCapabilities

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        backendIdentity: ExternalOperationBackendIdentity,
        declaredCapabilities: ExternalOperationControlCapabilities
    ) {
        self.schemaIdentifier = Self.schemaIdentifier
        self.schemaVersion = Self.currentSchemaVersion
        self.executionID = executionID
        self.authority = authority
        self.backendIdentity = backendIdentity
        self.declaredCapabilities = declaredCapabilities
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaIdentifier
        case schemaVersion
        case executionID
        case authorityID
        case authorityEpoch
        case backendIdentity
        case declaredCapabilitiesRawValue
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
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
        self.backendIdentity = try container.decode(
            ExternalOperationBackendIdentity.self,
            forKey: .backendIdentity
        )
        self.declaredCapabilities = ExternalOperationControlCapabilities(
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
        try container.encode(backendIdentity, forKey: .backendIdentity)
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
        case backendIdentity
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownExternalControlKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
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
        self.backendIdentity = try container.decode(
            ExternalOperationBackendIdentity.self,
            forKey: .backendIdentity
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaIdentifier, forKey: .schemaIdentifier)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(executionID.rawValue, forKey: .executionID)
        try container.encode(authority.id.rawValue, forKey: .authorityID)
        try container.encode(authority.epoch.rawValue, forKey: .authorityEpoch)
        try container.encode(backendIdentity, forKey: .backendIdentity)
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
