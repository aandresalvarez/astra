import Foundation
import SwiftData
import ASTRAModels

/// The caller's cached graph is not deletion authority. Validate the saved
/// account, bindings and mirror owners before deriving cleanup from that graph.
@MainActor
enum PluginAccountDeletionAdmission {
    static func currentWorkspaces(for account: Connector, modelContext: ModelContext) throws -> [Workspace] {
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        let id = account.id
        var query = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let rows = try saved.fetch(query)
        guard rows.count == 1, let stored = rows.first,
              ConnectorSavedAccountState.matches(stored, account),
              stored.configKeys == account.configKeys, stored.configValues == account.configValues,
              bindings(of: stored) == bindings(of: account)
        else { throw PluginOperations.OperationError.workspaceChanged }
        let current = try modelContext.fetch(FetchDescriptor<Workspace>())
        let persisted = try saved.fetch(FetchDescriptor<Workspace>())
        let expectedScope = try PluginOperations.workspacesUsing(account) { current }
        let actualScope = try PluginOperations.workspacesUsing(stored) { persisted }
        guard Set(expectedScope.map(\.id)) == Set(actualScope.map(\.id)) else {
            throw PluginOperations.OperationError.workspaceChanged
        }
        for workspace in expectedScope {
            try PluginActivationAdmission.requireCurrent(in: workspace, modelContext: modelContext)
        }
        return current
    }

    private struct Binding: Equatable {
        let id: UUID
        let componentID: String
        let isDefault: Bool
        let createdAt: Date
        let alias: String
        let accountID: UUID?
        let activation: PluginActivationRecord?
    }

    private static func bindings(of account: Connector) -> [Binding] {
        account.accountBindings.filter { !$0.isDeleted }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            Binding(id: $0.id, componentID: $0.componentID, isDefault: $0.isDefault,
                createdAt: $0.createdAt, alias: $0.alias, accountID: $0.account?.id,
                activation: $0.activation.map { PluginActivationRecord($0) })
        }
    }
}
