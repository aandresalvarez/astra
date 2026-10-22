import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct StanfordOutlookMailAuthService: Sendable {
    let transport: any OutlookHTTPTransport
    private let sessionFactory: @Sendable (OutlookCredentialIdentity.Reference) throws -> any OutlookTokenSession
    init(transport: any OutlookHTTPTransport = URLSessionOutlookHTTPTransport(),
         sessionFactory: @escaping @Sendable (OutlookCredentialIdentity.Reference) throws -> any OutlookTokenSession = { try OutlookOAuthVaultSession(reference: $0) }) {
        self.transport = transport
        self.sessionFactory = sessionFactory
    }

    @MainActor
    func startDeviceAuthorization(connector: Connector) async throws -> MicrosoftDeviceCodeResponse {
        try await startDeviceAuthorization(context: OutlookOAuthClientContext(connector))
    }

    func startDeviceAuthorization(context: OutlookOAuthClientContext) async throws -> MicrosoftDeviceCodeResponse {
        return try await postForm(url: context.oauthURL("devicecode"), fields: ["client_id": context.clientID, "scope": context.scopes])
    }

    @MainActor
    func pollForToken(connector: Connector, deviceCode: MicrosoftDeviceCodeResponse) async throws -> MicrosoftTokenResponse {
        try await pollForToken(context: OutlookOAuthClientContext(connector), deviceCode: deviceCode)
    }

    func pollForToken(context: OutlookOAuthClientContext, deviceCode: MicrosoftDeviceCodeResponse) async throws -> MicrosoftTokenResponse {
        guard !deviceCode.deviceCode.isEmpty, deviceCode.expiresIn > 0 else { throw StanfordOutlookMailError.expiredDeviceCode }
        let url = try context.oauthURL("token")
        let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))
        var interval = max(deviceCode.interval, 5)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let token: MicrosoftTokenResponse = try await postForm(url: url, fields: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": context.clientID,
                    "device_code": deviceCode.deviceCode])
                try Task.checkCancellation()
                return token
            } catch let error as StanfordOutlookMailError {
                switch error {
                case .oauth("authorization_pending"): break
                case .oauth("slow_down"): interval += 5
                case .oauth("authorization_declined"): throw StanfordOutlookMailError.authorizationDeclined
                case .oauth("expired_token"): throw StanfordOutlookMailError.expiredDeviceCode
                default: throw error
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try await Task.sleep(nanoseconds: UInt64(min(Double(interval), remaining) * 1_000_000_000))
            }
        }
        throw StanfordOutlookMailError.expiredDeviceCode
    }

    @MainActor
    func validAccessToken(connector: Connector) async throws -> String {
        try await accessToken(context: OutlookAuthorizationContext(connector))
    }

    @MainActor
    func refreshAccessToken(connector: Connector) async throws -> String {
        try await accessToken(context: OutlookAuthorizationContext(connector), forceRefresh: true)
    }

    func accessToken(context: OutlookAuthorizationContext, forceRefresh: Bool = false) async throws -> String {
        try Task.checkCancellation()
        let session = try sessionFactory(context.reference)
        guard let bundle = try session.load(tenantDomain: context.tenant, clientID: context.clientID, principalID: context.principalID)
        else { throw StanfordOutlookMailError.missingRefreshToken }
        if !forceRefresh, bundle.expiresAt.timeIntervalSinceNow > 120 { return bundle.accessToken }
        guard let refresh = bundle.refreshToken, !refresh.isEmpty else { throw StanfordOutlookMailError.missingRefreshToken }
        let token: MicrosoftTokenResponse = try await postForm(url: context.client.oauthURL("token"), fields: [
            "grant_type": "refresh_token", "client_id": context.clientID, "refresh_token": refresh, "scope": context.scopes])
        try Task.checkCancellation()
        guard !token.accessToken.isEmpty, token.expiresIn > 0 else { throw StanfordOutlookMailError.invalidResponse }
        let renewed = bundle.refreshed(accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
        guard try session.save(renewed, allowUserInteraction: false) else { throw StanfordOutlookMailError.credentialWriteFailed }
        return renewed.accessToken
    }

    private func postForm<T: Decodable>(url: URL, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").data(using: .utf8)
        let (data, http) = try await transport.data(for: request, maximumBytes: 1_024 * 1_024)
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200...299).contains(http.statusCode) else {
            if let error = try? decoder.decode(MicrosoftOAuthErrorResponse.self, from: data),
               ["authorization_pending", "slow_down", "authorization_declined", "expired_token"].contains(error.error) {
                throw StanfordOutlookMailError.oauth(error.error)
            }
            throw StanfordOutlookMailError.graph(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return try decoder.decode(T.self, from: data)
    }
}
