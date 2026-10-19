import Foundation
import SwiftData
import ASTRAModels

extension WorkspaceConfigManager {
    /// One Import Workspace action across every workspace it imports, as when
    /// a parent `Workspaces` folder expands into its child workspaces.
    ///
    /// A chosen file's created rows get fresh IDs (a reused UUID would read
    /// another row's Keychain credentials), so two children that list the
    /// same shared account would each mint their own copy. The session maps
    /// each exported shared account ID to the one row the first child
    /// created; a later child uses that row, which becomes a shared row
    /// again, and binds its activations to it. The row keeps its fresh ID, so
    /// it still resolves no credential this machine had. Only `.validate`
    /// imports consult it; a single-workspace import has none, and mirror
    /// recovery keeps the file's own IDs.
    @MainActor
    public final class ImportSession {
        /// File account ID -> the row created for it, and the workspace whose
        /// import created it.
        private var accounts: [String: (row: Connector, owner: Workspace, listed: Bool)] = [:]
        /// The rows each later workspace took from `accounts`, by workspace.
        private var adopted: [UUID: Set<String>] = [:]

        public init() {}

        /// Records the row created for the file's shared account `cc`; the
        /// first workspace to create one keeps it.
        /// `listed`: the creating workspace's mirror had it on its shared list.
        func record(_ row: Connector, for cc: ConnectorConfig, createdIn workspace: Workspace, listed: Bool) {
            guard cc.isGlobal == true, let fileID = cc.id, accounts[fileID] == nil else { return }
            accounts[fileID] = (row, workspace, listed)
        }

        /// The row an earlier workspace of this import created for `cc`.
        func sharedAccount(for cc: ConnectorConfig, in workspace: Workspace) -> (row: Connector, owner: Workspace, listed: Bool)? {
            guard cc.isGlobal == true, let fileID = cc.id, let entry = accounts[fileID],
                  !entry.row.isDeleted, entry.owner.id != workspace.id else { return nil }
            return entry
        }

        func adopt(_ row: Connector, in workspace: Workspace) {
            adopted[workspace.id, default: []].insert(row.id.uuidString)
        }

        /// The shared rows `workspace` took from an earlier one: created by
        /// this import, so its activations may bind them (`acceptsAccount`).
        func sharedRowIDs(in workspace: Workspace) -> Set<String> {
            adopted[workspace.id] ?? []
        }
    }

    /// Uses the row this import already created for `cc` in another
    /// workspace, made shared again so both use it: back on the creating
    /// workspace's shared list, where it was its own row until now (unless
    /// it is there only through a binding its mirror didn't list), and on
    /// this one's, which `restoreActivationDetails` settles the same way.
    /// Like a reused shared row it takes none of this file's skills. False
    /// when the import has no such row.
    @MainActor
    static func adoptSharedAccount(
        _ cc: ConnectorConfig,
        _ session: ImportSession?,
        _ workspace: Workspace,
        _ activation: inout WorkspaceCapabilityActivationState,
        _ connectorsByID: inout [String: Connector],
        _ reusedRowIDs: inout Set<String>
    ) -> Bool {
        guard let (row, owner, listed) = session?.sharedAccount(for: cc, in: workspace) else { return false }
        if !row.isGlobal {
            row.isGlobal = true
            row.workspace = nil
            let boundByOwner = WorkspaceCapabilityActivation.workspacesBinding(row).contains { $0.id == owner.id }
            if listed || !boundByOwner {
                WorkspaceCapabilityActivation.mutate(owner) { $0.enableGlobalConnector(row.id.uuidString) }
            }
        }
        session?.adopt(row, in: workspace)
        reusedRowIDs.insert(row.id.uuidString)
        activation.enableGlobalConnector(row.id.uuidString)
        connectorsByID[row.id.uuidString] = row
        if let fileID = cc.id { connectorsByID[fileID] = row }
        return true
    }
}
