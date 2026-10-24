import Foundation
import ASTRAModels

/// The account fields activation migration may change, including unbound
/// legacy accounts that are absent from workspace activation snapshots.
@MainActor
struct PluginMigrationAccountSnapshot {
    private let account: Connector
    private let namespace: UUID?
    private let packageID, version, componentID, kind, source: String?
    private let updatedAt: Date
    private let skill: Skill?

    init(_ account: Connector) {
        self.account = account
        namespace = account.credentialNamespaceID
        packageID = account.originPackageID
        version = account.originPackageVersion
        componentID = account.originComponentID
        kind = account.originComponentKind
        source = account.originSourceKind
        updatedAt = account.updatedAt
        skill = account.skill
    }

    func restore() {
        if account.credentialNamespaceID != namespace { account.credentialNamespaceID = namespace }
        if account.originPackageID != packageID { account.originPackageID = packageID }
        if account.originPackageVersion != version { account.originPackageVersion = version }
        if account.originComponentID != componentID { account.originComponentID = componentID }
        if account.originComponentKind != kind { account.originComponentKind = kind }
        if account.originSourceKind != source { account.originSourceKind = source }
        if account.updatedAt != updatedAt { account.updatedAt = updatedAt }
        if account.skill?.id != skill?.id { account.skill = skill }
    }
}
