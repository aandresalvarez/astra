import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Ephemeral sign-in state; it never owns persisted credentials or consults a
/// live account while waiting for Microsoft. Only a verified grant can publish.
@MainActor
final class OutlookSignInSession {
    struct VerifiedAuthorization {
        let bundle: OutlookOAuthBundle
        let identity: GraphMeResponse
        fileprivate init(bundle: OutlookOAuthBundle, identity: GraphMeResponse) { self.bundle = bundle; self.identity = identity }
    }
    private let expected: PluginAccountRecord
    private let context: OutlookOAuthClientContext
    private let auth: StanfordOutlookMailAuthService
    private let graph: StanfordOutlookMailGraphService

    init(account: Connector, transport: any OutlookHTTPTransport = URLSessionOutlookHTTPTransport()) throws {
        expected = PluginAccountRecord(account)
        context = try OutlookOAuthClientContext(account)
        auth = StanfordOutlookMailAuthService(transport: transport)
        graph = StanfordOutlookMailGraphService(transport: transport)
    }
    func start() async throws -> MicrosoftDeviceCodeResponse {
        try await auth.startDeviceAuthorization(context: context)
    }
    func finish(deviceCode: MicrosoftDeviceCodeResponse) async throws -> VerifiedAuthorization {
        let token = try await auth.pollForToken(context: context, deviceCode: deviceCode)
        try Task.checkCancellation()
        guard !token.accessToken.isEmpty, token.expiresIn > 0 else { throw StanfordOutlookMailError.invalidResponse }
        let identity = try await graph.identity(accessToken: token.accessToken)
        try Task.checkCancellation()
        let bundle = OutlookOAuthBundle(tenantDomain: context.tenant, clientID: context.clientID, principalID: identity.id,
            accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
        guard bundle.isSupported else { throw StanfordOutlookMailError.invalidResponse }
        return VerifiedAuthorization(bundle: bundle, identity: identity)
    }
    func publish(_ verified: VerifiedAuthorization, on account: Connector, modelContext: ModelContext, allowUserInteraction: Bool = true) throws {
        try Task.checkCancellation()
        try OutlookAuthorizationEditor.authorize(verified.bundle, identity: verified.identity, expected: expected,
            on: account, modelContext: modelContext, allowUserInteraction: allowUserInteraction)
    }
}
