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
            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableGlobalConnector(connector.id.uuidString) }
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

    static func duplicateForWorkspace(
        _ connector: Connector,
        in workspace: Workspace,
        secretStore: SecretStore = KeychainSecretStore()
    ) -> Connector {
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
        copy.accountAlias = connector.accountAlias
        copy.workspace = workspace
        copy.isGlobal = false
        copyCredentials(from: connector, to: copy, secretStore: secretStore)
        disableShared(connector, in: workspace)
        // The copy takes the shared account's place, including as the
        // workspace's default for its service.
        WorkspaceCapabilityActivation.mutate(workspace) { state in
            let service = WorkspaceCapabilityActivationState.normalizedService(connector.serviceType)
            if state.defaultAccountID(forService: service) == connector.id.uuidString {
                state.setDefaultAccount(copy.id.uuidString, forService: service)
            }
        }
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

    private static func copyCredentials(
        from source: Connector,
        to destination: Connector,
        secretStore: SecretStore
    ) {
        let sourceEntityIDs = KeychainSecretStore.connectorEntityIDs(for: source)
        let destinationEntityIDs = KeychainSecretStore.connectorEntityIDs(for: destination)
        for key in source.credentialKeys {
            guard let value = sourceEntityIDs.compactMap({ secretStore.load(key: key, entityID: $0) }).first,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            for destinationEntityID in destinationEntityIDs {
                secretStore.save(
                    key: key,
                    value: value,
                    entityID: destinationEntityID,
                    label: "Astra: \(destination.name)"
                )
            }
        }
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
