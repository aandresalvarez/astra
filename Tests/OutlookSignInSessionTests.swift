import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Verified Outlook sign-in session", .serialized)
struct OutlookSignInSessionTests {
    private func stub(identitySucceeds: Bool = true) -> OutlookBackendHTTPStub {
        OutlookBackendHTTPStub { request in
            if request.url?.path.hasSuffix("/devicecode") == true {
                return OutlookBackendHTTPStub.json(request, #"{"device_code":"synthetic-code","user_code":"TEST-CODE","verification_uri":"https://microsoft.com/devicelogin","expires_in":300,"interval":5,"message":"Sign in"}"#)
            }
            if request.url?.host == "login.microsoftonline.com" {
                return OutlookBackendHTTPStub.json(request, #"{"access_token":"verified-new-access","expires_in":3600}"#)
            }
            return OutlookBackendHTTPStub.json(request, identitySucceeds ? #"{"id":"replacement","mail":"replacement@tenant.example"}"# : #"{"error":"synthetic-private-error"}"#,
                status: identitySucceeds ? 200 : 403)
        }
    }

    @Test("Identity is checked before publication; a new login never inherits an old refresh token")
    func verifiesBeforeWriting() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let original = PluginAccountRecord(fixture.account)
            let transport = stub()
            let signIn = try OutlookSignInSession(account: fixture.account, transport: transport)
            let code = try await signIn.start()
            let verified = try await signIn.finish(deviceCode: code)
            #expect(PluginAccountRecord(fixture.account) == original)
            #expect(try fixture.load(original) == fixture.initial)
            #expect(verified.identity.id == "replacement")
            #expect(verified.bundle.refreshToken == nil)
            try signIn.publish(verified, on: fixture.account, modelContext: fixture.env.context, allowUserInteraction: false)
            #expect(fixture.account.credentialNamespaceID != original.credentialNamespaceID)
            #expect(try fixture.load(PluginAccountRecord(fixture.account))?.accessToken == "verified-new-access")
            #expect(try fixture.load(PluginAccountRecord(fixture.account))?.refreshToken == nil)
            #expect(try fixture.load(original) == fixture.initial)
            #expect(fixture.account.hasOutlookAuthorization)
            try OutlookAuthorizationEditor.signOut(fixture.account, modelContext: fixture.env.context)
            #expect(!fixture.account.hasOutlookAuthorization)
            let calls = await transport.calls()
            #expect(calls.map { $0.request.url?.host } == ["login.microsoftonline.com", "login.microsoftonline.com", "graph.microsoft.com"])
            #expect(calls.last?.request.url?.path == "/v1.0/me")
            #expect(calls.last?.request.value(forHTTPHeaderField: "Authorization") == "Bearer verified-new-access")
        }
    }

    @Test("A refused identity check does not alter or replace the current authorization")
    func failedIdentityDoesNotWriteTokens() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let original = PluginAccountRecord(fixture.account)
            let transport = stub(identitySucceeds: false)
            let signIn = try OutlookSignInSession(account: fixture.account, transport: transport)
            let code = try await signIn.start()
            do { _ = try await signIn.finish(deviceCode: code); Issue.record("Published unverified identity") }
            catch StanfordOutlookMailError.graph(let status, let message) {
                #expect(status == 403)
                #expect(!message.contains("synthetic-private-error"))
            }
            #expect(PluginAccountRecord(fixture.account) == original)
            #expect(try fixture.load(original) == fixture.initial)
        }
    }

    @Test("Late completion freezes provider context and refuses edited or deleted owners", arguments: ["edit", "delete"])
    func lateCompletionCannotReplaceOwner(change: String) async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let original = PluginAccountRecord(fixture.account)
            let transport = stub()
            let signIn = try OutlookSignInSession(account: fixture.account, transport: transport)
            let code = try await signIn.start()
            if change == "edit" {
                fixture.account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "edited-client")
                fixture.account.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: "edited.example")
            } else { fixture.env.context.delete(fixture.account) }
            try fixture.env.context.save()
            let verified = try await signIn.finish(deviceCode: code)
            #expect(throws: ConnectorCredentialEditor.Failure.self) {
                try signIn.publish(verified, on: fixture.account, modelContext: fixture.env.context, allowUserInteraction: false)
            }
            #expect(try fixture.load(original) == fixture.initial)
            let calls = await transport.calls()
            let tokenRequest = try #require(calls.first { $0.request.url?.path.hasSuffix("/token") == true }?.request)
            #expect(tokenRequest.url?.path == "/tenant.example/oauth2/v2.0/token")
            #expect(String(data: tokenRequest.httpBody!, encoding: .utf8)?.contains("client_id=synthetic-client") == true)
            #expect(verified.bundle.tenantDomain == "tenant.example")
        }
    }

    @Test("A cancelled sign-in never publishes even after identity verification")
    func cancelledPublicationKeepsOwner() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try OutlookBackendFixture(expired: false)
            defer { fixture.removeFiles() }
            let original = PluginAccountRecord(fixture.account)
            let signIn = try OutlookSignInSession(account: fixture.account, transport: stub())
            let code = try await signIn.start()
            let verified = try await signIn.finish(deviceCode: code)
            let publish = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try signIn.publish(verified, on: fixture.account, modelContext: fixture.env.context, allowUserInteraction: false)
            }
            do { try await publish.value; Issue.record("Cancelled sign-in published") }
            catch is CancellationError {}
            #expect(PluginAccountRecord(fixture.account) == original)
            #expect(try fixture.load(original) == fixture.initial)
        }
    }
}
