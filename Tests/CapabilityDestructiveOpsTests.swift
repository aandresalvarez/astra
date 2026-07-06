import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
import ASTRACore

// Phase 4: destructive-operation coverage and the install/uninstall
// resource-kind parity invariant. The parity test exists so the next
// resource kind added to PluginPackage cannot ship install-only the way
// MCP servers originally did: it enables a package containing every kind
// and asserts removal leaves no trace anywhere.

private func destructiveTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDestructiveContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func everyKindPackage(id: String = "every-kind") -> PluginPackage {
    PluginPackage(
        id: id,
        name: "Every Kind",
        icon: "shippingbox",
        description: "Package exercising every installable resource kind",
        author: "Test",
        category: "Test",
        tags: [],
        version: "1.0.0",
        skills: [PluginSkill(
            name: "Every Kind Skill",
            icon: "star",
            description: "skill",
            allowedTools: ["Read"],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "behave",
            environmentKeys: [],
            environmentValues: []
        )],
        connectors: [PluginConnector(
            name: "Every Kind Connector",
            serviceType: "everykind",
            icon: "link",
            description: "connector",
            baseURL: "https://everykind.example.com",
            authMethod: "api_key",
            credentialHints: [.init(key: "EVERYKIND_TOKEN", hint: "token")],
            configHints: [],
            notes: ""
        )],
        localTools: [PluginLocalTool(
            name: "Every Kind Tool",
            description: "tool",
            icon: "terminal",
            toolType: "cli",
            command: "echo",
            arguments: ""
        )],
        mcpServers: [PluginMCPServer(
            id: "every-kind-server",
            displayName: "Every Kind Server",
            transport: .stdio,
            command: "/bin/cat"
        )],
        templates: [PluginTemplate(
            name: "Every Kind Template",
            icon: "doc",
            description: "template",
            mainGoal: "Do {{thing}}",
            beforeGoal: "",
            afterGoal: "",
            mainBudget: 1000,
            beforeBudget: 0,
            afterBudget: 0,
            variablesJSON: "{}",
            passContextToMain: false,
            passContextToAfter: false
        )],
        browserAdapters: [BrowserSiteAdapterID.github],
        governance: .builtInApproved(riskLevel: .medium)
    )
}

@Suite("Capability Resource Kind Parity")
@MainActor
struct CapabilityResourceKindParityTests {

    @Test("Package model has no resource kinds beyond the ones this parity suite exercises")
    func parityCoversAllResourceKinds() {
        // If a new resource-kind array is added to PluginPackage, this count
        // changes and the full-kind parity test below must be extended to
        // install and uninstall it. Do not just bump the number.
        let package = everyKindPackage()
        let exercisedKinds: [Int] = [
            package.skills.count,
            package.connectors.count,
            package.localTools.count,
            package.mcpServers.count,
            package.templates.count,
            package.browserAdapters.count
        ]
        #expect(exercisedKinds.allSatisfy { $0 == 1 })
        #expect(package.contentParts.count == 6)
    }

    @Test("Uninstall reverses everything install created, across multiple workspaces")
    func installUninstallRoundTripLeavesNoTrace() throws {
        let root = try destructiveTempDirectory(named: "astra-parity")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let container = try makeDestructiveContainer()
        let context = container.mainContext
        let first = Workspace(name: "First", primaryPath: root.appendingPathComponent("a").path)
        let second = Workspace(name: "Second", primaryPath: root.appendingPathComponent("b").path)
        context.insert(first)
        context.insert(second)

        let package = everyKindPackage()
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        _ = try installer.install(package, into: first, modelContext: context)
        _ = try installer.enable(package, in: second, modelContext: context)

        #expect(first.enabledCapabilityIDs.contains(package.id))
        #expect(second.enabledCapabilityIDs.contains(package.id))
        #expect(FileManager.default.fileExists(atPath: library.packageURL(for: package.id).path))
        let projectedBefore = MCPRuntimeProjection.enabledServers(
            for: first, packages: [package], approvalRecords: []
        )
        #expect(projectedBefore.count == 1)

        _ = try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        for workspace in [first, second] {
            #expect(!workspace.enabledCapabilityIDs.contains(package.id))
            #expect(!workspace.installedPluginIDSet.contains(package.id))
            #expect(workspace.templates.isEmpty)
            #expect(MCPRuntimeProjection.enabledServers(
                for: workspace, packages: [package], approvalRecords: []
            ).isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: library.packageURL(for: package.id).path))

        let skills = try context.fetch(FetchDescriptor<Skill>())
        let connectors = try context.fetch(FetchDescriptor<Connector>())
        let tools = try context.fetch(FetchDescriptor<LocalTool>())
        #expect(!skills.contains { CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id) })
        #expect(!connectors.contains { CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id) })
        #expect(!tools.contains { CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id) })
    }
}

@Suite("Capability Disable Shared Claims")
@MainActor
struct CapabilityDisableSharedClaimsTests {

    @Test("Disabling one package preserves global resources claimed by another enabled package")
    func disablePreservesSharedClaims() throws {
        let root = try destructiveTempDirectory(named: "astra-shared-claims")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let container = try makeDestructiveContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Shared", primaryPath: root.path)
        context.insert(workspace)

        func sharedSkillPackage(id: String) -> PluginPackage {
            PluginPackage(
                id: id, name: id, icon: "star", description: "d",
                author: "a", category: "c", tags: [], version: "1.0.0",
                skills: [PluginSkill(
                    name: "Shared Skill", icon: "star", description: "s",
                    allowedTools: ["Read"], disallowedTools: [], customTools: [],
                    behaviorInstructions: "b", environmentKeys: [], environmentValues: []
                )],
                connectors: [], localTools: [], templates: [],
                governance: .builtInApproved(riskLevel: .low)
            )
        }

        let alpha = sharedSkillPackage(id: "alpha-pkg")
        let beta = sharedSkillPackage(id: "beta-pkg")
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        _ = try installer.install(alpha, into: workspace, modelContext: context)
        _ = try installer.install(beta, into: workspace, modelContext: context)
        #expect(workspace.enabledGlobalSkillIDs.count == 1)

        func currentCapabilities() throws -> WorkspaceCapabilities {
            WorkspaceCapabilities(
                workspace: workspace,
                globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
            )
        }
        CapabilityActivationDisabler().disable(
            alpha,
            in: workspace,
            capabilities: try currentCapabilities(),
            modelContext: context,
            availablePackages: [alpha, beta]
        )

        // beta still claims the shared skill, so its activation survives.
        #expect(!workspace.enabledCapabilityIDs.contains("alpha-pkg"))
        #expect(workspace.enabledCapabilityIDs.contains("beta-pkg"))
        #expect(workspace.enabledGlobalSkillIDs.count == 1)

        CapabilityActivationDisabler().disable(
            beta,
            in: workspace,
            capabilities: try currentCapabilities(),
            modelContext: context,
            availablePackages: [alpha, beta]
        )
        #expect(workspace.enabledGlobalSkillIDs.isEmpty)
    }
}

@Suite("Capability Lifecycle Matrix")
@MainActor
struct CapabilityLifecycleMatrixTests {

    private func snapshot(
        governance: CapabilityGovernance,
        enabled: Bool,
        workspace: Workspace
    ) -> CapabilityLifecycleSnapshot {
        var package = everyKindPackage(id: "matrix-pkg")
        package.governance = governance
        workspace.enabledCapabilityIDs = enabled ? ["matrix-pkg"] : []
        let context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            isAdmin: true,
            approvalRecords: []
        )
        return CapabilityLifecycleResolver.resolve(
            package: package,
            workspace: workspace,
            capabilities: WorkspaceCapabilities(workspace: workspace),
            context: context
        )
    }

    @Test("Approved + enabled resolves to Active")
    func approvedEnabledIsActive() throws {
        let container = try makeDestructiveContainer()
        let workspace = Workspace(name: "Matrix", primaryPath: "/tmp/matrix")
        container.mainContext.insert(workspace)
        let state = snapshot(governance: .builtInApproved(riskLevel: .low), enabled: true, workspace: workspace)
        #expect(state.canRun)
        #expect(state.stateLabel == "Active")
    }

    @Test("Approved + not enabled resolves to Available with enablement allowed")
    func approvedDisabledIsAvailable() throws {
        let container = try makeDestructiveContainer()
        let workspace = Workspace(name: "Matrix", primaryPath: "/tmp/matrix2")
        container.mainContext.insert(workspace)
        let state = snapshot(governance: .builtInApproved(riskLevel: .low), enabled: false, workspace: workspace)
        #expect(!state.canRun)
        #expect(state.canEnable)
        #expect(state.stateLabel == "Available")
    }

    @Test("Draft package is blocked from running and requires approval")
    func draftIsBlockedAndNeedsApproval() throws {
        let container = try makeDestructiveContainer()
        let workspace = Workspace(name: "Matrix", primaryPath: "/tmp/matrix3")
        container.mainContext.insert(workspace)
        let state = snapshot(governance: .localDraft(), enabled: false, workspace: workspace)
        #expect(!state.canEnable)
        #expect(!state.canRun)
        #expect(state.requiresApproval)
        #expect(!state.blockers.isEmpty)
    }

    @Test("Deprecated package warns and blocks new enablement but keeps running if already enabled")
    func deprecatedSemantics() throws {
        let container = try makeDestructiveContainer()
        let workspace = Workspace(name: "Matrix", primaryPath: "/tmp/matrix4")
        container.mainContext.insert(workspace)
        var deprecated = CapabilityGovernance.builtInApproved(riskLevel: .low)
        deprecated.approvalStatus = .deprecated

        let fresh = snapshot(governance: deprecated, enabled: false, workspace: workspace)
        #expect(!fresh.canEnable)
        #expect(!fresh.warnings.isEmpty)

        let running = snapshot(governance: deprecated, enabled: true, workspace: workspace)
        #expect(running.canRun)
    }
}

@Suite("Capability Health Matrix")
struct CapabilityHealthMatrixTests {

    private let prerequisite = CLIPrerequisite(
        binary: "examplectl",
        displayName: "Example CLI",
        purpose: "Drives the example service.",
        installHint: "brew install examplectl",
        authHint: "Run `examplectl login`."
    )

    private func healthPackage() -> PluginPackage {
        var package = PluginPackage(
            id: "health-pkg", name: "Health", icon: "heart", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: [],
            prerequisites: [prerequisite]
        )
        package.governance = .builtInApproved(riskLevel: .low)
        return package
    }

    @Test("Healthy prerequisite produces no issues")
    func healthyProducesNoIssues() {
        let issues = CapabilityHealthService.prerequisiteIssues(
            for: healthPackage(),
            statuses: [prerequisite.id: .healthy(path: "/usr/local/bin/examplectl", version: "1.0")]
        )
        #expect(issues.isEmpty)
    }

    @Test("Missing binary, unauthenticated, and unresponsive each map to actionable issues")
    func unhealthyStatusesMapToIssues() {
        let package = healthPackage()
        let cases: [(HealthStatus, CapabilityHealthIssue.Kind, String)] = [
            (.missingBinary, .missingBinary, "brew install examplectl"),
            (.unauthenticated(detail: "token expired"), .unauthenticated, "token expired"),
            (.unresponsive(detail: "timed out"), .unresponsive, "timed out")
        ]
        for (status, expectedKind, expectedFragment) in cases {
            let issues = CapabilityHealthService.prerequisiteIssues(
                for: package,
                statuses: [prerequisite.id: status]
            )
            #expect(issues.count == 1)
            #expect(issues.first?.kind == expectedKind)
            #expect(issues.first?.message.contains(expectedFragment) == true)
        }
    }

    @Test("Prerequisite without a probed status yields no issue")
    func unknownStatusYieldsNoIssue() {
        let issues = CapabilityHealthService.prerequisiteIssues(for: healthPackage(), statuses: [:])
        #expect(issues.isEmpty)
    }
}
