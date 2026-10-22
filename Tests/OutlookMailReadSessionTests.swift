import Foundation
import Testing
import ASTRACore
import ASTRAModels
import HostControlToolSupport
@testable import ASTRA

@MainActor
@Suite("Captured Outlook mail accounts")
struct OutlookMailReadSessionTests {
    private final class Calls { var accounts: [PluginAccountRecord] = [] }

    @Test("A later live login or edit cannot replace a captured account")
    func keepsCapturedAuthorization() async throws {
        let live = account(name: "Original")
        let oldGeneration = UUID()
        live.credentialNamespaceID = oldGeneration
        let captured = PluginAccountRecord(live)
        let calls = Calls()
        let session = try OutlookMailReadSession(accounts: [captured]) { record, _ in
            calls.accounts.append(record)
            return Data("{}".utf8)
        }
        live.credentialNamespaceID = UUID()
        live.name = "Changed later"
        live.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: "other.example")
        let request = try #require(MailReadRequest.parse(["operation": "folders", "account": "Original"]))
        _ = try await session.readMail(request)
        #expect(calls.accounts == [captured])
        #expect(calls.accounts.first?.credentialNamespaceID == oldGeneration)
    }

    @Test("An unrelated account and an ambiguous selector never reach the loader")
    func selectionIsScoped() async throws {
        let a = account(name: "Mailbox"), b = account(name: "Mailbox")
        let calls = Calls()
        let session = try OutlookMailReadSession(accounts: [PluginAccountRecord(a), PluginAccountRecord(b)]) { record, _ in
            calls.accounts.append(record); return Data("{}".utf8)
        }
        for (selector, failure) in [("unapproved", MailReadFailure.unknownAccount), ("Mailbox", .ambiguousAccount)] {
            let request = try #require(MailReadRequest.parse(["operation": "folders", "account": selector]))
            do { _ = try await session.readMail(request); Issue.record("An invalid selector reached the loader") }
            catch { #expect(error as? MailReadFailure == failure) }
        }
        #expect(calls.accounts.isEmpty)
        let exact = try #require(MailReadRequest.parse(["operation": "folders", "account": b.id.uuidString]))
        _ = try await session.readMail(exact)
        #expect(calls.accounts.map(\.id) == [b.id])
    }

    @Test("Account listing exposes only approved metadata and never loads credentials")
    func metadataDoesNotExposeVaultIdentity() async throws {
        let live = account(name: "Approved")
        live.credentialNamespaceID = UUID()
        live.credentialKeys = ["API_TOKEN"]
        live.credentialValues = ["synthetic-secret"]
        let calls = Calls()
        let session = try OutlookMailReadSession(accounts: [PluginAccountRecord(live)], withheldAccounts: 2) { record, _ in
            calls.accounts.append(record); return Data("{}".utf8)
        }
        let request = try #require(MailReadRequest.parse(["operation": "accounts"]))
        let reply = String(decoding: try await session.readMail(request), as: UTF8.self)
        #expect(reply.contains("Approved"))
        for value in ["synthetic-secret", live.credentialNamespaceID!.uuidString, "keychainService", "credentialKeys"] {
            #expect(!reply.contains(value))
        }
        #expect(calls.accounts.isEmpty)
    }

    @Test("Withheld access is reported as missing approval rather than missing configuration")
    func withheldIsNotAnEmptyAccountList() async throws {
        let session = try OutlookMailReadSession(accounts: [], withheldAccounts: 1) { _, _ in Data("{}".utf8) }
        let request = try #require(MailReadRequest.parse(["operation": "accounts"]))
        do { _ = try await session.readMail(request); Issue.record("Withheld accounts appeared absent") }
        catch { #expect(error as? MailReadFailure == .notApproved) }
    }

    private func account(name: String) -> Connector {
        let value = Connector(name: name)
        value.applyStanfordOutlookDefaults()
        value.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
        return value
    }
}
