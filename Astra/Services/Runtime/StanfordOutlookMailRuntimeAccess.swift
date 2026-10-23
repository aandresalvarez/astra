import Foundation
import ASTRACore
import ASTRAModels
import HostControlToolSupport

/// One launch's approved value records. A local-tool declaration grants no
/// account access, and later live edits cannot change a captured generation.
@MainActor
enum StanfordOutlookMailRuntimeAccess {
    struct Snapshot {
        let accounts: [PluginAccountRecord]
        let withheldAccountCount: Int

        @MainActor
        func makeReader(load: @escaping @MainActor @Sendable (PluginAccountRecord, MailReadRequest) async throws -> Data = {
            try await StanfordOutlookMailGraphService().read(account: $0, request: $1)
        }) -> BrokeredMailReadBridge {
            do {
                let session = try OutlookMailReadSession(accounts: accounts, withheldAccounts: withheldAccountCount, load: load)
                return BrokeredMailReadBridge { try await session.readMail($0) }
            } catch {
                // Malformed captured state closes this route without silently
                // picking a different account or blocking unrelated tools.
                return BrokeredMailReadBridge { _ in throw MailReadFailure.invalidSnapshot }
            }
        }
    }

    static func capture(for task: AgentTask, in scope: TaskCapabilityPromptScope,
                        runtime: AgentRuntimeID?, additionalGrants: [PermissionGrant]) -> Snapshot {
        let narrated = Set(scope.connectors.map(\.id))
        let approved = TaskCapabilityResolver.approvedCredentialConnectorIDs(
            in: TaskRuntimePermissionGrants.approvedCredentialLabels(for: task, runtime: runtime,
                additionalGrants: additionalGrants))
        let reachable = scope.reachableConnectors.filter(\.isStanfordOutlookMail)
        let allowed = reachable.filter { narrated.contains($0.id) || approved.contains($0.id) }
        return Snapshot(accounts: allowed.map(PluginAccountRecord.init),
            withheldAccountCount: reachable.count - allowed.count)
    }
}
