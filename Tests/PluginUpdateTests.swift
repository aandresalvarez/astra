import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Plugins 2.0, phase 3: definition changes arrive through a visible Update
/// instead of the retired startup repair, every built-in adds in one step on a
/// fresh store, and `worksOn` is shown before adding.
@Suite("Plugin update and built-ins")
@MainActor
struct PluginUpdateTests {
    @Test("Update rewrites the plugin's skill, records the version, and drops a stale duplicate's activation")
    func updateRefreshesAndPrunes() throws {
        let fixture = try Fixture()
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let pluginSkill = try #require(package.skills.first)
        let workspace = fixture.workspace("Update")

        let current = packageSkill(pluginSkill, package: package, version: "0.0.1", instructions: "Old current instructions")
        let stale = packageSkill(pluginSkill, package: package, version: "0.0.0", instructions: "Stale duplicate instructions")
        fixture.context.insert(current)
        fixture.context.insert(stale)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability(package.id)
            $0.enableGlobalSkill(stale.id.uuidString)
            $0.enableGlobalSkill(current.id.uuidString)
        }
        try fixture.context.save()
        #expect(PluginsSurfacePresentation.makeState([fixture.input(package, workspace: workspace)], query: "")
            .actionNeeded.first?.verb == .update)

        try fixture.service.update(
            package, workspace: workspace, modelContext: fixture.context,
            policyContext: .currentUser(workspace: workspace, approvalRecords: []),
            approvalStore: fixture.approvals, traceID: "update"
        )

        let activation = workspace.capabilityActivation
        #expect(activation.globalSkillIDs == [current.id.uuidString])
        #expect(activation.installedVersion(of: package.id) == package.version)
        #expect(current.behaviorInstructions == pluginSkill.behaviorInstructions)
        #expect(current.originPackageVersion == package.version)
        #expect(stale.behaviorInstructions == "Stale duplicate instructions")
        let row = PluginsSurfacePresentation.makeState([fixture.input(package, workspace: workspace)], query: "").ready.first
        #expect(row?.verb == nil)
    }

    @Test("Update keeps configured values, keeps a workspace account in the workspace, and retires what the new version dropped")
    func updateKeepsSetupAndRetiresDroppedComponents() throws {
        let fixture = try Fixture()
        var v1 = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        v1.version = "1.0.0"
        let workspace = fixture.workspace("Update setup")
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [])
        try fixture.service.add(v1, workspace: workspace, modelContext: fixture.context, policyContext: policy,
                                approvalStore: fixture.approvals, traceID: "v1")
        let other = fixture.workspace("Update setup, other")
        try fixture.service.add(v1, workspace: other, modelContext: fixture.context,
                                policyContext: .currentUser(workspace: other, approvalRecords: fixture.approvals.records()),
                                approvalStore: fixture.approvals, traceID: "v1-other")
        let shared = try #require(try fixture.context.fetch(FetchDescriptor<Connector>()).first { $0.isGlobal && $0.originPackageID == v1.id })
        let projectIndex = try #require(shared.configKeys.firstIndex(of: "GCP_PROJECT"))
        shared.configValues[projectIndex] = "my-project"
        let droppedTool = try #require(v1.localTools.last)

        var v2 = v1
        v2.version = "2.0.0"
        v2.localTools.removeLast()
        try fixture.service.update(v2, workspace: workspace, modelContext: fixture.context, policyContext: policy,
                                   approvalStore: fixture.approvals, traceID: "v2")

        #expect(shared.configValues[projectIndex] == "my-project")
        // The other workspace sharing those records is updated with it.
        #expect(other.capabilityActivation.installedVersion(of: v1.id) == "2.0.0")
        let tool = try #require(try fixture.context.fetch(FetchDescriptor<LocalTool>()).first {
            $0.originPackageID == v1.id && $0.name == droppedTool.name
        })
        #expect(tool.skill == nil)
        #expect(!workspace.capabilityActivation.globalToolIDs.contains(tool.id.uuidString))
        #expect(!other.capabilityActivation.globalToolIDs.contains(tool.id.uuidString))
        #expect(workspace.capabilityActivation.installedVersion(of: v1.id) == "2.0.0")
    }

    @Test("Update leaves a workspace-scoped account in the workspace with its URL")
    func updateKeepsWorkspaceAccount() throws {
        let fixture = try Fixture()
        var v1 = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        v1.version = "1.0.0"
        let workspace = fixture.workspace("Update jira")
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [])
        let connectorName = try #require(v1.connectors.first?.name)
        try fixture.service.add(v1, workspace: workspace, modelContext: fixture.context, policyContext: policy,
                                approvalStore: fixture.approvals,
                                baseURLOverrides: [connectorName: "https://acme.atlassian.net"], traceID: "v1")
        #expect(workspace.connectors.first?.baseURL == "https://acme.atlassian.net")

        var v2 = v1
        v2.version = "2.0.0"
        try fixture.service.update(v2, workspace: workspace, modelContext: fixture.context, policyContext: policy,
                                   approvalStore: fixture.approvals, traceID: "v2")

        #expect(workspace.connectors.count == 1)
        #expect(workspace.connectors.first?.baseURL == "https://acme.atlassian.net")
        #expect(workspace.capabilityActivation.globalConnectorIDs.isEmpty)
    }

    @Test("An added plugin whose library version moved on asks for an update")
    func updateRowCopy() {
        let package = PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" }!
        var input = PluginsSurfacePresentation.Input(
            package: package, isEnabled: true, pendingSteps: 1, isVisible: true, isRemovable: false,
            recordedVersion: "0.0.1"
        )
        var state = PluginsSurfacePresentation.makeState([input], query: "")
        #expect(state.actionNeeded.first?.verb == .update)
        #expect(state.actionNeeded.first?.subtitle.hasPrefix("Update to \(package.version) · 1 step pending") == true)

        input.recordedVersion = package.version
        input.pendingSteps = 0
        state = PluginsSurfacePresentation.makeState([input], query: "")
        #expect(state.ready.first?.verb == nil)
    }

    @Test("Every built-in adds in one step on a fresh store and lands without an Update")
    func everyBuiltInAddsInOneStep() throws {
        let fixture = try Fixture()
        let builtIns = PluginCatalog.builtInPackages
        #expect(builtIns.count == 10)
        for package in builtIns {
            let workspace = fixture.workspace(package.id)
            try fixture.service.add(
                package, workspace: workspace, modelContext: fixture.context,
                policyContext: .currentUser(workspace: workspace, approvalRecords: []),
                approvalStore: fixture.approvals, traceID: "exit-\(package.id)"
            )
            #expect(workspace.capabilityActivation.capabilityIDs == [package.id], "\(package.id) did not add")
            let state = PluginsSurfacePresentation.makeState([fixture.input(package, workspace: workspace)], query: "")
            #expect(state.available.isEmpty && !state.isEmpty, "\(package.id) still listed as available")
            #expect((state.actionNeeded + state.ready).allSatisfy { $0.verb == nil }, "\(package.id) asks for an update")
        }
    }

    @Test("Every built-in's worksOn agrees with the MCP runtime support matrix")
    func worksOnMatchesRuntimeMatrix() throws {
        for package in PluginCatalog.builtInPackages {
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: builtInURL(package.id)))
            for descriptor in AgentRuntimeAdapterRegistry.descriptors {
                let declared = try #require(manifest.worksOn[descriptor.id.rawValue], "\(package.id) misses \(descriptor.id.rawValue)")
                guard !package.mcpServers.isEmpty else {
                    #expect(declared == .full, "\(package.id) on \(descriptor.id.rawValue)")
                    continue
                }
                let expected: PluginRuntimeSupport
                if descriptor.id == .copilotCLI {
                    #expect(MCPRuntimeSupportMatrix.copilotProfile(for: descriptor, supportsAdditionalMCPConfig: true).supportsDelivery)
                    expected = .fullWithRecentCLI
                } else {
                    expected = MCPRuntimeSupportMatrix.profile(for: descriptor).supportsDelivery ? .full : .shellOnly
                }
                #expect(declared == expected, "\(package.id) on \(descriptor.id.rawValue)")
            }
        }
    }

    @Test("Before adding, a row says where the plugin runs")
    func worksOnSummary() {
        #expect(PluginsSurfacePresentation.worksOnSummary(PluginManifestConverter.defaultWorksOn(hasMCP: false))
            == "works on every provider")
        #expect(PluginsSurfacePresentation.worksOnSummary(PluginManifestConverter.defaultWorksOn(hasMCP: true))
            == "full on Claude, Codex, Copilot (recent); shell tools elsewhere")
        #expect(PluginsSurfacePresentation.worksOnSummary([:]) == nil)
    }

    // MARK: - Fixtures

    private func packageSkill(_ pluginSkill: PluginSkill, package: PluginPackage, version: String, instructions: String) -> Skill {
        let skill = Skill(
            name: pluginSkill.name, icon: pluginSkill.icon, skillDescription: pluginSkill.description,
            allowedTools: ["Read"], behaviorInstructions: instructions
        )
        skill.isGlobal = true
        skill.originPackageID = package.id
        skill.originPackageVersion = version
        skill.originComponentID = CapabilityResourceOrigin.componentID(for: pluginSkill)
        skill.originComponentKind = CapabilityResourceComponentKind.skill.rawValue
        return skill
    }

    private func builtInURL(_ id: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities/\(id).json")
    }

    /// A fresh store: an in-memory container, an empty library and an empty
    /// approval store under a temporary folder.
    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let root: URL
        let service: CapabilityCatalogActionService
        let approvals: CapabilityApprovalStore
        var context: ModelContext { container.mainContext }

        init() throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("plugin-update-\(UUID().uuidString)", isDirectory: true)
            service = CapabilityCatalogActionService(library: CapabilityLibrary(directory: root.appendingPathComponent("lib")))
            approvals = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals"))
            Self.retained.append(container)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Containers outlive the test so no SwiftData model is torn down
        /// under a later suite.
        private static var retained: [ModelContainer] = []

        func workspace(_ name: String) -> Workspace {
            let workspace = Workspace(name: name, primaryPath: "/tmp/plugin-update-\(name)")
            context.insert(workspace)
            return workspace
        }

        func input(_ package: PluginPackage, workspace: Workspace) -> PluginsSurfacePresentation.Input {
            let state = CapabilityPackageState(
                package: package, workspace: workspace,
                capabilities: WorkspaceCapabilities(workspace: workspace, globalSkills: [], globalConnectors: [], globalTools: [])
            )
            return PluginsSurfacePresentation.Input(
                package: package, isEnabled: state.isEnabled, pendingSteps: 0, isVisible: true, isRemovable: false,
                recordedVersion: workspace.capabilityActivation.installedVersion(of: package.id)
            )
        }
    }
}
