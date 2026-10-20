import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
enum CapabilitySharing {
    static func promoteToShared(_ connector: Connector, in workspace: Workspace?) {
        connector.isGlobal = true
        connector.workspace = nil
        if let workspace {
            // An account a plugin binds here stays in scope through its
            // binding: listed, it would stay on with the plugin off, as a
            // shared account the workspace turned on by itself does.
            if !WorkspaceCapabilityActivation.boundAccountIDs(of: workspace).contains(connector.id) {
                WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalConnector(connector.id.uuidString) }
            }
            workspace.updatedAt = Date()
        }
        connector.updatedAt = Date()
    }

    static func enableShared(_ connector: Connector, in workspace: Workspace) {
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalConnector(connector.id.uuidString) }
        workspace.updatedAt = Date()
    }

    static func disableShared(_ connector: Connector, in workspace: Workspace) {
        WorkspaceCapabilityActivation.mutate(workspace) { $0.globalConnectorIDs.removeAll { $0 == connector.id.uuidString } }
        workspace.updatedAt = Date()
    }

    static func makeWorkspaceCopy(_ connector: Connector, in workspace: Workspace) -> Connector {
        let copy = Connector(
            name: duplicatedName(for: connector, in: workspace),
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
        // Preserve the selected creator's storage/format provenance.
        copy.originPackageID = connector.originPackageID
        copy.originPackageVersion = connector.originPackageVersion
        copy.originComponentID = connector.originComponentID
        copy.originComponentKind = connector.originComponentKind
        copy.originSourceKind = connector.originSourceKind
        return copy
    }

    static func promoteToShared(_ tool: LocalTool, in workspace: Workspace?) {
        tool.isGlobal = true
        tool.workspace = nil
        if let workspace {
            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalTool(tool.id.uuidString) }
            workspace.updatedAt = Date()
        }
        tool.updatedAt = Date()
    }

    static func enableShared(_ tool: LocalTool, in workspace: Workspace) {
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalTool(tool.id.uuidString) }
        workspace.updatedAt = Date()
    }

    static func disableShared(_ tool: LocalTool, in workspace: Workspace) {
        WorkspaceCapabilityActivation.mutate(workspace) { $0.globalToolIDs.removeAll { $0 == tool.id.uuidString } }
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

    private static func duplicatedName(for connector: Connector, in workspace: Workspace) -> String {
        let baseName = connector.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Connector"
            : connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingNames = Set(workspace.connectors.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let firstCandidate = "\(baseName) Copy"
        if !existingNames.contains(firstCandidate.lowercased()) {
            return firstCandidate
        }

        var index = 2
        while true {
            let candidate = "\(baseName) Copy \(index)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }
}
