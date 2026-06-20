import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

// Remaining cheap coverage gaps from the ship review: the browser-bridge
// env namespace guard, PolicySummaryPresentation.mcpServersFactValue branches,
// and the disabler's connector origin-claim decline (skill was covered).

@Suite("Browser Bridge Env Guard")
struct BrowserBridgeEnvGuardTests {

    @Test("Only ASTRA_BROWSER-prefixed keys are allowed; loader/critical names are dropped")
    func namespaceGuard() {
        #expect(AgentRuntimeProcessRunner.isBrowserBridgeEnvKeyAllowed("ASTRA_BROWSER_URL"))
        #expect(AgentRuntimeProcessRunner.isBrowserBridgeEnvKeyAllowed("ASTRA_BROWSER_TOKEN"))
        #expect(AgentRuntimeProcessRunner.isBrowserBridgeEnvKeyAllowed("ASTRA_BROWSER_DEBUG_CAPTURE"))
        #expect(AgentRuntimeProcessRunner.isBrowserBridgeEnvKeyAllowed("ASTRA_BROWSER_REQUIRED_ENGINE"))
        // The trailing underscore is required: a delimiter-less prefix match
        // would let an unrelated future ASTRA_BROWSER* key through.
        for hostile in ["PATH", "HOME", "DYLD_INSERT_LIBRARIES", "ANTHROPIC_API_KEY", "ASTRA_CONNECTORS", "ASTRA_BROWSERX", "ASTRA_BROWSER"] {
            #expect(!AgentRuntimeProcessRunner.isBrowserBridgeEnvKeyAllowed(hostile), "\(hostile) must be dropped")
        }
    }
}

@Suite("MCP Servers Fact Value")
struct MCPServersFactValueTests {

    private func render(_ providerID: AgentRuntimeID) -> ProviderPolicyRender {
        ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: PermissionPolicy.restricted.rawValue,
            allowedTools: [],
            runtimeSupportTools: [],
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
    }

    private func manifest(
        providerID: AgentRuntimeID,
        servers: [RunPermissionManifest.MCPServer]
    ) -> RunPermissionManifest {
        RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "test",
            providerID: providerID,
            providerVersion: nil,
            model: "m",
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: render(providerID),
            workspacePath: "/tmp",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            mcpServers: servers,
            approvalsGranted: []
        )
    }

    private func server(id: String) -> RunPermissionManifest.MCPServer {
        RunPermissionManifest.MCPServer(
            id: id, packageID: "pkg", displayName: id, transport: "stdio", trustLevel: "medium"
        )
    }

    @Test("Empty server set reads None regardless of runtime")
    func emptyReadsNone() {
        #expect(PolicySummaryPresentation.mcpServersFactValue(manifest(providerID: .claudeCode, servers: [])) == "None")
        #expect(PolicySummaryPresentation.mcpServersFactValue(manifest(providerID: .copilotCLI, servers: [])) == "None")
    }

    @Test("Servers on a supporting runtime are listed")
    func supportingRuntimeLists() {
        let value = PolicySummaryPresentation.mcpServersFactValue(
            manifest(providerID: .claudeCode, servers: [server(id: "files")])
        )
        #expect(value.contains("files"))
        #expect(!value.contains("skipped"))

        let copilotValue = PolicySummaryPresentation.mcpServersFactValue(
            manifest(providerID: .copilotCLI, servers: [server(id: "files")])
        )
        #expect(copilotValue.contains("files"))
        #expect(!copilotValue.contains("skipped"))
    }

    @Test("Servers on a non-supporting runtime read as skipped, never active")
    func nonSupportingRuntimeSkips() {
        let value = PolicySummaryPresentation.mcpServersFactValue(
            manifest(providerID: .codexCLI, servers: [server(id: "files"), server(id: "db")])
        )
        #expect(value.contains("2 skipped"))
        #expect(value.contains("doesn't support MCP"))
        #expect(!value.contains("files"))
    }
}

@Suite("Disable Connector Shared Claim")
@MainActor
struct DisableConnectorSharedClaimTests {

    private func disableTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-disable-conn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A connector claimed by another enabled package survives disabling the first")
    func sharedConnectorSurvives() throws {
        let root = try disableTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext
        let workspace = Workspace(name: "Shared Conn", primaryPath: root.path)
        context.insert(workspace)

        func connectorPackage(id: String) -> PluginPackage {
            var package = PluginPackage(
                id: id, name: id, icon: "link", description: "d",
                author: "a", category: "c", tags: [], version: "1.0.0",
                skills: [], connectors: [PluginConnector(
                    name: "Shared Connector", serviceType: "shared-svc", icon: "link",
                    description: "d", baseURL: "https://shared.example.com", authMethod: "api_key",
                    credentialHints: [], configHints: [], notes: ""
                )],
                localTools: [], templates: []
            )
            package.governance = .builtInApproved(riskLevel: .low)
            return package
        }

        let alpha = connectorPackage(id: "alpha-conn")
        let beta = connectorPackage(id: "beta-conn")
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        _ = try installer.install(alpha, into: workspace, modelContext: context)
        _ = try installer.install(beta, into: workspace, modelContext: context)
        let connectorsAfterInstall = try context.fetch(FetchDescriptor<Connector>()).count

        CapabilityActivationDisabler().disable(
            alpha,
            in: workspace,
            capabilities: WorkspaceCapabilities(
                workspace: workspace,
                globalConnectors: try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
            ),
            modelContext: context,
            availablePackages: [alpha, beta]
        )

        // beta still claims the shared connector → it is not deleted.
        #expect(try context.fetch(FetchDescriptor<Connector>()).count == connectorsAfterInstall)
        #expect(!workspace.enabledCapabilityIDs.contains("alpha-conn"))
        #expect(workspace.enabledCapabilityIDs.contains("beta-conn"))
    }

    @Test("Disabling a package with no workspace-scoped resources still persists")
    func globalOnlyDisablePersists() throws {
        let root = try disableTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext
        let workspace = Workspace(name: "Global Only", primaryPath: root.path)
        context.insert(workspace)

        // Skill-only package → installer creates a global skill, no
        // workspace-scoped resource, so disable stages no keychain cleanup.
        var package = PluginPackage(
            id: "global-only", name: "Global Only", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [PluginSkill(
                name: "Global Skill", icon: "star", description: "s",
                allowedTools: ["Read"], disallowedTools: [], customTools: [],
                behaviorInstructions: "b", environmentKeys: [], environmentValues: []
            )],
            connectors: [], localTools: [], templates: []
        )
        package.governance = .builtInApproved(riskLevel: .low)
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        _ = try installer.install(package, into: workspace, modelContext: context)
        #expect(workspace.enabledCapabilityIDs.contains("global-only"))

        var persistCount = 0
        CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: WorkspaceCapabilities(
                workspace: workspace,
                globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
            ),
            modelContext: context,
            availablePackages: [package],
            persist: { _, _ in persistCount += 1; return true }
        )

        // The save runs even though no keychain-backed resource was deleted.
        #expect(persistCount == 1)
        #expect(!workspace.enabledCapabilityIDs.contains("global-only"))
    }
}
