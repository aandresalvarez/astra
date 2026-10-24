import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Rehearses the V20 plugin migration on a copy of a real store. Skipped
/// unless `ASTRA_STORE_REHEARSAL_COPY` names a store file to migrate (a copy:
/// the migration is one-way) and `ASTRA_STORE_REHEARSAL_LIBRARY` its
/// capability library directory.
@Suite("Store migration rehearsal")
@MainActor
struct DevStoreMigrationRehearsalTests {
    @Test("A copied store migrates to activations with every plugin and account accounted for")
    func rehearseMigrationOnCopiedStore() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let storePath = environment["ASTRA_STORE_REHEARSAL_COPY"],
              let libraryPath = environment["ASTRA_STORE_REHEARSAL_LIBRARY"] else { return }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: URL(fileURLWithPath: storePath))]
        )
        Self.retained.append(container)
        let context = container.mainContext
        let library = CapabilityLibrary(directory: URL(fileURLWithPath: libraryPath, isDirectory: true))
        let packages = CapabilityRuntimeResourceMatcher.packageDefinitions(library: library)

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        var expected: [UUID: Set<String>] = [:]
        for workspace in workspaces {
            expected[workspace.id] = Set(workspace.legacyInstalledPluginIDs + workspace.legacyEnabledCapabilityIDs)
        }
        let enabledBefore = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, Set($0.legacyEnabledCapabilityIDs)) })
        let connectorIDsBefore = Set(try context.fetch(FetchDescriptor<Connector>()).map(\.id))
        let pluginSkillsBefore = try context.fetch(FetchDescriptor<Skill>()).filter { $0.originPackageID != nil }.count
        print("REHEARSAL before: workspaces=\(workspaces.count) connectors=\(connectorIDsBefore.count) pluginSkills=\(pluginSkillsBefore) needs=\(PluginActivationMigration.needsMigration(modelContext: context))")

        let report = try PluginActivationMigration.migrate(modelContext: context, packages: packages)
        print("REHEARSAL report: \(report)")

        #expect(!PluginActivationMigration.needsMigration(modelContext: context))
        #expect(Set(try context.fetch(FetchDescriptor<Connector>()).map(\.id)) == connectorIDsBefore)
        for workspace in workspaces {
            #expect(Set(workspace.installedPluginIDs).isSuperset(of: expected[workspace.id] ?? []))
            #expect(Set(workspace.enabledCapabilityIDs) == enabledBefore[workspace.id] ?? [])
            let task = AgentTask(title: "Rehearsal", goal: "rehearsal", workspace: workspace)
            let reachable = TaskCapabilityResolver(task: task).allConnectors
            let own = Set(workspace.connectors.map(\.id))
            let bound = Set(workspace.pluginActivations.flatMap(\.bindings).compactMap { $0.account?.id })
            let shared = Set(workspace.enabledGlobalConnectorIDs.compactMap(UUID.init(uuidString:)))
            // A workspace reaches only its own rows, its bindings, or rows it listed itself.
            #expect(reachable.allSatisfy { own.contains($0.id) || bound.contains($0.id) || shared.contains($0.id) })
            print("REHEARSAL workspace \(workspace.name): activations=\(workspace.pluginActivations.map { "\($0.pluginID):\($0.isEnabled):\($0.bindings.count)" }) skills=\(WorkspaceCapabilities(workspace: workspace, packageDefinitions: packages).activeSkills.map(\.name)) connectors=\(reachable.map(\.name))")
        }
    }

    private static var retained: [ModelContainer] = []
}
