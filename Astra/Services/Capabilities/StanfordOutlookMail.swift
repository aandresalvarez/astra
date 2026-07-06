import Foundation
import ASTRACore

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

    static var registryURL: URL {
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

    var hasOutlookRefreshToken: Bool {
        KeychainService.exists(key: StanfordOutlookMail.refreshTokenKey, connectorID: id)
    }

    func applyStanfordOutlookDefaults(defaultTenant: Bool = true) {
        serviceType = StanfordOutlookMail.serviceType
        authMethod = StanfordOutlookMail.authMethod
        icon = "envelope.badge.shield.half.filled"
        baseURL = StanfordOutlookMail.graphBaseURL
        testHTTPMethod = "GET"
        credentialKeys = []
        credentialValues = []
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

    func clearOutlookOAuthState() {
        KeychainService.delete(key: StanfordOutlookMail.accessTokenKey, connectorID: id)
        KeychainService.delete(key: StanfordOutlookMail.refreshTokenKey, connectorID: id)
        KeychainService.delete(key: StanfordOutlookMail.expiresAtKey, connectorID: id)
        setConfigValue(StanfordOutlookMail.tokenUpdatedAtKey, value: "")
        StanfordOutlookMailRegistry.remove(connectorID: id)
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

struct GraphMessageListResponse: Decodable {
    let value: [GraphMessage]
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
        case .invalidResponse:
            return "Microsoft returned an unexpected response."
        }
    }
}

struct StanfordOutlookMailAuthService {
    func startDeviceAuthorization(connector: Connector) async throws -> MicrosoftDeviceCodeResponse {
        let tenant = connector.outlookTenantDomain
        let clientID = connector.outlookClientID
        guard connector.hasConfiguredOutlookTenantDomain else { throw StanfordOutlookMailError.missingTenant }
        guard !clientID.isEmpty else { throw StanfordOutlookMailError.missingClientID }

        let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/devicecode")!
        let response: MicrosoftDeviceCodeResponse = try await postForm(
            url: url,
            fields: [
                "client_id": clientID,
                "scope": connector.configValue(StanfordOutlookMail.scopesKey).isEmpty
                    ? StanfordOutlookMail.scopeString
                    : connector.configValue(StanfordOutlookMail.scopesKey)
            ]
        )
        return response
    }

    func pollForToken(
        connector: Connector,
        deviceCode: MicrosoftDeviceCodeResponse
    ) async throws -> MicrosoftTokenResponse {
        let tenant = connector.outlookTenantDomain
        let clientID = connector.outlookClientID
        guard connector.hasConfiguredOutlookTenantDomain else { throw StanfordOutlookMailError.missingTenant }
        guard !clientID.isEmpty else { throw StanfordOutlookMailError.missingClientID }

        let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))
        var interval = max(deviceCode.interval, 5)

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let token: MicrosoftTokenResponse = try await postForm(
                    url: url,
                    fields: [
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "client_id": clientID,
                        "device_code": deviceCode.deviceCode
                    ]
                )
                try Task.checkCancellation()
                return token
            } catch let error as StanfordOutlookMailError {
                switch error {
                case .oauth(let message) where message.contains("authorization_pending"):
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                case .oauth(let message) where message.contains("slow_down"):
                    interval += 5
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                case .oauth(let message) where message.contains("authorization_declined"):
                    throw StanfordOutlookMailError.authorizationDeclined
                case .oauth(let message) where message.contains("expired_token"):
                    throw StanfordOutlookMailError.expiredDeviceCode
                default:
                    throw error
                }
            }
        }

        throw StanfordOutlookMailError.expiredDeviceCode
    }

    func validAccessToken(connector: Connector) async throws -> String {
        let expiresAt = KeychainService.load(key: StanfordOutlookMail.expiresAtKey, connectorID: connector.id)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        if let accessToken = KeychainService.load(key: StanfordOutlookMail.accessTokenKey, connectorID: connector.id),
           let expiresAt,
           expiresAt.timeIntervalSinceNow > 120 {
            return accessToken
        }
        return try await refreshAccessToken(connector: connector)
    }

    @discardableResult
    func refreshAccessToken(connector: Connector) async throws -> String {
        let tenant = connector.outlookTenantDomain
        let clientID = connector.outlookClientID
        guard connector.hasConfiguredOutlookTenantDomain else { throw StanfordOutlookMailError.missingTenant }
        guard !clientID.isEmpty else { throw StanfordOutlookMailError.missingClientID }
        guard let refreshToken = KeychainService.load(key: StanfordOutlookMail.refreshTokenKey, connectorID: connector.id),
              !refreshToken.isEmpty else {
            throw StanfordOutlookMailError.missingRefreshToken
        }

        let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        let token: MicrosoftTokenResponse = try await postForm(
            url: url,
            fields: [
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": refreshToken,
                "scope": connector.configValue(StanfordOutlookMail.scopesKey).isEmpty
                    ? StanfordOutlookMail.scopeString
                    : connector.configValue(StanfordOutlookMail.scopesKey)
            ]
        )
        saveTokenResponse(token, connector: connector)
        return token.accessToken
    }

    func saveTokenResponse(_ token: MicrosoftTokenResponse, connector: Connector) {
        KeychainService.save(
            key: StanfordOutlookMail.accessTokenKey,
            value: token.accessToken,
            connectorID: connector.id,
            label: "Astra Mail: \(connector.name)"
        )
        if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
            KeychainService.save(
                key: StanfordOutlookMail.refreshTokenKey,
                value: refreshToken,
                connectorID: connector.id,
                label: "Astra Mail: \(connector.name)"
            )
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(max(token.expiresIn, 60)))
        KeychainService.save(
            key: StanfordOutlookMail.expiresAtKey,
            value: String(expiresAt.timeIntervalSince1970),
            connectorID: connector.id,
            label: "Astra Mail: \(connector.name)"
        )
        connector.setConfigValue(StanfordOutlookMail.tokenUpdatedAtKey, value: ISO8601DateFormatter().string(from: Date()))
        connector.setConfigValue(StanfordOutlookMail.scopesKey, value: token.scope ?? StanfordOutlookMail.scopeString)
        StanfordOutlookMailRegistry.upsert(connector: connector)
    }
}

struct StanfordOutlookMailGraphService {
    private let auth = StanfordOutlookMailAuthService()

    func testConnection(connector: Connector) async throws -> GraphMeResponse {
        let me: GraphMeResponse = try await get(
            connector: connector,
            path: "/me",
            queryItems: [
                URLQueryItem(name: "$select", value: "id,displayName,userPrincipalName,mail")
            ],
            preferTextBody: false
        )
        connector.setConfigValue(StanfordOutlookMail.accountIDKey, value: me.id)
        connector.setConfigValue(StanfordOutlookMail.displayNameKey, value: me.displayName ?? "")
        if connector.outlookEmail.isEmpty {
            connector.setConfigValue(
                StanfordOutlookMail.emailKey,
                value: me.mail ?? me.userPrincipalName ?? ""
            )
        }
        StanfordOutlookMailRegistry.upsert(connector: connector)
        return me
    }

    func searchMessages(connector: Connector, query: String, limit: Int = 10) async throws -> [GraphMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = [
            URLQueryItem(name: "$top", value: String(min(max(limit, 1), 25))),
            URLQueryItem(name: "$select", value: "id,subject,from,receivedDateTime,bodyPreview,hasAttachments,webLink")
        ]
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "$search", value: "\"\(trimmed)\""))
        } else {
            items.append(URLQueryItem(name: "$orderby", value: "receivedDateTime desc"))
        }
        let response: GraphMessageListResponse = try await get(
            connector: connector,
            path: "/me/messages",
            queryItems: items,
            preferTextBody: false,
            consistencyLevelEventual: !trimmed.isEmpty
        )
        return response.value
    }

    func message(connector: Connector, id messageID: String) async throws -> GraphMessage {
        let encodedMessageID = urlPathComponent(messageID)
        return try await get(
            connector: connector,
            path: "/me/messages/\(encodedMessageID)",
            queryItems: [
                URLQueryItem(
                    name: "$select",
                    value: "id,subject,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,body,hasAttachments,webLink"
                )
            ],
            preferTextBody: true,
            consistencyLevelEventual: false
        )
    }

    private func get<T: Decodable>(
        connector: Connector,
        path: String,
        queryItems: [URLQueryItem],
        preferTextBody: Bool,
        consistencyLevelEventual: Bool = false
    ) async throws -> T {
        let token = try await auth.validAccessToken(connector: connector)
        var components = URLComponents(string: StanfordOutlookMail.graphBaseURL)!
        components.percentEncodedPath = path
        components.queryItems = queryItems
        guard let url = components.url else { throw StanfordOutlookMailError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if preferTextBody {
            request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
        }
        if consistencyLevelEventual {
            request.setValue("eventual", forHTTPHeaderField: "ConsistencyLevel")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StanfordOutlookMailError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw StanfordOutlookMailError.graph(http.statusCode, message)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
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
        let registryURL = StanfordOutlookMail.registryURL
        let broker = HostFileAccessBroker()
        guard let data = try? broker.readData(
            at: registryURL,
            intent: .astraManagedStorage(root: registryURL.deletingLastPathComponent())
        ) else {
            return []
        }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func upsert(connector: Connector) {
        guard connector.isStanfordOutlookMail else { return }
        var current = entries().filter { $0.connectorID != connector.id.uuidString }
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

    static func remove(connectorID: UUID) {
        save(entries().filter { $0.connectorID != connectorID.uuidString })
    }

    private static func save(_ entries: [Entry]) {
        do {
            let directory = StanfordOutlookMail.registryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries.sorted { $0.email < $1.email })
            try data.write(to: StanfordOutlookMail.registryURL, options: [.atomic])
        } catch {
            AppLogger.audit(.connectorTested, category: "Mail", fields: [
                "result": "registry_write_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
        }
    }
}

private func postForm<T: Decodable>(url: URL, fields: [String: String]) async throws -> T {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = formEncoded(fields).data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw StanfordOutlookMailError.invalidResponse
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    if (200...299).contains(http.statusCode) {
        return try decoder.decode(T.self, from: data)
    }

    if let oauth = try? decoder.decode(MicrosoftOAuthErrorResponse.self, from: data) {
        let description = oauth.errorDescription ?? oauth.error
        throw StanfordOutlookMailError.oauth("\(oauth.error): \(description)")
    }

    let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
    throw StanfordOutlookMailError.graph(http.statusCode, message)
}

private func formEncoded(_ fields: [String: String]) -> String {
    fields
        .map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }
        .joined(separator: "&")
}

private func urlPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/%")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// Registered as the `OutlookMailConnectionSeam`
/// (`ASTRACore/OutlookMailConnectionSeam.swift`) backing implementation.
///
/// Rather than re-deriving `StanfordOutlookMailAuthService`/
/// `StanfordOutlookMailGraphService`'s nested OAuth-refresh-then-Graph-call
/// flow as primitives, this reconstructs a scratch, never-persisted
/// `Connector` from `ConnectorOutlookFacts` and runs the existing flow on it
/// unchanged. This is safe: Keychain entries are addressed by an entity-ID
/// string computed from `id`/`serviceType`/`baseURL`/origin fields (see
/// `KeychainSecretStore.connectorEntityIDs(for:)`), not by Swift object
/// identity, so the scratch connector resolves to the exact same
/// Keychain-stored tokens and `StanfordOutlookMailRegistry` entry as the real
/// one — see `ASTRACore/OutlookMailConnectionSeam.swift`'s header for the
/// full reasoning.
enum OutlookMailConnectionAdapter: OutlookMailConnectionTesting {
    static func testConnection(facts: ConnectorOutlookFacts) async throws -> OutlookConnectionResult {
        let scratch = Connector(name: facts.name, serviceType: facts.serviceType)
        scratch.id = facts.id
        for (key, value) in facts.config {
            scratch.setConfigValue(key, value: value)
        }
        let me = try await StanfordOutlookMailGraphService().testConnection(connector: scratch)
        return OutlookConnectionResult(mail: me.mail, userPrincipalName: me.userPrincipalName, updatedConfig: scratch.config)
    }

    static func removeFromRegistry(connectorID: UUID) {
        StanfordOutlookMailRegistry.remove(connectorID: connectorID)
    }
}
