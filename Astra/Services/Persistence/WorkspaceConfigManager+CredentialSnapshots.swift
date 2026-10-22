import Foundation
import ASTRACore

/// Credential references are recoverable metadata, never authority supplied
/// by a chosen file. Secret values remain outside portable snapshots.
extension WorkspaceConfigManager {
    static func redactedSkillSnapshot(_ snapshot: SkillSnapshotConfig) -> SkillSnapshotConfig {
        SkillSnapshotConfig(
            id: snapshot.id,
            name: snapshot.name,
            icon: snapshot.icon,
            description: snapshot.description,
            allowedTools: snapshot.allowedTools,
            disallowedTools: snapshot.disallowedTools,
            customTools: snapshot.customTools,
            behaviorInstructions: snapshot.behaviorInstructions,
            environmentKeys: snapshot.environmentKeys,
            environmentValues: Array(repeating: "", count: snapshot.environmentKeys.count),
            isGlobal: snapshot.isGlobal,
            connectorIDs: snapshot.connectorIDs,
            localToolIDs: snapshot.localToolIDs,
            connectorSnapshots: snapshot.connectorSnapshots,
            localToolSnapshots: snapshot.localToolSnapshots,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            credentialNamespaceID: snapshot.credentialNamespaceID
        )
    }

    static func importedSkillSnapshots(_ snapshots: [SkillSnapshotConfig], freshIDs: Bool) -> [SkillSnapshotConfig] {
        snapshots.map { snapshot in
            var copied = snapshot
            if freshIDs {
                copied.credentialNamespaceID = nil
                copied.connectorSnapshots = copied.connectorSnapshots?.map { account in
                    var isolated = account
                    isolated.credentialNamespaceID = UUID()
                    if isolated.serviceType == OutlookCredentialIdentity.serviceType {
                        isolated.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
                    }
                    return isolated
                }
            }
            return copied
        }
    }
}
