import Testing
import Foundation
@testable import ASTRA
import ASTRACore

private final class CatalogLoadEventRecorder: @unchecked Sendable {
    private(set) var changes: [CapabilityCatalogPersistenceChange] = []
    private var token: NSObjectProtocol?

    func start() {
        token = NotificationCenter.default.addObserver(
            forName: .capabilityCatalogPersistenceChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let change = notification.object as? CapabilityCatalogPersistenceChange else { return }
            self?.changes.append(change)
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

@MainActor
private final class ProductionCatalogReloadHandler: @unchecked Sendable {
    let catalog: PluginCatalog
    let library: CapabilityLibrary
    let workspaceID: UUID
    let sourceRevision = PluginCatalogPresentationSourceRevision()
    private var token: NSObjectProtocol?

    init(catalog: PluginCatalog, library: CapabilityLibrary, workspaceID: UUID = UUID()) {
        self.catalog = catalog
        self.library = library
        self.workspaceID = workspaceID
    }

    func start() {
        token = NotificationCenter.default.addObserver(
            forName: .capabilityCatalogPersistenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let change = notification.object as? CapabilityCatalogPersistenceChange else { return }
                self.sourceRevision.receive(change, workspaceID: self.workspaceID) {
                    self.catalog.loadApprovedCapabilities(
                        library: self.library,
                        announceLibraryMutations: false
                    )
                }
            }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

// Mutation flows (enable/disable/remove/update) are covered on the live path
// in CapabilityInstallerTests, CapabilityLibraryTests, and
// CapabilityCatalogActionServiceTests. This file covers the read-side
// catalog: search matching, approved-package loading, and the curated
// built-in definitions.

// MARK: - Search

@Suite("PluginCatalog Search")
struct PluginCatalogSearchTests {

    @Test("Matches generated content summary fallback")
    func matchesGeneratedContentSummaryFallback() {
        let package = PluginPackage(
            id: "browser-only",
            name: "Drive Browser",
            icon: "globe",
            description: "",
            author: "Test",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: ["google-drive"]
        )

        #expect(package.contentSummary == "1 browser adapter")
        #expect(PluginCatalogSearch.matches(package, query: " BROWSER ADAPTER "))
        #expect(!PluginCatalogSearch.matches(package, query: "jira"))
    }
}

// MARK: - Load

@Suite("PluginCatalog Load")
@MainActor
struct PluginCatalogLoadTests {

    @Test("Approved capability catalog loads from capability folder")
    func approvedCatalogLoadsFromCapabilityFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-approved-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let package = PluginPackage(
            id: "approved-only",
            name: "Approved Only",
            icon: "checkmark.seal",
            description: "Approved folder package",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let library = CapabilityLibrary(directory: root)
        let catalog = PluginCatalog()

        catalog.loadApprovedCapabilities(library: library)
        #expect(catalog.packages.map(\.id).contains("security-auditor"))

        try library.install(package)
        catalog.loadApprovedCapabilities(library: library)
        #expect(catalog.packages.map(\.id).contains("approved-only"))
        #expect(catalog.packages.allSatisfy { FileManager.default.fileExists(atPath: library.packageStorageURL(for: $0.id).path) })
    }

    @Test("approved catalog repair and stale built-in prune emit one global mutation")
    func approvedCatalogPruneEmitsGlobalMutation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-approved-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        var stale = PluginPackage(
            id: "retired-built-in-test",
            name: "Retired Built-in",
            icon: "archivebox",
            description: "Stale curated capability",
            author: "ASTRA",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        stale.sourceMetadata = .builtIn()
        try library.install(stale, sourceMetadata: .builtIn())
        let recorder = CatalogLoadEventRecorder()
        recorder.start()
        let catalog = PluginCatalog()
        let reloadHandler = ProductionCatalogReloadHandler(catalog: catalog, library: library)
        reloadHandler.start()

        catalog.loadApprovedCapabilities(library: library)

        #expect(library.installedPackage(id: stale.id) == nil)
        #expect(recorder.changes == [.global])
        // The repair event is delivered synchronously while the original load
        // is active. Its centralized handler must not assign a second snapshot.
        #expect(catalog.revision == 1)
        #expect(reloadHandler.sourceRevision.persistenceRevision == 1)
    }

    @Test("typed persistence handler reloads once globally and never for workspace-only changes")
    func typedPersistenceHandlerOwnsReloadScope() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-approved-handler-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let catalog = PluginCatalog()
        let workspaceID = UUID()
        let handler = ProductionCatalogReloadHandler(
            catalog: catalog,
            library: library,
            workspaceID: workspaceID
        )
        handler.start()

        CapabilityCatalogPersistenceEvents.post(.global)
        #expect(catalog.revision == 1)
        #expect(handler.sourceRevision.persistenceRevision == 1)

        CapabilityCatalogPersistenceEvents.post(.workspace(workspaceID))
        #expect(catalog.revision == 1)
        #expect(handler.sourceRevision.persistenceRevision == 2)

        CapabilityCatalogPersistenceEvents.post(.workspace(UUID()))
        #expect(catalog.revision == 1)
        #expect(handler.sourceRevision.persistenceRevision == 2)
    }
}

// MARK: - Built-in Package Definitions

@Suite("PluginCatalog Built-ins")
@MainActor
struct PluginCatalogBuiltInTests {

    @Test("Jira capability uses permission probe and current search endpoint")
    func jiraCapabilityGuidesAuthAndSearch() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let skill = try #require(package.skills.first)

        #expect(package.version == "2.0.7")
        #expect(package.description.contains("Docker host-control"))
        #expect(package.description.contains("non-Docker"))
        #expect(package.governance.externalEffects.contains(.externalAPIWrite))
        #expect(package.governance.externalEffects.contains(.ticketMutation))
        #expect(package.governance.policyNotes.contains("non-Docker"))
        #expect(skill.behaviorInstructions.contains("DOCKER HOST-CONTROL RUNS"))
        #expect(skill.behaviorInstructions.contains("First verify auth with operation status"))
        #expect(skill.behaviorInstructions.contains("For configured projects, use operation search_jql"))
        #expect(skill.behaviorInstructions.contains("NON-DOCKER REST RUNS"))
        #expect(skill.behaviorInstructions.contains("/rest/api/3/mypermissions?permissions=BROWSE_PROJECTS"))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/myself"))
        #expect(!skill.behaviorInstructions.contains("CREATE_ISSUES"))
        #expect(skill.behaviorInstructions.contains("operation search_jql"))
        #expect(skill.behaviorInstructions.contains("next_page_token"))
        #expect(skill.behaviorInstructions.contains("/rest/api/3/search/jql?jql="))
        #expect(!skill.behaviorInstructions.contains("If /myself returns 401/403, stop"))
        #expect(skill.behaviorInstructions.contains("Do not request raw method, path, or body inputs"))
        #expect(skill.behaviorInstructions.contains("Do not create, update, comment on, transition, delete"))
    }

    @Test("Security auditor bundled capability version matches fallback catalog")
    func securityAuditorVersionMatchesFallbackCatalog() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "security-auditor" })

        #expect(package.version == "2.0.1")
    }

    @Test("MCP smoke test bundled capability declares governed MCP server")
    func mcpSmokeTestDeclaresGovernedMCPServer() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "mcp-smoke-test" })
        let server = try #require(package.mcpServers.first)
        let prerequisite = try #require(package.prerequisites.first)

        #expect(package.name == "MCP Smoke Test")
        #expect(package.skills.isEmpty)
        #expect(server.id == "smoke")
        #expect(server.transport == .stdio)
        #expect(server.command == "astra-mcp-smoke-server")
        #expect(server.allowedTools == ["smoke.ping"])
        #expect(server.environmentKeys.isEmpty)
        #expect(prerequisite.binary == "astra-mcp-smoke-server")
        #expect(package.governance.approvalStatus == .approved)
        #expect(package.governance.visibility == .hidden)
    }

    @Test("Google Workspace bundled capability is a normal setup-gated integration")
    func googleWorkspaceCapabilityIsNormalSetupGatedIntegration() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == GoogleWorkspaceCapability.packageID })

        #expect(package.name == "Google Workspace")
        #expect(package.category == "Integrations")
        #expect(package.connectors.isEmpty)
        #expect(package.requiresSetup)
        #expect(package.setupRequirements == [
            PluginSetupRequirement(
                id: GoogleWorkspaceCapability.setupRequirementID,
                kind: .oauthAccount,
                displayName: "Google Workspace OAuth account",
                provider: GoogleWorkspaceCapability.connectorBinding,
                required: true,
                notes: "Connect with ASTRA managed OAuth when provisioned, or configure an admin custom OAuth client with a loopback redirect before enabling the capability."
            )
        ])
        #expect(GoogleWorkspaceCapability.usesGoogleWorkspaceOAuthSetup(package))
        #expect(package.mcpServers.map(\.id) == [
            "google_workspace_gmail",
            "google_workspace_drive",
            "google_workspace_calendar"
        ])
        #expect(package.mcpServers.allSatisfy { $0.transport == .http })
        #expect(package.mcpServers.allSatisfy { $0.connectorBindings == [GoogleWorkspaceCapability.connectorBinding] })
        #expect(package.mcpServers.allSatisfy { $0.environmentKeys.isEmpty })
    }

    @Test("DevOps pack references only known capability packages")
    func devOpsPackReferencesOnlyKnownCapabilities() throws {
        let manifest = try Self.bundledDevOpsPackManifest()
        let referencedIDs = Set(
            manifest.capabilityPackageIDs
                + manifest.shelfDefaults.flatMap(\.capabilityPackageIDs)
                + manifest.appTemplates.flatMap(\.capabilityPackageIDs)
        )
        let knownIDs = Set(PluginCatalog.builtInPackages.map(\.id))

        #expect(referencedIDs == ["github-workflow"])
        #expect(referencedIDs.isSubset(of: knownIDs))
    }

    @Test("Built-in packages all have valid versions")
    func builtInVersionsValid() {
        for pkg in PluginCatalog.builtInPackages {
            let ver = SemanticVersion(string: pkg.version)
            #expect(ver != nil, "Package \(pkg.id) has invalid version: \(pkg.version)")
        }
    }

    @Test("Built-in packages have unique IDs")
    func builtInUniqueIDs() {
        let ids = PluginCatalog.builtInPackages.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    private static func bundledDevOpsPackManifest() throws -> AstraPackManifest {
        let snapshot = AstraPackCatalog(localStorageRoot: nil).load()
        return try #require(snapshot.packs.first { $0.id == "astra.pack.devops" })
    }
}
