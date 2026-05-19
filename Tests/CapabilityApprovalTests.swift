import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Approval")
struct CapabilityApprovalTests {
    @Test("approval record round trips for exact package digest")
    func approvalRecordRoundTripsForExactDigest() throws {
        let (store, root) = makeApprovalStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = makeApprovalPackage()

        let record = try store.save(
            package: package,
            status: .approved,
            approvedBy: "Security",
            reviewNotes: "Reviewed"
        )

        let loaded = try #require(store.record(for: package))
        let expectedDigest = try CapabilityApprovalDigest.digest(for: package)
        #expect(loaded == record)
        #expect(loaded.sourceDigest == expectedDigest)
    }

    @Test("package content changes invalidate previous approval")
    func packageContentChangesInvalidatePreviousApproval() throws {
        let (store, root) = makeApprovalStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = makeApprovalPackage()
        try store.save(package: package, status: .approved, approvedBy: "Security")

        var changed = package
        changed.localTools[0].arguments = "issue list"

        #expect(store.record(for: changed) == nil)
        #expect(try CapabilityApprovalDigest.digest(for: package) != CapabilityApprovalDigest.digest(for: changed))
    }

    @Test("approval digest changes for connector browser adapter and MCP edits")
    func approvalDigestChangesForRuntimeSurfaceEdits() throws {
        let package = makeApprovalPackage()
        let original = try CapabilityApprovalDigest.digest(for: package)

        var connectorChanged = package
        connectorChanged.connectors = [
            PluginConnector(
                name: "Jira",
                serviceType: "jira",
                icon: "list.clipboard",
                description: "Jira connector",
                baseURL: "https://jira.example.com",
                authMethod: "bearer",
                credentialHints: [.init(key: "JIRA_TOKEN", hint: "Jira token")],
                configHints: [],
                notes: ""
            )
        ]

        var browserChanged = package
        browserChanged.browserAdapters = [BrowserSiteAdapterID.github]

        var mcpChanged = package
        mcpChanged.mcpServers = [
            PluginMCPServer(
                id: "github",
                displayName: "GitHub MCP",
                transport: .stdio,
                command: "github-mcp-server",
                arguments: ["stdio"],
                allowedTools: ["issues.list"]
            )
        ]

        #expect(try CapabilityApprovalDigest.digest(for: connectorChanged) != original)
        #expect(try CapabilityApprovalDigest.digest(for: browserChanged) != original)
        #expect(try CapabilityApprovalDigest.digest(for: mcpChanged) != original)
    }

    @Test("approval digest ignores source last refreshed timestamp")
    func approvalDigestIgnoresSourceLastRefreshedTimestamp() throws {
        var first = makeApprovalPackage()
        first.sourceMetadata = CapabilitySourceMetadata(
            id: "catalog",
            displayName: "Catalog",
            kind: "local",
            trustLevel: "local",
            lastRefreshedAt: Date(timeIntervalSince1970: 100)
        )
        var second = first
        second.sourceMetadata?.lastRefreshedAt = Date(timeIntervalSince1970: 200)

        #expect(try CapabilityApprovalDigest.digest(for: first) == CapabilityApprovalDigest.digest(for: second))
    }

    @Test("approval store default directories are channel-specific")
    func approvalStoreDirectoriesAreChannelSpecific() {
        let dev = CapabilityApprovalStore.approvalsDirectory(for: .development).path
        let prod = CapabilityApprovalStore.approvalsDirectory(for: .production).path

        #expect(dev.contains("AstraDev/CapabilityApprovals"))
        #expect(prod.contains("Astra/CapabilityApprovals"))
        #expect(dev != prod)
    }
}

private func makeApprovalStore() -> (CapabilityApprovalStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-capability-approvals-\(UUID().uuidString)", isDirectory: true)
    return (CapabilityApprovalStore(directory: root), root)
}

private func makeApprovalPackage() -> PluginPackage {
    PluginPackage(
        id: "approval-package",
        name: "Approval Package",
        icon: "puzzlepiece.extension",
        description: "Approval test",
        author: "Tests",
        category: "Tests",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [
            PluginLocalTool(
                name: "GitHub",
                description: "GitHub CLI",
                icon: "terminal",
                toolType: "cli",
                command: "gh",
                arguments: ""
            )
        ],
        templates: [],
        governance: .localDraft()
    )
}
