import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
import ASTRACore

// Phase 5: package update flow. A strictly newer version of an installed
// local package imports as an update (warning, not blocker), returns to
// draft, requires re-approval (the digest changed), and refreshes enabled
// workspace definitions once approved and re-enabled.

private func updateTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func updatePackage(version: String, instructions: String = "v1 behavior") -> PluginPackage {
    var package = PluginPackage(
        id: "updatable-pkg", name: "Updatable", icon: "arrow.up.square", description: "d",
        author: "a", category: "c", tags: [], version: version,
        skills: [PluginSkill(
            name: "Updatable Skill", icon: "star", description: "s",
            allowedTools: ["Read"], disallowedTools: [], customTools: [],
            behaviorInstructions: instructions, environmentKeys: [], environmentValues: []
        )],
        connectors: [], localTools: [], templates: []
    )
    package.governance = .localDraft()
    return package
}

@Suite("Capability Update Validation")
struct CapabilityUpdateValidationTests {

    @Test("Newer version of an installed local package validates as an update warning")
    func newerVersionIsUpdateWarning() {
        let installed = updatePackage(version: "1.0.0")
        let incoming = updatePackage(version: "1.1.0")
        let report = CapabilityPackageValidator.validate(
            package: incoming,
            installedPackages: [installed],
            checkPrerequisites: false
        )
        #expect(report.canInstall)
        #expect(report.warnings.contains { $0.code == .packageUpdate })
        #expect(!report.issues.contains { $0.code == .duplicatePackageID })
    }

    @Test("Same version of an installed package stays blocked")
    func sameVersionStaysBlocked() {
        let installed = updatePackage(version: "1.0.0")
        let incoming = updatePackage(version: "1.0.0")
        let report = CapabilityPackageValidator.validate(
            package: incoming,
            installedPackages: [installed],
            checkPrerequisites: false
        )
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.code == .duplicatePackageID })
    }

    @Test("Older version of an installed package stays blocked")
    func olderVersionStaysBlocked() {
        let installed = updatePackage(version: "2.0.0")
        let incoming = updatePackage(version: "1.0.0")
        let report = CapabilityPackageValidator.validate(
            package: incoming,
            installedPackages: [installed],
            checkPrerequisites: false
        )
        #expect(!report.canInstall)
    }

    @Test("Newer version cannot replace a built-in package")
    func builtInStaysBlocked() {
        var installed = updatePackage(version: "1.0.0")
        installed.sourceMetadata = .builtIn()
        let incoming = updatePackage(version: "9.0.0")
        let report = CapabilityPackageValidator.validate(
            package: incoming,
            installedPackages: [installed],
            checkPrerequisites: false
        )
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.code == .duplicatePackageID })
    }
}

@Suite("Capability Update Round Trip")
@MainActor
struct CapabilityUpdateRoundTripTests {

    @Test("Import of a newer version replaces the file, demands re-approval, and refreshes on enable")
    func updateRoundTrip() throws {
        let root = try updateTempDirectory(named: "astra-update-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let approvalStore = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals", isDirectory: true))
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext
        let workspace = Workspace(name: "Update", primaryPath: root.path)
        context.insert(workspace)

        // v1: install, approve, enable.
        let v1 = updatePackage(version: "1.0.0", instructions: "v1 behavior")
        try library.install(v1, sourceMetadata: .localLibrary())
        let v1Record = try approvalStore.save(
            package: try #require(library.installedPackage(id: v1.id)),
            status: .approved,
            approvedBy: "test",
            reviewNotes: ""
        )
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        let v1Stored = try #require(library.installedPackage(id: v1.id))
        _ = try installer.enable(
            v1Stored,
            in: workspace,
            modelContext: context,
            policyContext: .currentUser(workspace: workspace, approvalRecords: [v1Record])
        )
        let enabledSkill = try #require(try context.fetch(FetchDescriptor<Skill>()).first)
        #expect(enabledSkill.behaviorInstructions == "v1 behavior")

        // v2: import replaces the file and returns the package to draft.
        let v2 = updatePackage(version: "2.0.0", instructions: "v2 behavior")
        let encoder = JSONEncoder()
        let importURL = root.appendingPathComponent("incoming-v2.json")
        try encoder.encode(v2).write(to: importURL)
        let importer = CapabilityPackageImporter(library: library)
        let result = try importer.importFile(at: importURL, checkPrerequisites: false)
        #expect(result.report.warnings.contains { $0.code == .packageUpdate })

        let stored = try #require(library.installedPackage(id: v1.id))
        #expect(stored.version == "2.0.0")
        #expect(stored.governance.approvalStatus == .draft)

        // The v1 approval record no longer matches: v2 must be re-approved.
        let draftDecision = CapabilityCatalogPolicy.decision(
            for: stored,
            context: .currentUser(workspace: workspace, approvalRecords: [v1Record])
        )
        #expect(!draftDecision.canRun)

        let v2Record = try approvalStore.save(
            package: stored,
            status: .approved,
            approvedBy: "test",
            reviewNotes: ""
        )
        let approvedDecision = CapabilityCatalogPolicy.decision(
            for: stored,
            context: .currentUser(workspace: workspace, approvalRecords: [v1Record, v2Record])
        )
        #expect(approvedDecision.canRun)

        // Re-enable (the post-approval refresh path) upserts the v2
        // definitions onto the existing resources instead of duplicating.
        _ = try installer.enable(
            stored,
            in: workspace,
            modelContext: context,
            policyContext: .currentUser(workspace: workspace, approvalRecords: [v1Record, v2Record])
        )
        let skills = try context.fetch(FetchDescriptor<Skill>())
        #expect(skills.count == 1)
        #expect(skills.first?.behaviorInstructions == "v2 behavior")
        #expect(workspace.installedVersion(of: v1.id) == "2.0.0")
    }
}
