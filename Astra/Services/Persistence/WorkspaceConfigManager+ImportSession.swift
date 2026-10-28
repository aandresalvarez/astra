import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension WorkspaceConfigManager {
    /// One Import Workspace action across every workspace it imports, as when
    /// a parent `Workspaces` folder expands into its child workspaces.
    ///
    /// A chosen file's created rows get fresh IDs (a reused UUID would read
    /// another row's Keychain credentials), so two children that list the
    /// same shared account would each mint their own copy. Each file is its
    /// own trust domain: by default every workspace gets its own row, since
    /// a crafted file in the same folder could describe another file's
    /// account identically, get bound to its row, and later receive the
    /// credentials the person enters for the legitimate workspace; matching
    /// fields the file controls is not authentication. Only an account the
    /// person explicitly confirmed (`sharedAccountIDs`, the file's account
    /// ID) is shared: the session maps it to the one row the first child
    /// created; a later child uses that row, which becomes a shared row
    /// again, and binds its activations to it. The row keeps its fresh ID, so
    /// it still resolves no credential this machine had. Two files that give
    /// one ID to different accounts (another service, URL, sign-in, name or
    /// setting) are not merged even then: each gets its own row, and the
    /// mismatch is logged, so neither workspace is pointed at the other's
    /// tenant. Only `.validate` imports consult it; a single-workspace import
    /// has none, and mirror recovery keeps the file's own IDs.
    @MainActor
    public final class ImportSession {
        /// File account ID -> the row created for it, and the workspace whose
        /// import created it.
        private var accounts: [String: (row: Connector, owner: Workspace, listed: Bool, record: AccountRecord)] = [:]

        /// What a file says an account is, secrets aside: two files must
        /// agree on all of it to share one row.
        struct AccountRecord: Equatable {
            let serviceType: String
            let baseURL: String
            let authMethod: String
            let name: String
            let credentialKeys: [String]
            let configKeys: [String]
            let configValues: [String]

            init(_ cc: ConnectorConfig) {
                serviceType = cc.serviceType
                baseURL = cc.baseURL
                authMethod = cc.authMethod
                name = cc.name
                credentialKeys = cc.credentialKeys
                configKeys = cc.configKeys
                configValues = cc.configValues
            }
        }
        /// The rows each later workspace took from `accounts`, by workspace.
        private var adopted: [UUID: Set<String>] = [:]

        /// The file account IDs the person confirmed may share one row
        /// across the files of this action. Empty: none is shared.
        private let sharedAccountIDs: Set<String>

        public init(sharedAccountIDs: Set<String> = []) {
            self.sharedAccountIDs = sharedAccountIDs
        }

        /// Records the row created for the file's shared account `cc`; the
        /// first workspace to create one keeps it.
        /// `listed`: the creating workspace's mirror had it on its shared list.
        func record(_ row: Connector, for cc: ConnectorConfig, createdIn workspace: Workspace, listed: Bool) {
            guard cc.isGlobal == true, let fileID = cc.id, accounts[fileID] == nil else { return }
            accounts[fileID] = (row, workspace, listed, AccountRecord(cc))
        }

        /// The row an earlier workspace of this import created for `cc`,
        /// when the person confirmed sharing it; nil otherwise.
        func sharedAccount(for cc: ConnectorConfig, in workspace: Workspace) -> (row: Connector, owner: Workspace, listed: Bool)? {
            guard cc.isGlobal == true, let fileID = cc.id, sharedAccountIDs.contains(fileID), let entry = accounts[fileID],
                  !entry.row.isDeleted, entry.owner.id != workspace.id else { return nil }
            guard entry.record == AccountRecord(cc) else {
                AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "operation": "import_shared_account",
                    "reason": "account_records_differ",
                    "workspace_id": workspace.id.uuidString
                ], level: .warning)
                return nil
            }
            return (entry.row, entry.owner, entry.listed)
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
