import Foundation
import ASTRACore
import ASTRAModels

/// Whether a run may be handed `ASTRA_MAIL_REGISTRY_PATH`.
///
/// That variable is not a route, it is a credential pointer. The registry it
/// names hands the helper the Keychain service holding the mailbox access and
/// refresh tokens, which the helper then reads with `/usr/bin/security` —
/// outside the connector projection, so `connectorCredentialExposurePolicy`
/// never sees it and cannot withhold it.
///
/// That is why this one cannot follow reachability the way a route does.
/// Connector preflight walks only the narrated set, so an enabled Stanford mail
/// connector that this turn's wording pruned raises no first-use approval;
/// widening the injection to the reachable tier would let a turn about
/// something else perform authenticated mailbox reads that the user was never
/// asked about.
///
/// Narrated is unchanged — preflight walks it, so the approval exists. Offered
/// has to carry the grant the narrated path would have obtained.
enum StanfordOutlookMailRuntimeAccess {
    @MainActor
    static func isGranted(
        for task: AgentTask,
        in capabilityScope: TaskCapabilityPromptScope,
        runtime: AgentRuntimeID?,
        additionalGrants: [PermissionGrant]
    ) -> Bool {
        if capabilityScope.connectors.contains(where: { $0.isStanfordOutlookMail })
            || capabilityScope.localTools.contains(where: { $0.command == StanfordOutlookMail.toolCommand }) {
            return true
        }
        let offered = capabilityScope.reachableConnectors.filter(\.isStanfordOutlookMail)
        guard !offered.isEmpty else { return false }
        let approvedConnectorIDs = TaskCapabilityResolver.approvedCredentialConnectorIDs(
            in: TaskRuntimePermissionGrants.approvedCredentialLabels(
                for: task,
                runtime: runtime,
                additionalGrants: additionalGrants
            )
        )
        return offered.contains { approvedConnectorIDs.contains($0.id) }
    }
}
