import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Captured Outlook OAuth refresh", .serialized)
struct OutlookOAuthRefreshTests {
    @Test("Actual refresh uses the exact legacy or generation grant and preserves an omitted refresh token", arguments: [false, true])
    func renewsOnlyCapturedGrant(legacy: Bool) async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(legacy: legacy)
            defer { fixture.removeFiles() }
            let before = PluginAccountRecord(fixture.account)
            let stub = OutlookBackendHTTPStub { request in
                OutlookBackendHTTPStub.json(request, #"{"access_token":"renewed-access","expires_in":3600}"#)
            }
            let token = try await StanfordOutlookMailAuthService(transport: stub).validAccessToken(connector: fixture.account)
            #expect(token == "renewed-access")
            let renewed = try #require(try fixture.load(before))
            #expect(renewed.accessToken == "renewed-access")
            #expect(renewed.refreshToken == "original-refresh")
            #expect(renewed.principalID == "original")
            #expect(PluginAccountRecord(fixture.account) == before)
            let calls = await stub.calls()
            #expect(calls.count == 1)
            let request = try #require(calls.first?.request)
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/tenant.example/oauth2/v2.0/token")
            #expect(request.httpMethod == "POST")
            #expect(String(data: request.httpBody!, encoding: .utf8)?.contains("refresh_token=original-refresh") == true)
            #expect(calls.first?.maximumBytes == 1_024 * 1_024)
            if !legacy {
                for key in OutlookCredentialIdentity.tokenKeys { #expect(KeychainService.load(key: key, connectorID: fixture.account.id) == nil) }
            }
        }
    }

    @Test("A cancelled in-flight refresh retains its lease until settled and never writes the late token")
    func cancellationPreventsLateWrite() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture()
            defer { fixture.removeFiles() }
            let before = PluginAccountRecord(fixture.account)
            let cleanup = fixture.account.keychainCleanup
            let gate = OutlookBackendHTTPGate()
            let stub = OutlookBackendHTTPStub { request in
                await gate.pause() // Deliberately ignores cancellation until released.
                return OutlookBackendHTTPStub.json(request, #"{"access_token":"must-not-save","refresh_token":"must-not-save","expires_in":3600}"#)
            }
            let refresh = Task { try await StanfordOutlookMailAuthService(transport: stub).validAccessToken(connector: fixture.account) }
            do {
                try await gate.waitUntilStarted()
                refresh.cancel()
                #expect(!KeychainService.deleteAll(facts: cleanup.secretFacts, sparing: []))
                await gate.release()
                do { _ = try await refresh.value; Issue.record("Cancelled refresh returned a token") }
                catch is CancellationError {}
                #expect(try fixture.load(before) == fixture.initial)
                #expect(KeychainService.deleteAll(facts: cleanup.secretFacts, sparing: []))
                #expect(try fixture.load(before) == nil)
            } catch {
                refresh.cancel(); await gate.release(); _ = await refresh.result
                throw error
            }
        }
    }

    @Test("A new login during refresh cannot redirect the late token into the current generation")
    func newLoginCannotRetargetRefresh() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture()
            defer { fixture.removeFiles() }
            let accepted = PluginAccountRecord(fixture.account)
            let gate = OutlookBackendHTTPGate()
            let stub = OutlookBackendHTTPStub { request in
                await gate.pause()
                return OutlookBackendHTTPStub.json(request, #"{"access_token":"renewed-original-access","expires_in":3600}"#)
            }
            let refresh = Task { try await StanfordOutlookMailAuthService(transport: stub).validAccessToken(connector: fixture.account) }
            do {
                try await gate.waitUntilStarted()
                let replacement = OutlookOAuthBundle(tenantDomain: "tenant.example", clientID: "synthetic-client", principalID: "replacement",
                    accessToken: "replacement-access", refreshToken: "replacement-refresh", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
                try OutlookAuthorizationEditor.authorize(replacement,
                    identity: .init(id: "replacement", displayName: nil, userPrincipalName: nil, mail: nil), expected: accepted,
                    on: fixture.account, modelContext: fixture.env.context, allowUserInteraction: false)
                let current = PluginAccountRecord(fixture.account)
                #expect(current.credentialNamespaceID != accepted.credentialNamespaceID)
                #expect(!KeychainService.deleteAll(facts: accepted.makeAccount().keychainCleanup.secretFacts, sparing: []))
                await gate.release()
                #expect(try await refresh.value == "renewed-original-access")
                #expect(try fixture.load(current) == replacement)
                #expect(try fixture.load(accepted)?.accessToken == "renewed-original-access")
                #expect(try fixture.load(accepted)?.principalID == "original")
            } catch {
                refresh.cancel(); await gate.release(); _ = await refresh.result
                throw error
            }
        }
    }

    @Test("Two connection checks retain an unknown legacy principal after a successful refresh")
    func legacyUnknownPrincipalRemainsStable() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(legacy: true, knownPrincipal: false)
            defer { fixture.removeFiles() }
            let stub = OutlookBackendHTTPStub { request in
                if request.url?.host == "login.microsoftonline.com" {
                    return OutlookBackendHTTPStub.json(request, #"{"access_token":"renewed-legacy","expires_in":3600}"#)
                }
                return OutlookBackendHTTPStub.json(request, #"{"id":"verified-principal","mail":"legacy@tenant.example"}"#)
            }
            let graph = StanfordOutlookMailGraphService(transport: stub)
            for _ in 0..<2 {
                #expect(try await graph.testConnection(connector: fixture.account).id == "verified-principal")
                #expect(fixture.account.configValue(StanfordOutlookMail.accountIDKey).isEmpty)
            }
            let calls = await stub.calls()
            #expect(calls.filter { $0.request.url?.host == "login.microsoftonline.com" }.count == 1)
            #expect(calls.filter { $0.request.url?.host == "graph.microsoft.com" }.count == 2)
            #expect(try fixture.load(PluginAccountRecord(fixture.account))?.principalID == "")
        }
    }

    @Test("A refused vault save never returns the renewed provider token")
    func refusedSaveIsFailure() async throws {
        let account = Connector(name: "Refused save")
        account.applyStanfordOutlookDefaults()
        account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
        let old = OutlookOAuthBundle(tenantDomain: account.outlookTenantDomain, clientID: "synthetic-client", principalID: "",
            accessToken: "old", refreshToken: "refresh", expiresAt: Date(timeIntervalSince1970: 1))
        let stub = OutlookBackendHTTPStub { request in
            OutlookBackendHTTPStub.json(request, #"{"access_token":"new-but-not-durable","expires_in":3600}"#)
        }
        let auth = StanfordOutlookMailAuthService(transport: stub, sessionFactory: { _ in RefusedOutlookTokenSession(bundle: old) })
        do { _ = try await auth.validAccessToken(connector: account); Issue.record("Returned an unpreserved token") }
        catch StanfordOutlookMailError.credentialWriteFailed {}
    }
}

private final class RefusedOutlookTokenSession: OutlookTokenSession {
    let bundle: OutlookOAuthBundle
    init(bundle: OutlookOAuthBundle) { self.bundle = bundle }
    func load(tenantDomain: String, clientID: String, principalID: String?) throws -> OutlookOAuthBundle? { bundle }
    func save(_ bundle: OutlookOAuthBundle, allowUserInteraction: Bool) throws -> Bool { false }
}
