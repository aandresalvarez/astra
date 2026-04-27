import Foundation
import ASTRACore

extension ConnectorSnapshotConfig {
    init(connector: Connector) {
        self.init(
            id: connector.id.uuidString,
            name: connector.name,
            serviceType: connector.serviceType,
            icon: connector.icon,
            description: connector.connectorDescription,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys,
            configKeys: connector.configKeys,
            configValues: connector.configValues,
            isGlobal: connector.isGlobal,
            notes: connector.notes,
            createdAt: connector.createdAt,
            updatedAt: connector.updatedAt
        )
    }
}

extension LocalToolSnapshotConfig {
    init(localTool: LocalTool) {
        self.init(
            id: localTool.id.uuidString,
            name: localTool.name,
            description: localTool.toolDescription,
            icon: localTool.icon,
            toolType: localTool.toolType,
            command: localTool.command,
            arguments: localTool.arguments,
            isGlobal: localTool.isGlobal,
            createdAt: localTool.createdAt,
            updatedAt: localTool.updatedAt
        )
    }
}

extension SkillSnapshotConfig {
    init(skill: Skill) {
        self.init(
            id: skill.id.uuidString,
            name: skill.name,
            icon: skill.icon,
            description: skill.skillDescription,
            allowedTools: skill.allowedTools,
            disallowedTools: skill.disallowedTools,
            customTools: skill.customTools,
            behaviorInstructions: skill.behaviorInstructions,
            environmentKeys: skill.environmentKeys,
            environmentValues: skill.environmentValues,
            isGlobal: skill.isGlobal,
            connectorIDs: skill.connectors.map { $0.id.uuidString },
            localToolIDs: skill.localTools.map { $0.id.uuidString },
            connectorSnapshots: skill.connectors.map(ConnectorSnapshotConfig.init(connector:)),
            localToolSnapshots: skill.localTools.map(LocalToolSnapshotConfig.init(localTool:)),
            createdAt: skill.createdAt,
            updatedAt: skill.updatedAt
        )
    }
}

extension ArtifactConfig {
    init(artifact: Artifact) {
        self.init(
            id: artifact.id.uuidString,
            type: artifact.type,
            path: artifact.path,
            content: artifact.content,
            version: artifact.version,
            createdAt: artifact.createdAt
        )
    }
}
