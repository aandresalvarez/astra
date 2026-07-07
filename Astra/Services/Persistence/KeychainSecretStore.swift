import Foundation
import ASTRACore
import ASTRAModels

/// `SecretStore` backed by ASTRA's dedicated keychain file (see
/// `AstraSecureKeychainStore`), keeping connector/skill secrets out of the
/// user's `login.keychain-db`. The protocol surface is unchanged — only the
/// backing store moved.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func load(key: String, entityID: String) -> String? {
        AstraSecureKeychainStore.load(service: entityID, account: key)
    }

    @discardableResult
    public func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        AstraSecureKeychainStore.save(
            service: entityID,
            account: key,
            value: value,
            label: label ?? "Astra credential"
        )
    }

    @discardableResult
    public func delete(key: String, entityID: String) -> Bool {
        AstraSecureKeychainStore.delete(service: entityID, account: key)
    }

    public func deleteAll(entityID: String) {
        AstraSecureKeychainStore.deleteAll(service: entityID)
    }

    public func exists(key: String, entityID: String) -> Bool {
        AstraSecureKeychainStore.exists(service: entityID, account: key)
    }

    public static func connectorEntityID(for connectorID: UUID) -> String {
        "\(AppChannel.current.keychainConnectorPrefix)-\(connectorID.uuidString)"
    }

    public static func connectorEntityIDs(for connector: Connector) -> [String] {
        connectorEntityIDs(
            id: connector.id,
            serviceType: connector.serviceType,
            baseURL: connector.baseURL,
            originPackageID: connector.originPackageID,
            originComponentID: connector.originComponentID
        )
    }

    /// Primitive twin of `connectorEntityIDs(for:)`, usable from
    /// `ASTRACore.ConnectorSecretFacts` call sites that no longer have a live
    /// `Connector` (Track A2.5's `Connector.swift` seam boundary).
    public static func connectorEntityIDs(
        id: UUID,
        serviceType: String,
        baseURL: String,
        originPackageID: String?,
        originComponentID: String?
    ) -> [String] {
        var entityIDs = [connectorEntityID(for: id)]
        if let stableEntityID = stableConnectorEntityID(
            serviceType: serviceType,
            baseURL: baseURL,
            originPackageID: originPackageID,
            originComponentID: originComponentID
        ) {
            entityIDs.append(stableEntityID)
        }
        return unique(entityIDs)
    }

    public static func stableConnectorEntityID(for connector: Connector) -> String? {
        stableConnectorEntityID(
            serviceType: connector.serviceType,
            baseURL: connector.baseURL,
            originPackageID: connector.originPackageID,
            originComponentID: connector.originComponentID
        )
    }

    public static func stableConnectorEntityID(
        serviceType: String,
        baseURL: String,
        originPackageID: String? = nil,
        originComponentID: String? = nil
    ) -> String? {
        let service = slug(serviceType)
        let base = normalizedBaseURLIdentity(baseURL).map(slug)
        let package = slug(originPackageID ?? "")
        let component = slug(originComponentID ?? "")

        let identity: String
        if !package.isEmpty || !component.isEmpty {
            identity = [service, package, component, base ?? ""].filter { !$0.isEmpty }.joined(separator: "-")
        } else if let base, !base.isEmpty {
            identity = [service, base].filter { !$0.isEmpty }.joined(separator: "-")
        } else {
            return nil
        }

        guard !identity.isEmpty else { return nil }
        return "\(AppChannel.current.keychainConnectorPrefix)-connector-\(String(identity.prefix(160)))"
    }

    public static func skillEntityID(for skillID: UUID) -> String {
        "\(AppChannel.current.keychainSkillPrefix)-\(skillID.uuidString)"
    }

    public static func googleOAuthEntityID(for accountID: UUID) -> String {
        "\(AppChannel.current.keychainConnectorPrefix)-google-oauth-\(accountID.uuidString)"
    }

    private static func normalizedBaseURLIdentity(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let components = URLComponents(string: candidate),
           let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            var parts = [host.lowercased()]
            if let port = components.port {
                parts.append("port-\(port)")
            }
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                parts.append(path.lowercased())
            }
            return parts.joined(separator: "-")
        }
        return trimmed.lowercased()
    }

    private static func slug(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasSeparator = false
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("-")
                previousWasSeparator = true
            }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
