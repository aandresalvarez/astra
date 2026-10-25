import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// One read-only comparison for a saved account owner. Credential cutovers
/// and deletion must not replace a newer saved identity or generation.
@MainActor
enum ConnectorSavedAccountState {
    static func matches(_ stored: Connector, _ current: Connector) -> Bool {
        ConnectorSnapshotConfig(connector: stored) == ConnectorSnapshotConfig(connector: current)
            && stored.credentialValues == current.credentialValues
            && stored.originPackageID == current.originPackageID
            && stored.originPackageVersion == current.originPackageVersion
            && stored.originComponentID == current.originComponentID
            && stored.originComponentKind == current.originComponentKind
            && stored.originSourceKind == current.originSourceKind
            && stored.accountAlias == current.accountAlias
            && stored.testHTTPMethod == current.testHTTPMethod
            && stored.workspace?.id == current.workspace?.id
            && stored.skill?.id == current.skill?.id
    }
}
