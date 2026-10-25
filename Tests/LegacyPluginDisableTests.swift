import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Legacy plugin Turn off preserves owned resources", .serialized)
struct LegacyPluginDisableTests {
    @Test("The actual Plugins action never deletes an authored namesake or its queued credential")
    func actualActionPreservesAuthoredNamesake() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            try env.disk.library.install(package)
            let skill = Skill(name: package.skills[0].name, environmentVariables: ["API_TOKEN": "accepted-legacy-disable-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            env.workspace.legacyEnabledCapabilityIDs = [package.id]
            env.workspace.legacyInstalledPluginIDs = [package.id]
            env.workspace.legacyInstalledPluginVersions = [package.version]
            let task = AgentTask(title: "Queued legacy namesake", goal: "Keep the accepted authored credential", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            TaskCapabilitySnapshotCapture.capture(for: task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [package])
            env.context.insert(request)
            try env.context.save()
            let namespace = skill.secretNamespaceID
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let before = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            try #require(TaskCapabilityResolver(task: before).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
            try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) == nil)
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            #expect(result.persisted)
            #expect(result.removedWorkspaceSkillIDs.isEmpty)
            let saved = ModelContext(env.context.container)
            #expect(try saved.fetchCount(FetchDescriptor<Skill>()) == 1)
            #expect(!env.workspace.enabledCapabilityIDs.contains(package.id))
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-legacy-disable-token")
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
        }
    }
    @Test("A legitimately pinned legacy skill stays accepted across Turn off, but a new request cannot borrow it")
    func acceptedLegacySelectionHasIndependentAuthority() throws {
        try withLegacySkill { env, package, skill in
            let task = AgentTask(title: "Accepted legacy selection", goal: "Use the accepted credential", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            TaskCapabilitySnapshotCapture.capture(for: task)
            try #require(TaskCapabilityResolver(task: task).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [package])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let before = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            #expect(TaskCapabilityResolver(task: before).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            try #require(result.persisted)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
            #expect(!WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [package]).activeSkills.contains { $0.id == skill.id })
            let future = AgentTask(title: "New legacy request", goal: "Respect Turn off", workspace: env.workspace)
            future.skills = [skill] // A stale selection is not fresh admission.
            env.context.insert(future)
            TaskCapabilitySnapshotCapture.capture(for: future)
            let next = TaskTurnRequest(task: future, messageEventID: UUID(), sequence: 1, pluginDefinitions: [package])
            env.context.insert(next)
            try env.context.save()
            let nextSnapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: next, from: future))
            let nextLaunch = TaskExecutionLaunchSnapshotApplicator.detachedTask(nextSnapshot, from: future)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: nextLaunch)
            #expect(TaskCapabilityResolver(task: nextLaunch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == nil)
        }
    }

    @Test("The accepted pending legacy membership is frozen, independent of later Turn off")
    func legacyMembershipStaysFrozen() throws {
        try withLegacySkill { env, package, _ in
            let task = AgentTask(title: "Accepted legacy membership", goal: "Keep the accepted plugin scope", workspace: env.workspace)
            env.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [package])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            try #require(result.persisted)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            let frozen = try #require(launch.workspace)
            #expect(frozen.enabledCapabilityIDs.contains(package.id))
            #expect(!env.workspace.enabledCapabilityIDs.contains(package.id))
        }
    }

    @Test("The completed Turn off mirror preserves disabled legacy ownership after trusted recovery")
    func legacyOffMirrorKeepsItsOwner() throws {
        try withLegacySkill { env, package, skill in
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            try #require(result.persisted && result.problem == nil)
            let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath))
            let config = try WorkspaceConfigManager.loadConfig(from: url)
            #expect(config.installedPlugins?.contains { $0.id == package.id } == true)
            let own = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            let restored = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: own.mainContext,
                capabilityTrust: .preserveRecordedState).workspace
            try own.mainContext.save()
            #expect(!restored.enabledCapabilityIDs.contains(package.id))
            let row = try #require(restored.skills.first { $0.id == skill.id })
            #expect(row.environmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
            #expect(!WorkspaceCapabilities(workspace: restored, packageDefinitions: [package]).activeSkills.contains { $0.id == row.id })
        }
    }

    @Test("Shared skills with identical names retain independent row identity")
    func sharedNamesDoNotShareEnablement() throws {
        try withLegacySkill { env, _, skill in
            skill.originPackageID = nil
            skill.isGlobal = true
            let other = Skill(name: skill.name)
            other.isGlobal = true
            env.context.insert(other)
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalSkill(other.id.uuidString) }
            try env.context.save()
            let capabilities = WorkspaceCapabilities(workspace: env.workspace, globalSkills: [skill, other])
            let rows = CapabilityCatalogInventory.packages(catalogPackages: [], capabilities: capabilities)
            let first = try #require(rows.first { $0.id == "skill.\(skill.id.uuidString.lowercased())" })
            let second = try #require(rows.first { $0.id == "skill.\(other.id.uuidString.lowercased())" })
            #expect(!CapabilityPackageState(package: first, workspace: env.workspace, capabilities: capabilities).isEnabled)
            #expect(CapabilityPackageState(package: second, workspace: env.workspace, capabilities: capabilities).isEnabled)
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(first, workspace: env.workspace, modelContext: env.context)
            #expect(result.persisted && result.problem == nil)
            #expect(env.workspace.enabledGlobalSkillIDs == [other.id.uuidString])
            #expect(!CapabilityPackageState(package: first, workspace: env.workspace, capabilities: capabilities).isEnabled)
        }
    }

    @Test("An authored namesake remains a distinct managed resource beside its library plugin")
    func authoredNamesakeIsNotHiddenByTheCatalog() throws {
        try withLegacySkill { env, package, skill in
            skill.originPackageID = nil
            try env.context.save()
            let capabilities = WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [package])
            let id = "skill.\(skill.id.uuidString.lowercased())"
            let rows = CapabilityCatalogInventory.packages(catalogPackages: [package], capabilities: capabilities)
            #expect(Set(rows.map(\.id)) == [package.id, id])
            let management = CapabilityGalleryInventory.managementPackages(catalogPackages: [package], capabilities: capabilities,
                workspace: env.workspace)
            #expect(Set(management.map(\.id)) == [package.id, id])
        }
    }

    func withLegacySkill(_ body: (PluginAddCommitTests.Fixture, PluginPackage, Skill) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            try env.disk.library.install(package)
            let skill = Skill(name: package.skills[0].name, environmentVariables: ["API_TOKEN": "accepted-legacy-disable-token"])
            skill.originPackageID = package.id
            skill.originComponentID = CapabilityResourceOrigin.componentID(for: package.skills[0])
            skill.workspace = env.workspace
            env.context.insert(skill)
            env.workspace.legacyEnabledCapabilityIDs = [package.id]
            env.workspace.legacyInstalledPluginIDs = [package.id]
            env.workspace.legacyInstalledPluginVersions = [package.version]
            try env.context.save()
            try body(env, package, skill)
        }
    }

}
