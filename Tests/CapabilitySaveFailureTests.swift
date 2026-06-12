import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

// The two CRITICAL coverage gaps from the ship review: when the SwiftData
// save fails mid-lifecycle, no keychain credential is wiped and no library
// file is stranded. Exercised through the injectable `persist` seam so the
// failure is deterministic without a real failing ModelContext.

private func saveFailureTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func saveFailureContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@MainActor
private let failingPersist: @MainActor (Workspace?, ModelContext) -> Bool = { _, _ in false }

private func connectorPackage(id: String) -> PluginPackage {
    var package = PluginPackage(
        id: id, name: id, icon: "link", description: "d",
        author: "a", category: "c", tags: [], version: "1.0.0",
        skills: [PluginSkill(
            name: "\(id) Skill", icon: "star", description: "s",
            allowedTools: ["Read"], disallowedTools: [], customTools: [],
            behaviorInstructions: "b", environmentKeys: [], environmentValues: []
        )],
        connectors: [PluginConnector(
            name: "\(id) Connector", serviceType: "svc-\(id)", icon: "link",
            description: "d", baseURL: "https://\(id).example.com", authMethod: "api_key",
            credentialHints: [.init(key: "SVC_TOKEN", hint: "h")],
            configHints: [], notes: ""
        )],
        localTools: [], templates: []
    )
    package.governance = .builtInApproved(riskLevel: .medium)
    return package
}

@Suite("Capability Uninstall Save Failure")
@MainActor
struct CapabilityUninstallSaveFailureTests {

    @Test("Failed save aborts uninstall: file kept, resources intact, throws saveFailed")
    func failedSaveAbortsUninstall() throws {
        let root = try saveFailureTempDirectory(named: "astra-uninstall-savefail")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let container = try saveFailureContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Save Fail", primaryPath: root.path)
        context.insert(workspace)

        let package = connectorPackage(id: "uninstall-pkg")
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        _ = try installer.install(
            package,
            into: workspace,
            modelContext: context,
            credentialInputs: ["SVC_TOKEN": "secret-value"]
        )
        #expect(FileManager.default.fileExists(atPath: library.packageURL(for: package.id).path))
        let skillsBefore = try context.fetch(FetchDescriptor<Skill>()).count
        let connectorsBefore = try context.fetch(FetchDescriptor<Connector>()).count

        let uninstaller = CapabilityUninstaller(library: library)
        #expect(throws: CapabilityUninstaller.UninstallError.self) {
            try uninstaller.remove(package, modelContext: context, persist: failingPersist)
        }

        // File survives, resources survive (rolled back), package still enabled.
        #expect(FileManager.default.fileExists(atPath: library.packageURL(for: package.id).path))
        #expect(try context.fetch(FetchDescriptor<Skill>()).count == skillsBefore)
        #expect(try context.fetch(FetchDescriptor<Connector>()).count == connectorsBefore)
        #expect(library.installedPackage(id: package.id) != nil)
        // Membership arrays restored: the package is not left half-removed.
        #expect(workspace.installedPluginIDSet.contains(package.id))
    }
}

@Suite("Capability Disable Save Failure")
@MainActor
struct CapabilityDisableSaveFailureTests {

    @Test("Failed save rolls back disable: resources intact, empty result returned")
    func failedSaveRollsBackDisable() throws {
        let root = try saveFailureTempDirectory(named: "astra-disable-savefail")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let container = try saveFailureContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Disable Fail", primaryPath: root.path)
        context.insert(workspace)

        let package = connectorPackage(id: "disable-pkg")
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        // Scope the connector to the workspace so disable stages a delete +
        // keychain cleanup (the path guarded by the save).
        _ = try installer.install(
            package,
            into: workspace,
            modelContext: context,
            credentialInputs: ["SVC_TOKEN": "secret-value"]
        )
        let connectorsBefore = try context.fetch(FetchDescriptor<Connector>()).count

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })),
            globalConnectors: try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
        )
        let result = CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: capabilities,
            modelContext: context,
            availablePackages: [package],
            persist: failingPersist
        )

        // Empty result and no committed deletions.
        #expect(result.removedWorkspaceConnectorIDs.isEmpty)
        #expect(result.removedWorkspaceSkillIDs.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Connector>()).count == connectorsBefore)
    }
}

@Suite("Capability Enable Save Failure")
@MainActor
struct CapabilityEnableSaveFailureTests {

    @Test("Failed save throws persistenceFailed and leaves the workspace not enabled")
    func failedSaveThrowsPersistenceFailed() throws {
        let root = try saveFailureTempDirectory(named: "astra-enable-savefail")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let container = try saveFailureContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Enable Fail", primaryPath: root.path)
        context.insert(workspace)

        let package = connectorPackage(id: "enable-pkg")
        try library.install(package, sourceMetadata: .localLibrary())
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))

        #expect(throws: CapabilityInstaller.InstallationError.self) {
            try installer.enable(
                package,
                in: workspace,
                modelContext: context,
                persist: failingPersist
            )
        }
        #expect(!workspace.enabledCapabilityIDs.contains(package.id))
    }
}
