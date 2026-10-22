import Foundation
import ASTRAModels

/// The workspaces named at the first tap. This is transient user consent,
/// not ownership state; deletion must compare it with the saved owners.
struct PluginAccountDeletionScope: Equatable {
    struct WorkspaceEntry: Equatable {
        let id: UUID
        let name: String
    }

    let accountID: UUID
    let workspaces: [WorkspaceEntry]

    @MainActor
    static func capture(_ account: Connector) throws -> Self {
        let owners = try PluginOperations.workspacesUsing(account)
        return Self(accountID: account.id, workspaces: owners.sorted {
            $0.id.uuidString < $1.id.uuidString
        }.map { WorkspaceEntry(id: $0.id, name: $0.name) })
    }
}
