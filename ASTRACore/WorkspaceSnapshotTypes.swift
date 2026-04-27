import Foundation

public struct ConnectorSnapshotConfig: Codable, Equatable {
    public var id: String?
    public var name: String
    public var serviceType: String
    public var icon: String
    public var description: String
    public var baseURL: String
    public var authMethod: String
    public var credentialKeys: [String]
    public var configKeys: [String]
    public var configValues: [String]
    public var isGlobal: Bool?
    public var notes: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String?,
        name: String,
        serviceType: String,
        icon: String,
        description: String,
        baseURL: String,
        authMethod: String,
        credentialKeys: [String],
        configKeys: [String],
        configValues: [String],
        isGlobal: Bool?,
        notes: String,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.serviceType = serviceType
        self.icon = icon
        self.description = description
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.credentialKeys = credentialKeys
        self.configKeys = configKeys
        self.configValues = configValues
        self.isGlobal = isGlobal
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LocalToolSnapshotConfig: Codable, Equatable {
    public var id: String?
    public var name: String
    public var description: String
    public var icon: String
    public var toolType: String
    public var command: String
    public var arguments: String
    public var isGlobal: Bool?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String?,
        name: String,
        description: String,
        icon: String,
        toolType: String,
        command: String,
        arguments: String,
        isGlobal: Bool?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.toolType = toolType
        self.command = command
        self.arguments = arguments
        self.isGlobal = isGlobal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SkillSnapshotConfig: Codable, Equatable {
    public var id: String?
    public var name: String
    public var icon: String
    public var description: String
    public var allowedTools: [String]
    public var disallowedTools: [String]
    public var customTools: [String]
    public var behaviorInstructions: String
    public var environmentKeys: [String]
    public var environmentValues: [String]
    public var isGlobal: Bool?
    public var connectorIDs: [String]?
    public var localToolIDs: [String]?
    public var connectorSnapshots: [ConnectorSnapshotConfig]?
    public var localToolSnapshots: [LocalToolSnapshotConfig]?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String?,
        name: String,
        icon: String,
        description: String,
        allowedTools: [String],
        disallowedTools: [String],
        customTools: [String],
        behaviorInstructions: String,
        environmentKeys: [String],
        environmentValues: [String],
        isGlobal: Bool?,
        connectorIDs: [String]?,
        localToolIDs: [String]?,
        connectorSnapshots: [ConnectorSnapshotConfig]?,
        localToolSnapshots: [LocalToolSnapshotConfig]?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.customTools = customTools
        self.behaviorInstructions = behaviorInstructions
        self.environmentKeys = environmentKeys
        self.environmentValues = environmentValues
        self.isGlobal = isGlobal
        self.connectorIDs = connectorIDs
        self.localToolIDs = localToolIDs
        self.connectorSnapshots = connectorSnapshots
        self.localToolSnapshots = localToolSnapshots
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ArtifactConfig: Codable, Equatable {
    public var id: String?
    public var type: String
    public var path: String
    public var content: String?
    public var version: Int
    public var createdAt: Date

    public init(
        id: String?,
        type: String,
        path: String,
        content: String?,
        version: Int,
        createdAt: Date
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.content = content
        self.version = version
        self.createdAt = createdAt
    }
}
