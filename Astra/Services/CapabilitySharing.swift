import Foundation

@MainActor
enum CapabilitySharing {
    static func promoteToShared(_ connector: Connector, in workspace: Workspace?) {
        connector.isGlobal = true
        connector.workspace = nil
        if let workspace {
            appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)
            workspace.updatedAt = Date()
        }
        connector.updatedAt = Date()
    }

    static func enableShared(_ connector: Connector, in workspace: Workspace) {
        appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)
        workspace.updatedAt = Date()
    }

    static func disableShared(_ connector: Connector, in workspace: Workspace) {
        workspace.enabledGlobalConnectorIDs.removeAll { $0 == connector.id.uuidString }
        workspace.updatedAt = Date()
    }

    static func duplicateForWorkspace(_ connector: Connector, in workspace: Workspace) -> Connector {
        let copy = Connector(
            name: connector.name,
            serviceType: connector.serviceType,
            icon: connector.icon,
            connectorDescription: connector.connectorDescription,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod
        )
        copy.credentialKeys = connector.credentialKeys
        copy.credentialValues = Array(repeating: "", count: connector.credentialKeys.count)
        copy.configKeys = connector.configKeys
        copy.configValues = connector.configValues
        copy.testHTTPMethod = connector.testHTTPMethod
        copy.notes = connector.notes
        copy.workspace = workspace
        copy.isGlobal = false
        disableShared(connector, in: workspace)
        return copy
    }

    static func promoteToShared(_ tool: LocalTool, in workspace: Workspace?) {
        tool.isGlobal = true
        tool.workspace = nil
        if let workspace {
            appendUnique(tool.id.uuidString, to: &workspace.enabledGlobalToolIDs)
            workspace.updatedAt = Date()
        }
        tool.updatedAt = Date()
    }

    static func enableShared(_ tool: LocalTool, in workspace: Workspace) {
        appendUnique(tool.id.uuidString, to: &workspace.enabledGlobalToolIDs)
        workspace.updatedAt = Date()
    }

    static func disableShared(_ tool: LocalTool, in workspace: Workspace) {
        workspace.enabledGlobalToolIDs.removeAll { $0 == tool.id.uuidString }
        workspace.updatedAt = Date()
    }

    static func duplicateForWorkspace(_ tool: LocalTool, in workspace: Workspace) -> LocalTool {
        let copy = LocalTool(
            name: tool.name,
            toolDescription: tool.toolDescription,
            icon: tool.icon,
            toolType: tool.toolType,
            command: tool.command,
            arguments: tool.arguments
        )
        copy.workspace = workspace
        copy.isGlobal = false
        disableShared(tool, in: workspace)
        return copy
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}
