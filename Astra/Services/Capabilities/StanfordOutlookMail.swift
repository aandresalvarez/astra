import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum StanfordOutlookMail {
    static let capabilityID = "stanford-outlook-mail"
    static let serviceType = "stanford_outlook_mail"
    static let authMethod = "oauth"
    static let toolCommand = "stanford-mail"
    static let graphBaseURL = "https://graph.microsoft.com/v1.0"

    static let accessTokenKey = "ASTRA_MAIL_ACCESS_TOKEN"
    static let refreshTokenKey = "ASTRA_MAIL_REFRESH_TOKEN"
    static let expiresAtKey = "ASTRA_MAIL_EXPIRES_AT"

    static let emailKey = "ASTRA_MAIL_EMAIL"
    static let tenantDomainKey = "ASTRA_MAIL_TENANT_DOMAIN"
    static let clientIDKey = "ASTRA_MAIL_CLIENT_ID"
    static let accountIDKey = "ASTRA_MAIL_ACCOUNT_ID"
    static let displayNameKey = "ASTRA_MAIL_DISPLAY_NAME"
    static let scopesKey = "ASTRA_MAIL_SCOPES"
    static let tokenUpdatedAtKey = "ASTRA_MAIL_TOKEN_UPDATED_AT"

    static let authorizationConfigurationKeys = [tenantDomainKey, clientIDKey, scopesKey, emailKey,
        displayNameKey, accountIDKey, tokenUpdatedAtKey]
    static let defaultTenantDomain = "stanford.edu"
    static let defaultScopes = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/Mail.Read",
        "offline_access",
        "openid",
        "profile"
    ]

    static var scopeString: String {
        defaultScopes.joined(separator: " ")
    }

    /// Tests point the registry elsewhere through this task-local, so they
    /// never read or rewrite the user's real mail registry.
    @TaskLocal static var registryURLOverride: URL?

    static var registryURL: URL {
        if let registryURLOverride { return registryURLOverride }
        let toolsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".astra", isDirectory: true)
        return toolsRoot.appendingPathComponent("mail-accounts-\(AppChannel.current.keychainConnectorPrefix).json")
    }

    static func normalizeTenant(_ tenant: String) -> String {
        let trimmed = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultTenantDomain : trimmed.lowercased()
    }

    static func normalizeConfiguredTenant(_ tenant: String) -> String {
        tenant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func keychainService(for connectorID: UUID) -> String {
        KeychainSecretStore.connectorEntityID(for: connectorID)
    }
}

extension Connector {
    // `isStanfordOutlookMail`, `configValue(_:)`, `setConfigValue(_:value:)`,
    // and `outlookEmail` moved to `Astra/Models/Connector.swift` as part of
    // Track A2.5 — see that file's "Stanford Outlook Mail (pure members)"
    // section.

    var outlookTenantDomain: String {
        StanfordOutlookMail.normalizeTenant(configuredOutlookTenantDomain)
    }

    var configuredOutlookTenantDomain: String {
        StanfordOutlookMail.normalizeConfiguredTenant(configValue(StanfordOutlookMail.tenantDomainKey))
    }

    var hasConfiguredOutlookTenantDomain: Bool {
        !configuredOutlookTenantDomain.isEmpty
    }

    var outlookClientID: String {
        configValue(StanfordOutlookMail.clientIDKey).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var outlookDisplayName: String {
        configValue(StanfordOutlookMail.displayNameKey)
    }

    var hasOutlookAuthorization: Bool { outlookAuthorizationReadiness.canReadMail() }

    /// Expired or incomplete credentials can still be explicitly cleared.
    var hasStoredOutlookAuthorization: Bool { outlookAuthorizationReadiness.isStored }

    var outlookAuthorizationReadiness: OutlookAuthorizationReadiness {
        guard hasConfiguredOutlookTenantDomain, !outlookClientID.isEmpty,
              let reference = OutlookCredentialIdentity.resolve(accountID: id, credentialNamespaceID: credentialNamespaceID,
                format: outlookCredentialFormat) else { return .unavailable }
        // Presentation only: atomic bundle reads need no refresh/cleanup lease.
        let service = KeychainSecretStore.connectorEntityID(for: reference.namespaceID)
        switch AstraSecureKeychainStore.read(service: service, account: OutlookOAuthBundle.storageKey) {
        case .value(let json):
            guard let data = json.data(using: .utf8), let bundle = try? JSONDecoder().decode(OutlookOAuthBundle.self, from: data),
                  bundle.matches(tenantDomain: outlookTenantDomain, clientID: outlookClientID,
                    principalID: configValue(StanfordOutlookMail.accountIDKey)) else { return .unavailable }
            return OutlookAuthorizationReadiness(isStored: true, canRefresh: bundle.refreshToken?.isEmpty == false,
                accessTokenExpiresAt: bundle.expiresAt)
        case .missing:
            guard case .legacy = reference else { return .unavailable }
            var fields: [String?] = []
            for key in OutlookCredentialIdentity.legacyTokenKeys {
                switch AstraSecureKeychainStore.read(service: service, account: key) {
                case .value(let value): fields.append(value)
                case .missing: fields.append(nil)
                case .unavailable: return .unavailable
                }
            }
            let stored = fields[0]?.isEmpty == false || fields[1]?.isEmpty == false
            guard fields[0]?.isEmpty == false, let expiry = fields[2].flatMap(TimeInterval.init), expiry.isFinite else {
                return OutlookAuthorizationReadiness(isStored: stored, canRefresh: false, accessTokenExpiresAt: nil)
            }
            return OutlookAuthorizationReadiness(isStored: stored, canRefresh: fields[1]?.isEmpty == false,
                accessTokenExpiresAt: Date(timeIntervalSince1970: expiry))
        case .unavailable: return .unavailable
        }
    }

    func applyStanfordOutlookDefaults(defaultTenant: Bool = true) {
        serviceType = StanfordOutlookMail.serviceType
        authMethod = StanfordOutlookMail.authMethod
        icon = "envelope.badge.shield.half.filled"
        baseURL = StanfordOutlookMail.graphBaseURL
        testHTTPMethod = "GET"
        if defaultTenant && configValue(StanfordOutlookMail.tenantDomainKey).isEmpty {
            setConfigValue(StanfordOutlookMail.tenantDomainKey, value: StanfordOutlookMail.defaultTenantDomain)
        }
        if configValue(StanfordOutlookMail.scopesKey).isEmpty {
            setConfigValue(StanfordOutlookMail.scopesKey, value: StanfordOutlookMail.scopeString)
        }
        if connectorDescription.isEmpty {
            connectorDescription = "Read Stanford Microsoft 365 mail through Microsoft Graph."
        }
        if notes.isEmpty {
            notes = "Uses Microsoft OAuth device-code sign-in. Duo/Cardinal Key prompts are handled by the Stanford or SHC Microsoft sign-in page."
        }
        updatedAt = Date()
    }


}

struct MicrosoftDeviceCodeResponse: Decodable, Equatable {
    let userCode: String
    let deviceCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    let message: String
}

struct MicrosoftTokenResponse: Decodable {
    let tokenType: String?
    let scope: String?
    let expiresIn: Int
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
}

struct MicrosoftOAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?
}

struct GraphMeResponse: Decodable, Equatable {
    let id: String
    let displayName: String?
    let userPrincipalName: String?
    let mail: String?
}

struct GraphEmailAddress: Decodable {
    let name: String?
    let address: String?
}

struct GraphRecipient: Decodable {
    let emailAddress: GraphEmailAddress?
}

struct GraphItemBody: Decodable {
    let contentType: String?
    let content: String?
}

struct GraphMessage: Decodable {
    let id: String
    let subject: String?
    let receivedDateTime: String?
    let sentDateTime: String?
    let bodyPreview: String?
    let body: GraphItemBody?
    let from: GraphRecipient?
    let toRecipients: [GraphRecipient]?
    let ccRecipients: [GraphRecipient]?
    let hasAttachments: Bool?
    let webLink: String?
}

enum StanfordOutlookMailError: LocalizedError {
    case missingTenant
    case missingClientID
    case missingDeviceCode
    case missingRefreshToken
    case expiredDeviceCode
    case authorizationDeclined
    case oauth(String)
    case graph(Int, String)
    case invalidResponse
    case credentialWriteFailed

    var errorDescription: String? {
        switch self {
        case .missingTenant:
            return "Enter a Microsoft 365 tenant domain, such as stanford.edu or stanfordhealthcare.org."
        case .missingClientID:
            return "Enter the Microsoft Entra application client ID for this tenant."
        case .missingDeviceCode:
            return "Start sign-in before completing authorization."
        case .missingRefreshToken:
            return "This account is not connected yet. Sign in again."
        case .expiredDeviceCode:
            return "The sign-in code expired. Start sign-in again."
        case .authorizationDeclined:
            return "The Microsoft sign-in was declined."
        case .oauth(let message):
            return message
        case .graph(let status, let message):
            return "Microsoft Graph HTTP \(status): \(message)"
        case .credentialWriteFailed:
            return "ASTRA could not preserve the renewed authorization. Unlock the credential store and retry."
        case .invalidResponse:
            return "Microsoft returned an unexpected response."
        }
    }
}

enum StanfordOutlookMailRegistry {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String { connectorID }
        var connectorID: String
        var name: String
        var email: String
        var tenantDomain: String
        var clientID: String
        var keychainService: String
        var channel: String
        var displayName: String
        var updatedAt: String
    }

    static func entries() -> [Entry] {
        readEntries() ?? []
    }

    /// Nil when the registry can't be read or decoded, which a writer must
    /// never take as empty.
    private static func readEntries() -> [Entry]? {
        let registryURL = StanfordOutlookMail.registryURL
        let broker = HostFileAccessBroker()
        guard let data = try? broker.readData(
            at: registryURL,
            intent: .astraManagedStorage(root: registryURL.deletingLastPathComponent())
        ) else {
            return nil
        }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    static func upsert(
        connector: Connector,
        attributes: (String) throws -> [FileAttributeKey: Any] = { try FileManager.default.attributesOfItem(atPath: $0) }
    ) {
        guard connector.isStanfordOutlookMail else { return }
        // A registry that exists but can't be read is never rewritten with
        // only this account: the others it holds would be lost. Only one
        // confirmed missing starts empty; one that can't be checked is
        // left alone too.
        let existing: [Entry]
        let present: Bool
        do {
            _ = try attributes(StanfordOutlookMail.registryURL.path)
            present = true
        } catch {
            guard WorkspaceFileLayout.isMissingFile(error) else {
                AppLogger.audit(.connectorTested, category: "Mail", fields: [
                    "result": "registry_unreadable_upsert_skipped"
                ], level: .warning)
                return
            }
            present = false
        }
        if present {
            guard let read = readEntries() else {
                AppLogger.audit(.connectorTested, category: "Mail", fields: [
                    "result": "registry_unreadable_upsert_skipped"
                ], level: .warning)
                return
            }
            existing = read
        } else {
            existing = []
        }
        var current = existing.filter { $0.connectorID != connector.id.uuidString }
        current.append(Entry(
            connectorID: connector.id.uuidString,
            name: connector.name,
            email: connector.outlookEmail,
            tenantDomain: connector.outlookTenantDomain,
            clientID: connector.outlookClientID,
            keychainService: StanfordOutlookMail.keychainService(for: connector.id),
            channel: AppChannel.current.rawValue,
            displayName: connector.outlookDisplayName,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        ))
        save(current)
    }

    /// True once no entry for `connectorID` remains. A registry that exists
    /// but can't be read is left as it is, never rewritten without the other
    /// accounts, and reported as not removed, as is one that can't even be
    /// checked: only a confirmed missing registry holds no entry.
    @discardableResult
    static func remove(connectorID: UUID) -> Bool {
        // Without following links: a dangling one is still a registry, whose
        // target could come back with the entry in it, so it is unverified.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: StanfordOutlookMail.registryURL.path)
        } catch {
            return WorkspaceFileLayout.isMissingFile(error)
        }
        guard let current = readEntries() else { return false }
        let remaining = current.filter { $0.connectorID != connectorID.uuidString }
        guard remaining.count != current.count else { return true }
        return save(remaining)
    }

    /// Where the registry's contents live: the registry itself, or, when it
    /// is a link, the file it resolves to. Writing the link's target keeps
    /// the link and updates what every reader of it sees, rather than
    /// replacing the link with a file while the old entries stay behind it.
    /// Nil when that file lies outside the registry's own managed folder,
    /// the same boundary the broker reads within, so a link can never make
    /// ASTRA overwrite an unrelated file.
    private static var registryWriteURL: URL? {
        let target = StanfordOutlookMail.registryURL.resolvingSymlinksInPath()
        let root = StanfordOutlookMail.registryURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let folder = target.deletingLastPathComponent().path
        return folder == root || folder.hasPrefix(root + "/") ? target : nil
    }

    @discardableResult
    private static func save(_ entries: [Entry]) -> Bool {
        guard let target = registryWriteURL else {
            AppLogger.audit(.connectorTested, category: "Mail", fields: [
                "result": "registry_target_outside_managed_folder"
            ], level: .error)
            return false
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries.sorted { $0.email < $1.email })
            try data.write(to: target, options: [.atomic])
            return true
        } catch {
            AppLogger.audit(.connectorTested, category: "Mail", fields: [
                "result": "registry_write_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
            return false
        }
    }
}

/// Connection checks reconstruct only the captured account identity, including
/// its exact OAuth generation. Legacy registry deletion remains a cleanup shim.
enum OutlookMailConnectionAdapter: OutlookMailConnectionTesting {
    @MainActor
    static func testConnection(facts: ConnectorOutlookFacts) async throws -> OutlookConnectionResult {
        let scratch = Connector(name: facts.name, serviceType: facts.serviceType)
        scratch.id = facts.id
        scratch.credentialNamespaceID = facts.credentialNamespaceID
        scratch.configKeys = facts.configKeys
        scratch.configValues = facts.configValues
        if let format = facts.outlookCredentialFormat { scratch.outlookCredentialFormat = format }

        // Diff against configValue(_:) (first-match), not a collapsed dict,
        // so a duplicate config row that the flow never touches doesn't
        // register as "changed" just because its first/last occurrences
        // differ (see this seam's other duplicate-row fix, same file).
        let keysBefore = Set(scratch.configKeys)
        let before = Dictionary(uniqueKeysWithValues: keysBefore.map { ($0, scratch.configValue($0)) })

        let me = try await StanfordOutlookMailGraphService().testConnection(connector: scratch)

        var changed: [String: String] = [:]
        for key in Set(scratch.configKeys) {
            let after = scratch.configValue(key)
            if before[key] != after {
                changed[key] = after
            }
        }
        return OutlookConnectionResult(mail: me.mail, userPrincipalName: me.userPrincipalName, changedConfigEntries: changed)
    }

    @discardableResult
    static func removeFromRegistry(connectorID: UUID) -> Bool {
        StanfordOutlookMailRegistry.remove(connectorID: connectorID)
    }
}
