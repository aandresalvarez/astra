import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// The account editor can be laid out once more after its account's deletion
/// was saved (the confirmation is still closing). A deleted, saved row traps
/// on its array fields, so the editor has to recognize it from the two reads
/// that stay safe. Reading `credentialKeys` here would end the test process.
@MainActor
@Suite("Account editor and a deleted account", .serialized)
struct ConnectorEditorDeletedAccountTests {
    @Test("A deleted account is recognized before and after its deletion is saved")
    func deletedAccountIsRecognized() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = Connector(name: "Synthetic Jira", serviceType: "jira", baseURL: "https://jira.example.test", authMethod: "basic")
        account.isGlobal = true
        account.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        account.credentialValues = ["", ""]
        env.context.insert(account)
        // New accounts are edited as soon as they are inserted.
        #expect(!ConnectorEditorView.isGone(account))
        try env.context.save()
        #expect(!ConnectorEditorView.isGone(account))

        env.context.delete(account)
        #expect(ConnectorEditorView.isGone(account))
        try env.context.save()
        // Saved: the row no longer reports itself deleted, only detached.
        #expect(!account.isDeleted && account.modelContext == nil)
        #expect(ConnectorEditorView.isGone(account))
    }
}
