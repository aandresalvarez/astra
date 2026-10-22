import Foundation

/// The storage contract captured with an Outlook account or accepted task.
/// Legacy writers always used the logical ID, even if the account already
/// had a generic credential generation. New writers must publish the format
/// and generation together. A missing generation or unknown format grants
/// no access; resolving never searches another identity or endpoint alias.
public enum OutlookCredentialIdentity {
    public static let serviceType = "stanford_outlook_mail"
    public static let legacyTokenKeys = ["ASTRA_MAIL_ACCESS_TOKEN", "ASTRA_MAIL_REFRESH_TOKEN", "ASTRA_MAIL_EXPIRES_AT"]
    public static var tokenKeys: [String] { legacyTokenKeys + [OutlookOAuthBundle.storageKey] }

    public static func format(keys: [String], values: [String]) -> String? {
        guard let index = keys.firstIndex(of: formatKey), index < values.count, !values[index].isEmpty else { return nil }
        return values[index]
    }

    public static let formatKey = "ASTRA_MAIL_CREDENTIAL_FORMAT"
    public static let generationFormat = "generation-v1"

    public enum Reference: Equatable, Sendable {
        case legacy(UUID)
        case generation(UUID)

        public var namespaceID: UUID {
            switch self {
            case .legacy(let id), .generation(let id): id
            }
        }
    }

    public static func resolve(
        accountID: UUID, credentialNamespaceID: UUID?, format: String?
    ) -> Reference? {
        switch format {
        case nil, "": return .legacy(accountID)
        case generationFormat:
            return credentialNamespaceID.map(Reference.generation)
        default: return nil
        }
    }
}
