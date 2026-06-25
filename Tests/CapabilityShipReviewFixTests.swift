import Testing
import Foundation
import ASTRACore
@testable import ASTRA

// Ship-review fix batch: MCP environment-key gating, MCP name grammar,
// always-strict Claude config, legacy env denylist, built-in governance
// from curated definitions, existence-aware install rollback, and the
// coverage gaps the review flagged as cheaply closeable.

private func fixBatchTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("MCP Environment Key Gating")
struct MCPEnvironmentKeyGatingTests {

    private func packageWithServer(
        envKeys: [String],
        declaredConnectorKeys: [String] = [],
        declaredSkillKeys: [String] = []
    ) -> PluginPackage {
        var package = PluginPackage(
            id: "env-pkg", name: "Env", icon: "key", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: declaredSkillKeys.isEmpty ? [] : [PluginSkill(
                name: "Env Skill", icon: "star", description: "s",
                allowedTools: ["Read"], disallowedTools: [], customTools: [],
                behaviorInstructions: "b",
                environmentKeys: declaredSkillKeys,
                environmentValues: declaredSkillKeys.map { _ in "" }
            )],
            connectors: declaredConnectorKeys.isEmpty ? [] : [PluginConnector(
                name: "Env Connector", serviceType: "envsvc", icon: "link",
                description: "d", baseURL: "https://env.example.com", authMethod: "api_key",
                credentialHints: declaredConnectorKeys.map { .init(key: $0, hint: "h") },
                configHints: [], notes: ""
            )],
            localTools: [],
            mcpServers: [PluginMCPServer(
                id: "env-server", displayName: "Env Server", transport: .stdio,
                command: "/bin/cat", environmentKeys: envKeys
            )],
            templates: []
        )
        package.governance = .builtInApproved(riskLevel: .medium)
        return package
    }

    @Test("Server requesting host secrets it never declared is blocked by the validator")
    func undeclaredKeysBlockValidation() {
        let package = packageWithServer(envKeys: ["AWS_SECRET_ACCESS_KEY"])
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("AWS_SECRET_ACCESS_KEY") })
    }

    @Test("Server requesting keys its package declares passes validation")
    func declaredKeysPassValidation() {
        let package = packageWithServer(
            envKeys: ["ENVSVC_TOKEN"],
            declaredConnectorKeys: ["ENVSVC_TOKEN"]
        )
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(!report.issues.contains { $0.code == .unsafeMCPServer })
    }

    @Test("Catalog policy blocks enabling a package whose server requests undeclared keys")
    func policyBlocksUndeclaredKeys() {
        let package = packageWithServer(envKeys: ["ANTHROPIC_API_KEY"])
        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(isAdmin: true)
        )
        #expect(!decision.canEnable)
    }

    @Test("Projection strips undeclared keys from the rendered config")
    func projectionFiltersUndeclaredKeys() {
        let server = PluginMCPServer(
            id: "env-server", displayName: "Env Server", transport: .stdio,
            command: "/bin/cat", environmentKeys: ["DECLARED_KEY", "GITHUB_TOKEN"]
        )
        let resolved = MCPRuntimeProjection.ResolvedServer(
            packageID: "p", server: server,
            permittedEnvironmentKeys: ["DECLARED_KEY"]
        )
        let data = MCPRuntimeProjection.claudeConfigJSON(
            servers: [resolved],
            availableEnvironment: ["DECLARED_KEY": "projected"]
        )
        let rendered = String(decoding: data ?? Data(), as: UTF8.self)
        #expect(rendered.contains("DECLARED_KEY"))
        #expect(!rendered.contains("GITHUB_TOKEN"))
    }

    @Test("declaredKeys unions connector hints and skill environment keys")
    func declaredKeysUnion() {
        let package = packageWithServer(
            envKeys: [],
            declaredConnectorKeys: ["ENVSVC_TOKEN"],
            declaredSkillKeys: ["ENVSVC_REGION"]
        )
        #expect(MCPEnvironmentKeyPolicy.declaredKeys(in: package) == ["ENVSVC_TOKEN", "ENVSVC_REGION"])
    }
}

@Suite("MCP Permission Name Grammar")
struct MCPPermissionNameGrammarTests {

    @Test("Valid names pass; separators and double underscores are rejected")
    func grammarRules() {
        #expect(MCPEnvironmentKeyPolicy.isValidPermissionName("files"))
        #expect(MCPEnvironmentKeyPolicy.isValidPermissionName("files-v2.beta_1"))
        #expect(!MCPEnvironmentKeyPolicy.isValidPermissionName("bad__id"))
        #expect(!MCPEnvironmentKeyPolicy.isValidPermissionName("has space"))
        #expect(!MCPEnvironmentKeyPolicy.isValidPermissionName(""))
        #expect(!MCPEnvironmentKeyPolicy.isValidPermissionName("-leading"))
    }

    @Test("Validator blocks servers whose id or tool names break permission grammar")
    func validatorBlocksBadNames() {
        var package = PluginPackage(
            id: "grammar-pkg", name: "Grammar", icon: "textformat", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [],
            mcpServers: [PluginMCPServer(
                id: "bad__server", displayName: "Bad", transport: .stdio, command: "/bin/cat"
            )],
            templates: []
        )
        package.governance = .builtInApproved(riskLevel: .low)
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(!report.canInstall)
    }
}

@Suite("Strict MCP Config Always On")
struct StrictMCPConfigTests {

    @Test("allowEmpty renders an inert config so --strict-mcp-config can always apply")
    func emptyConfigRendered() throws {
        let url = try #require(MCPRuntimeProjection.writeClaudeConfig(
            servers: [], taskID: UUID(), allowEmpty: true
        ))
        defer { try? FileManager.default.removeItem(at: url) }
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect(servers.isEmpty)
    }

    @Test("Default behavior still writes nothing for an empty server set")
    func defaultStaysNil() {
        #expect(MCPRuntimeProjection.writeClaudeConfig(servers: [], taskID: UUID()) == nil)
    }

    @Test("allowEmpty falls back to the temp root when the private subdir is blocked")
    func writeFallsBackWhenSubdirBlocked() throws {
        // Block the private subdir by planting a regular file where the
        // directory would be created; the fallback location must still
        // produce a config URL so the strict flag never gets stripped.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-mcp-configs", isDirectory: false)
        let preexisting = FileManager.default.fileExists(atPath: blocker.path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDir)
        guard !preexisting || !isDir.boolValue else {
            // A real config dir already exists on this machine — skip the
            // destructive setup rather than remove the shared directory.
            return
        }
        try? FileManager.default.removeItem(at: blocker)
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let url = MCPRuntimeProjection.writeClaudeConfig(servers: [], taskID: UUID(), allowEmpty: true)
        let resolved = try #require(url)
        defer { try? FileManager.default.removeItem(at: resolved) }
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any])
        #expect((object["mcpServers"] as? [String: Any])?.isEmpty == true)
    }
}

@Suite("Legacy Env Name Denylist")
struct LegacyEnvNameDenylistTests {

    @Test("Process-critical and loader names never export bare")
    func criticalNamesBlocked() {
        for name in ["PATH", "HOME", "SHELL", "TMPDIR", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "ASTRA_CONNECTORS"] {
            #expect(!ConnectorRuntimeProjection.isSafeLegacyEnvName(name), "\(name) must not export bare")
        }
        #expect(ConnectorRuntimeProjection.isSafeLegacyEnvName("JIRA_API_TOKEN"))
        #expect(ConnectorRuntimeProjection.isSafeLegacyEnvName("REDCAP_API_URL"))
    }
}

@Suite("Built-in Governance From Definition")
struct BuiltInGovernanceFromDefinitionTests {

    @Test("Hand-edited built-in JSON cannot weaken or elevate its governance")
    func curatedGovernanceWins() throws {
        let root = try fixBatchTempDirectory(named: "astra-curated-governance")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        try library.syncApprovedPackages(PluginCatalog.builtInPackages)

        // Tamper: rewrite security-auditor's on-disk governance to restricted
        // draft requiring consent — the load must restore curated governance.
        let url = library.packageURL(for: "security-auditor")
        var tampered = try #require(library.installedPackage(id: "security-auditor"))
        tampered.governance = .localDraft()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(tampered).write(to: url)

        let loaded = try #require(library.installedPackage(id: "security-auditor"))
        let curated = try #require(PluginCatalog.builtInPackages.first { $0.id == "security-auditor" })
        #expect(loaded.governance.approvalStatus == curated.governance.approvalStatus)
        #expect(loaded.governance.requiresAdminApproval == curated.governance.requiresAdminApproval)
    }

    @Test("A curated built-in stays removal-protected even if its on-disk kind is tampered to local")
    func tamperedBuiltInKindStaysProtected() throws {
        let root = try fixBatchTempDirectory(named: "astra-tamper-builtin-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        try library.syncApprovedPackages(PluginCatalog.builtInPackages)

        // Tamper the on-disk source metadata to claim local content, which
        // would bypass a kind-based removal guard.
        let url = library.packageURL(for: "security-auditor")
        var tampered = try #require(library.installedPackage(id: "security-auditor"))
        tampered.sourceMetadata = .localLibrary()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(tampered).write(to: url)

        // Removal is gated on the curated ID set, not disk metadata.
        #expect(throws: CapabilityLibrary.RemovalError.self) {
            try library.removePackage(id: "security-auditor")
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Install Rollback Existence Awareness")
@MainActor
struct InstallRollbackExistenceTests {

    @Test("A failed pre-install read of an existing file never deletes it")
    func readFailureDoesNotDelete() throws {
        let root = try fixBatchTempDirectory(named: "astra-rollback-existence")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pkg.json")
        try Data(#"{"version":"2.0.0"}"#.utf8).write(to: url)

        // nil snapshot + file existed: read failed, deletion would destroy
        // the user's previous package. The file must survive.
        CapabilityInstaller.restoreLibraryFile(previousData: nil, fileExistedBefore: true, at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Runtime Support Subtitle Branches")
struct RuntimeSupportSubtitleTests {

    private func descriptor(id: AgentRuntimeID, mcp: Bool) -> AgentRuntimeDescriptor {
        AgentRuntimeDescriptor(
            id: id, displayName: id.rawValue, executableName: id.rawValue,
            installHint: "", authHint: "", defaultModels: ["default"],
            supportsAstraRunProtocol: false, supportsMCPServers: mcp
        )
    }

    @Test("No supporting runtimes yields the not-delivered subtitle")
    func noneSupporting() {
        let subtitle = CapabilityRuntimeSupportPresentation.mcpSupportSubtitle(
            descriptors: [descriptor(id: .codexCLI, mcp: false)]
        )
        #expect(subtitle == "Not delivered to any installed runtime yet")
    }

    @Test("All runtimes supporting yields the all-runtimes subtitle")
    func allSupporting() {
        let subtitle = CapabilityRuntimeSupportPresentation.mcpSupportSubtitle(
            descriptors: [descriptor(id: .claudeCode, mcp: true)]
        )
        #expect(subtitle == "Delivered on all runtimes")
    }
}

@Suite("Update Flow Version Parsing Edge")
struct UpdateFlowVersionParsingTests {

    @Test("Unparseable versions fall back to the duplicate-ID blocker, not the update path")
    func nonSemverStaysBlocked() {
        func pkg(version: String) -> PluginPackage {
            var package = PluginPackage(
                id: "ver-pkg", name: "Ver", icon: "number", description: "d",
                author: "a", category: "c", tags: [], version: version,
                skills: [], connectors: [], localTools: [], templates: []
            )
            package.governance = .localDraft()
            return package
        }
        let report = CapabilityPackageValidator.validate(
            package: pkg(version: "not-a-version"),
            installedPackages: [pkg(version: "1.0.0")],
            checkPrerequisites: false
        )
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.code == .duplicatePackageID })
    }
}
