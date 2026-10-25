import Foundation
import ASTRACore

// The portable account record, shared by explicit exports and recovery mirrors.
extension WorkspaceConfigManager {
    public struct ConnectorConfig: Codable, Sendable {
        public init(id: String? = nil, name: String, serviceType: String, icon: String, description: String, baseURL: String, authMethod: String, credentialKeys: [String], configKeys: [String], configValues: [String], isGlobal: Bool? = nil, notes: String, originPackageID: String? = nil, originPackageVersion: String? = nil, originComponentID: String? = nil, originComponentKind: String? = nil, originSourceKind: String? = nil, accountAlias: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil, credentialNamespaceID: UUID? = nil, outlookCredentialFormat: String? = nil) {
            self.id = id
            self.credentialNamespaceID = credentialNamespaceID
            self.outlookCredentialFormat = outlookCredentialFormat ?? OutlookCredentialIdentity.format(keys: configKeys, values: configValues)
            self.name = name
            self.serviceType = serviceType
            self.icon = icon
            self.description = description
            self.baseURL = baseURL
            self.authMethod = authMethod
            self.credentialKeys = credentialKeys
            self.configKeys = configKeys
            self.configValues = configValues
            self.isGlobal = isGlobal
            self.notes = notes
            self.originPackageID = originPackageID
            self.originPackageVersion = originPackageVersion
            self.originComponentID = originComponentID
            self.originComponentKind = originComponentKind
            self.originSourceKind = originSourceKind
            self.accountAlias = accountAlias
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var id: String?
        public var credentialNamespaceID: UUID?
        public var outlookCredentialFormat: String?
        public var name: String
        public var serviceType: String
        public var icon: String
        public var description: String
        public var baseURL: String
        public var authMethod: String
        public var credentialKeys: [String]
        public var configKeys: [String]
        public var configValues: [String]
        public var isGlobal: Bool?
        public var notes: String
        public var accountAlias: String? = nil
        public var originPackageID: String? = nil
        public var originPackageVersion: String? = nil
        public var originComponentID: String? = nil
        public var originComponentKind: String? = nil
        public var originSourceKind: String? = nil
        public var createdAt: Date?
        public var updatedAt: Date?
    }
}
