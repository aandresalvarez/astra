import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

actor OutlookBackendHTTPStub: OutlookHTTPTransport {
    struct Call: Sendable { let request: URLRequest; let maximumBytes: Int }
    private var recorded: [Call] = []
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.handler = handler }
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        recorded.append(.init(request: request, maximumBytes: maximumBytes))
        return try await handler(request)
    }
    func calls() -> [Call] { recorded }
    nonisolated static func json(_ request: URLRequest, _ text: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }
}

actor OutlookBackendHTTPGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async throws {
        for _ in 0..<250 {
            if started { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
struct OutlookBackendFixture {
    let env: PluginAddCommitTests.Fixture
    let account: Connector
    let initial: OutlookOAuthBundle
    init(legacy: Bool = false, knownPrincipal: Bool = true, expired: Bool = true) throws {
        env = try PluginAddCommitTests.Fixture(installed: false)
        account = Connector(name: "Backend Outlook")
        account.applyStanfordOutlookDefaults()
        account.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: "tenant.example")
        account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
        if knownPrincipal { account.setConfigValue(StanfordOutlookMail.accountIDKey, value: "original") }
        account.credentialNamespaceID = UUID()
        account.workspace = env.workspace
        if !legacy { account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat }
        env.context.insert(account)
        try env.context.save()
        initial = OutlookOAuthBundle(tenantDomain: "tenant.example", clientID: "synthetic-client",
            principalID: knownPrincipal ? "original" : "", accessToken: "original-access", refreshToken: "original-refresh",
            expiresAt: Date(timeIntervalSince1970: expired ? 1 : 4_000_000_000))
        if legacy {
            for (key, value) in zip(OutlookCredentialIdentity.legacyTokenKeys,
                [initial.accessToken, initial.refreshToken!, String(initial.expiresAt.timeIntervalSince1970)]) {
                try #require(KeychainService.save(key: key, value: value, connectorID: account.id))
            }
        } else {
            let session = try OutlookOAuthVaultSession(reference: .generation(account.credentialNamespaceID!))
            try #require(try session.save(initial))
        }
    }
    func removeFiles() { env.disk.removeFiles() }
    func load(_ record: PluginAccountRecord) throws -> OutlookOAuthBundle? {
        let copy = record.makeAccount()
        let reference = try #require(OutlookCredentialIdentity.resolve(accountID: copy.id,
            credentialNamespaceID: copy.credentialNamespaceID, format: copy.outlookCredentialFormat))
        let session = try OutlookOAuthVaultSession(reference: reference)
        return try session.load(tenantDomain: copy.outlookTenantDomain, clientID: copy.outlookClientID,
            principalID: copy.configValue(StanfordOutlookMail.accountIDKey))
    }
}
