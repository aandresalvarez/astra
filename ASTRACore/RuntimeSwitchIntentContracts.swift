import Foundation

public enum RuntimeSwitchContractError: Error, Equatable, Sendable {
    case emptyValue(String)
    case oversizedValue(String, limit: Int)
    case invalidTimestamp(String)
    case invalidMode
    case invalidTargetManifest
    case emptyForceReasonCode
}

public struct RuntimeSwitchRequestID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct RuntimeSwitchRequestDigest: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public let value: ExecutionLaunchArgumentsSHA256

    public init(value: ExecutionLaunchArgumentsSHA256) { self.value = value }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, value }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch request digest"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch request digest"
        )
        self.init(value: try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(value, forKey: .value)
    }
}

public struct RuntimeSwitchSourceFence: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let executionID: RunBrokerExecutionID
    public let taskID: UUID
    public let authority: RunBrokerAuthority
    public let manifestSHA256: ExecutionLaunchArgumentsSHA256
    public let configurationRevision: String

    public init(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        executionID: RunBrokerExecutionID,
        taskID: UUID,
        authority: RunBrokerAuthority,
        manifestSHA256: ExecutionLaunchArgumentsSHA256,
        configurationRevision: String
    ) throws {
        self.installationID = installationID
        self.storeID = storeID
        self.executionID = executionID
        self.taskID = taskID
        self.authority = authority
        self.manifestSHA256 = manifestSHA256
        self.configurationRevision = try RuntimeSwitchBounds.canonical(
            configurationRevision,
            field: "source configuration revision",
            limit: 256
        )
    }

    public init(manifest: ExecutionLaunchManifest, manifestSHA256: ExecutionLaunchArgumentsSHA256) throws {
        try self.init(
            installationID: manifest.installationID,
            storeID: manifest.storeID,
            executionID: manifest.executionID,
            taskID: manifest.taskID,
            authority: manifest.authority,
            manifestSHA256: manifestSHA256,
            configurationRevision: manifest.configuration.configurationRevision
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case installationID
        case storeID
        case executionID
        case taskID
        case authority
        case manifestSHA256
        case configurationRevision
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch source fence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch source fence"
        )
        try self.init(
            installationID: container.decode(RunBrokerInstallationID.self, forKey: .installationID),
            storeID: container.decode(RunBrokerStoreID.self, forKey: .storeID),
            executionID: container.decode(RunBrokerExecutionID.self, forKey: .executionID),
            taskID: container.decode(UUID.self, forKey: .taskID),
            authority: container.decode(RunBrokerAuthority.self, forKey: .authority),
            manifestSHA256: container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .manifestSHA256),
            configurationRevision: container.decode(String.self, forKey: .configurationRevision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(installationID, forKey: .installationID)
        try container.encode(storeID, forKey: .storeID)
        try container.encode(executionID, forKey: .executionID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(authority, forKey: .authority)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(configurationRevision, forKey: .configurationRevision)
    }
}

/// A fully resolved, immutable replacement launch. The broker verifies the
/// digest before admitting the request; a runtime preference alone is never a
/// launch authority and there is no fallback provider.
public struct RuntimeSwitchResolvedTarget: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let manifest: ExecutionLaunchManifest
    public let manifestSHA256: ExecutionLaunchArgumentsSHA256

    public init(
        manifest: ExecutionLaunchManifest,
        manifestSHA256: ExecutionLaunchArgumentsSHA256
    ) throws {
        try Self.validate(manifest)
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case manifest
        case manifestSHA256
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch resolved target"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch resolved target"
        )
        try Self.validateManifestShape(from: container.superDecoder(forKey: .manifest))
        try self.init(
            manifest: container.decode(ExecutionLaunchManifest.self, forKey: .manifest),
            manifestSHA256: container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .manifestSHA256)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
    }

    private static func validate(_ manifest: ExecutionLaunchManifest) throws {
        let configuration = manifest.configuration
        guard configuration.runtimeID.rawValue.utf8.count <= 128,
              (configuration.modelID?.utf8.count ?? 0) <= 256,
              configuration.executablePath.utf8.count <= 4_096,
              configuration.workingDirectory.utf8.count <= 4_096,
              configuration.configurationRevision.utf8.count <= 256,
              !configuration.configurationRevision.isEmpty,
              configuration.environmentVariableNames.count <= 256,
              configuration.environmentVariableNames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              manifest.declaredEffects.count <= 1_024,
              manifest.declaredEffects.allSatisfy({ validScope($0.scope) }),
              manifest.createdAt.timeIntervalSince1970.isFinite else {
            throw RuntimeSwitchContractError.invalidTargetManifest
        }
        let canonicalConfiguration = ExecutionLaunchConfigurationSnapshot(
            runtimeID: configuration.runtimeID,
            modelID: configuration.modelID,
            executablePath: configuration.executablePath,
            launchArguments: configuration.launchArguments,
            workingDirectory: configuration.workingDirectory,
            environmentVariableNames: configuration.environmentVariableNames,
            configurationRevision: configuration.configurationRevision
        )
        let canonicalManifest = ExecutionLaunchManifest(
            installationID: manifest.installationID,
            storeID: manifest.storeID,
            executionID: manifest.executionID,
            taskID: manifest.taskID,
            authority: manifest.authority,
            configuration: canonicalConfiguration,
            declaredEffects: manifest.declaredEffects,
            createdAt: manifest.createdAt
        )
        guard canonicalManifest == manifest,
              let encoded = try? JSONEncoder().encode(canonicalManifest),
              encoded.count <= 1_048_576 else {
            throw RuntimeSwitchContractError.invalidTargetManifest
        }
    }

    private static func validScope(_ scope: ExecutionEffectScope) -> Bool {
        switch scope {
        case .workspaceRepository(let workspaceID, let repositoryID):
            return validIdentifier(workspaceID)
                && (repositoryID.map(validIdentifier) ?? true)
                && scope.isKnownAndWellFormed
        case .remotePath(let hostID, let path):
            return validIdentifier(hostID)
                && path.utf8.count <= 4_096
                && scope.isKnownAndWellFormed
        case .datasetDatabase(let dataSourceID, let databaseID, let datasetID):
            return validIdentifier(dataSourceID)
                && validIdentifier(databaseID)
                && (datasetID.map(validIdentifier) ?? true)
                && scope.isKnownAndWellFormed
        case .cloudResource(let providerID, let resourceID):
            return validIdentifier(providerID)
                && validIdentifier(resourceID)
                && scope.isKnownAndWellFormed
        case .computeOnly:
            return true
        case .unknown:
            return false
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && !value.isEmpty
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validateManifestShape(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(ManifestCodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch target manifest"
        )
        let manifest = try decoder.container(keyedBy: ManifestCodingKeys.self)
        try validateAuthorityShape(from: manifest.superDecoder(forKey: .authority))
        try validateConfigurationShape(from: manifest.superDecoder(forKey: .configuration))
        var effects = try manifest.nestedUnkeyedContainer(forKey: .declaredEffects)
        while !effects.isAtEnd {
            try validateEffectShape(from: effects.superDecoder())
        }
    }

    private static func validateAuthorityShape(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(AuthorityCodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch target authority"
        )
    }

    private static func validateConfigurationShape(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(ConfigurationCodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch target configuration"
        )
        let configuration = try decoder.container(keyedBy: ConfigurationCodingKeys.self)
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: configuration.superDecoder(forKey: .launchArguments),
            allowed: Set(LaunchArgumentCodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch target launch argument summary"
        )
    }

    private static func validateEffectShape(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(EffectCodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch target effect claim"
        )
        let effect = try decoder.container(keyedBy: EffectCodingKeys.self)
        try validateScopeShape(from: effect.superDecoder(forKey: .scope))
    }

    private static func validateScopeShape(from decoder: Decoder) throws {
        let allowed = Set(ScopeKind.allCases.map(\.rawValue))
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: allowed,
            typeName: "runtime switch target effect scope"
        )
        let container = try decoder.container(keyedBy: RuntimeSwitchDynamicCodingKey.self)
        guard container.allKeys.count == 1,
              let key = container.allKeys.first,
              let kind = ScopeKind(rawValue: key.stringValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Runtime switch target effect scope must contain exactly one known variant"
            ))
        }
        let payload = try container.superDecoder(forKey: key)
        let payloadKeys: Set<String>
        switch kind {
        case .workspaceRepository:
            payloadKeys = ["workspaceID", "repositoryID"]
        case .remotePath:
            payloadKeys = ["hostID", "path"]
        case .datasetDatabase:
            payloadKeys = ["dataSourceID", "databaseID", "datasetID"]
        case .cloudResource:
            payloadKeys = ["providerID", "resourceID"]
        case .computeOnly, .unknown:
            payloadKeys = []
        }
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: payload,
            allowed: payloadKeys,
            typeName: "runtime switch target effect scope payload"
        )
    }

    private enum ManifestCodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, installationID, storeID, executionID, taskID
        case authority, configuration, declaredEffects, createdAt
    }

    private enum AuthorityCodingKeys: String, CodingKey, CaseIterable { case id, epoch }

    private enum ConfigurationCodingKeys: String, CodingKey, CaseIterable {
        case runtimeID, modelID, executablePath, launchArguments, workingDirectory
        case environmentVariableNames, configurationRevision
    }

    private enum LaunchArgumentCodingKeys: String, CodingKey, CaseIterable {
        case argumentCount, argumentsSHA256
    }

    private enum EffectCodingKeys: String, CodingKey, CaseIterable { case scope, access }

    private enum ScopeKind: String, CaseIterable {
        case workspaceRepository, remotePath, datasetDatabase, cloudResource, computeOnly, unknown
    }
}

public enum RuntimeSwitchMode: String, Codable, Equatable, Hashable, Sendable {
    case graceful
    case immediate

    public var cancellationIntent: ExecutionCancellationIntent {
        switch self {
        case .graceful: .graceful
        case .immediate: .immediate
        }
    }
}

/// Strict client command. It contains expectations, never observations. The
/// broker compares every field against its canonical ledger and supervisor
/// evidence before recording any durable effect.
public struct RuntimeSwitchIntent: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let requestID: RuntimeSwitchRequestID
    public let mode: RuntimeSwitchMode
    public let expectedSource: RuntimeSwitchSourceFence
    public let target: RuntimeSwitchResolvedTarget
    public let requestedAt: Date

    public init(
        requestID: RuntimeSwitchRequestID,
        mode: RuntimeSwitchMode,
        expectedSource: RuntimeSwitchSourceFence,
        target: RuntimeSwitchResolvedTarget,
        requestedAt: Date
    ) throws {
        guard requestedAt.timeIntervalSince1970.isFinite else {
            throw RuntimeSwitchContractError.invalidTimestamp("requestedAt")
        }
        self.requestID = requestID
        self.mode = mode
        self.expectedSource = expectedSource
        self.target = target
        self.requestedAt = requestedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case requestID
        case mode
        case expectedSource
        case target
        case requestedAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch intent"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch intent"
        )
        try self.init(
            requestID: container.decode(RuntimeSwitchRequestID.self, forKey: .requestID),
            mode: container.decode(RuntimeSwitchMode.self, forKey: .mode),
            expectedSource: container.decode(RuntimeSwitchSourceFence.self, forKey: .expectedSource),
            target: container.decode(RuntimeSwitchResolvedTarget.self, forKey: .target),
            requestedAt: container.decode(Date.self, forKey: .requestedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(mode, forKey: .mode)
        try container.encode(expectedSource, forKey: .expectedSource)
        try container.encode(target, forKey: .target)
        try container.encode(requestedAt, forKey: .requestedAt)
    }
}

public struct GracefulRuntimeHandoffRequest: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public let intent: RuntimeSwitchIntent

    public init(intent: RuntimeSwitchIntent) throws {
        guard intent.mode == .graceful else { throw RuntimeSwitchContractError.invalidMode }
        self.intent = intent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, intent }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "graceful runtime handoff request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "graceful runtime handoff request"
        )
        try self.init(intent: container.decode(RuntimeSwitchIntent.self, forKey: .intent))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(intent, forKey: .intent)
    }
}

public enum ActiveRuntimeSwitchRequest: Codable, Equatable, Hashable, Sendable {
    case gracefulHandoff(GracefulRuntimeHandoffRequest)
    case forceTermination(ForceRuntimeSwitchRequest)

    public static func defaultHandoff(intent: RuntimeSwitchIntent) throws -> Self {
        .gracefulHandoff(try .init(intent: intent))
    }

    public var intent: RuntimeSwitchIntent {
        switch self {
        case .gracefulHandoff(let request): request.intent
        case .forceTermination(let request): request.intent
        }
    }

    private enum Kind: String, Codable { case gracefulHandoff = "graceful_handoff", forceTermination = "force_termination" }
    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, kind, gracefulHandoff, forceTermination }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "active runtime switch request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            1,
            in: container,
            key: .schemaVersion,
            typeName: "active runtime switch request"
        )
        switch try container.decode(Kind.self, forKey: .kind) {
        case .gracefulHandoff:
            guard !container.contains(.forceTermination) else { throw Self.invalidVariant(in: container) }
            self = .gracefulHandoff(try container.decode(GracefulRuntimeHandoffRequest.self, forKey: .gracefulHandoff))
        case .forceTermination:
            guard !container.contains(.gracefulHandoff) else { throw Self.invalidVariant(in: container) }
            self = .forceTermination(try container.decode(ForceRuntimeSwitchRequest.self, forKey: .forceTermination))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        switch self {
        case .gracefulHandoff(let request):
            try container.encode(Kind.gracefulHandoff, forKey: .kind)
            try container.encode(request, forKey: .gracefulHandoff)
        case .forceTermination(let request):
            try container.encode(Kind.forceTermination, forKey: .kind)
            try container.encode(request, forKey: .forceTermination)
        }
    }

    private static func invalidVariant(in container: KeyedDecodingContainer<CodingKeys>) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: container.codingPath,
            debugDescription: "Runtime switch request must contain exactly one payload matching kind"
        ))
    }
}

enum RuntimeSwitchBounds {
    static func canonical(_ value: String, field: String, limit: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RuntimeSwitchContractError.emptyValue(field) }
        guard normalized.utf8.count <= limit else {
            throw RuntimeSwitchContractError.oversizedValue(field, limit: limit)
        }
        return normalized
    }
}
