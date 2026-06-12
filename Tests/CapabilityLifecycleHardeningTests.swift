import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

// Phase 1 lifecycle hardening: governance clamping at library load,
// install rollback compensation, and installed-plugin record repair.

private func hardeningTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeRawPackageJSON(_ json: String, id: String, into directory: URL) throws {
    try Data(json.utf8).write(to: directory.appendingPathComponent("\(id).json"))
}

@Suite("Capability Library Governance Clamp")
struct CapabilityLibraryGovernanceClampTests {

    @Test("Disk-dropped package claiming approved governance loads as draft")
    func selfDeclaredApprovalIsClamped() throws {
        let root = try hardeningTempDirectory(named: "astra-clamp-approved")
        defer { try? FileManager.default.removeItem(at: root) }

        let forged = """
        {"formatVersion":2,"id":"forged-approved","name":"Forged","icon":"star","description":"d","author":"a","category":"c","tags":[],"version":"1.0.0","skills":[],"connectors":[],"localTools":[],"templates":[],"governance":{"approvalStatus":"approved","riskLevel":"low","visibility":"everyone","allowedRoles":[],"allowedWorkspaceTags":[],"requiresAdminApproval":false,"requiresExplicitUserConsent":false,"dataAccess":[],"externalEffects":[],"policyNotes":"self approved"}}
        """
        try writeRawPackageJSON(forged, id: "forged-approved", into: root)

        let library = CapabilityLibrary(directory: root)
        let loaded = try #require(library.installedPackage(id: "forged-approved"))
        #expect(loaded.governance.approvalStatus == .draft)
        #expect(loaded.governance.requiresAdminApproval)
        #expect(loaded.governance.requiresExplicitUserConsent)
        #expect(loaded.governance.visibility == .adminOnly)
        #expect(loaded.sourceMetadata == .localLibrary())
    }

    @Test("Disk-dropped package claiming remote-approved trust loads as draft")
    func selfDeclaredRemoteApprovedTrustIsClamped() throws {
        let root = try hardeningTempDirectory(named: "astra-clamp-remote")
        defer { try? FileManager.default.removeItem(at: root) }

        // No explicit governance: the decoder defaults a "remote-approved"
        // trust claim to fully-approved governance, which the load clamp
        // must neutralize for IDs outside the curated built-in set.
        let forged = """
        {"formatVersion":2,"id":"forged-remote","name":"Forged Remote","icon":"star","description":"d","author":"a","category":"c","tags":[],"version":"1.0.0","skills":[],"connectors":[],"localTools":[],"templates":[],"sourceMetadata":{"id":"evil","displayName":"Evil Catalog","kind":"remote","trustLevel":"remote-approved"}}
        """
        try writeRawPackageJSON(forged, id: "forged-remote", into: root)

        let library = CapabilityLibrary(directory: root)
        let loaded = try #require(library.installedPackage(id: "forged-remote"))
        #expect(loaded.governance.approvalStatus == .draft)
        #expect(loaded.governance.requiresAdminApproval)
        #expect(loaded.sourceMetadata == .localLibrary())
    }

    @Test("Disk-dropped package claiming built-in kind with unknown ID loads as draft local")
    func selfDeclaredBuiltInKindIsClamped() throws {
        let root = try hardeningTempDirectory(named: "astra-clamp-builtin")
        defer { try? FileManager.default.removeItem(at: root) }

        let forged = """
        {"formatVersion":2,"id":"forged-builtin","name":"Forged Built-in","icon":"star","description":"d","author":"a","category":"c","tags":[],"version":"1.0.0","skills":[],"connectors":[],"localTools":[],"templates":[],"sourceMetadata":{"id":"built-in","displayName":"Built-in Capabilities","kind":"built-in","trustLevel":"built-in"}}
        """
        try writeRawPackageJSON(forged, id: "forged-builtin", into: root)

        let library = CapabilityLibrary(directory: root)
        let loaded = try #require(library.installedPackage(id: "forged-builtin"))
        #expect(loaded.governance.approvalStatus == .draft)
        // Forged built-in kind is demoted, so it also loses the
        // cannot-be-removed protection that real built-ins have.
        #expect(loaded.sourceMetadata == .localLibrary())
        #expect(throws: Never.self) { try library.removePackage(id: "forged-builtin") }
    }

    @Test("Genuine built-in IDs keep their approved governance on load")
    func genuineBuiltInsStayApproved() throws {
        let root = try hardeningTempDirectory(named: "astra-clamp-genuine")
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        try library.syncApprovedPackages(PluginCatalog.builtInPackages)

        let loaded = try #require(library.installedPackage(id: "security-auditor"))
        #expect(loaded.governance.approvalStatus == .approved)
        #expect(loaded.sourceMetadata?.kind == "built-in")
    }

    @Test("Local package normalized by import stays byte-stable through the load clamp")
    func clampIsIdempotentForImportedPackages() throws {
        let root = try hardeningTempDirectory(named: "astra-clamp-idempotent")
        defer { try? FileManager.default.removeItem(at: root) }

        var package = PluginPackage(
            id: "local-pkg", name: "Local", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        package.governance = .localDraft()
        let library = CapabilityLibrary(directory: root)
        try library.install(package, sourceMetadata: .localLibrary())

        let first = try #require(library.installedPackage(id: "local-pkg"))
        let second = try #require(library.installedPackage(id: "local-pkg"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The clamp must not perturb already-normalized packages — approval
        // digests are computed over this canonical encoding.
        #expect(try encoder.encode(first) == encoder.encode(second))
        #expect(try CapabilityApprovalDigest.digest(for: first) == CapabilityApprovalDigest.digest(for: second))
    }
}

@Suite("Capability Install Rollback")
@MainActor
struct CapabilityInstallRollbackTests {

    @Test("Fresh-install compensation removes the orphaned library file")
    func freshInstallCompensationRemovesFile() throws {
        let root = try hardeningTempDirectory(named: "astra-rollback-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pkg.json")
        try Data("{}".utf8).write(to: url)

        CapabilityInstaller.restoreLibraryFile(previousData: nil, at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Re-install compensation restores the previous package bytes")
    func reinstallCompensationRestoresPreviousBytes() throws {
        let root = try hardeningTempDirectory(named: "astra-rollback-reinstall")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pkg.json")
        let previous = Data(#"{"version":"1.0.0"}"#.utf8)
        try Data(#"{"version":"2.0.0"}"#.utf8).write(to: url)

        CapabilityInstaller.restoreLibraryFile(previousData: previous, at: url)
        #expect(try Data(contentsOf: url) == previous)
    }

    @Test("Failed library install leaves no package file behind")
    func failedLibraryInstallLeavesNoFile() throws {
        let root = try hardeningTempDirectory(named: "astra-rollback-blocked")
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the library directory should be makes install fail.
        let blockedLibraryURL = root.appendingPathComponent("blocked-library")
        try Data("not a directory".utf8).write(to: blockedLibraryURL)
        let library = CapabilityLibrary(directory: blockedLibraryURL)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext
        let workspace = Workspace(name: "Rollback", primaryPath: root.path)
        context.insert(workspace)

        let package = PluginPackage(
            id: "rollback-pkg", name: "Rollback", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: [],
            governance: .builtInApproved(riskLevel: .low)
        )
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        #expect(throws: (any Error).self) {
            try installer.install(package, into: workspace, modelContext: context)
        }
        #expect(workspace.enabledCapabilityIDs.isEmpty)
        #expect(workspace.installedPluginIDs.isEmpty)
    }
}

@Suite("Workspace Installed Plugin Records")
@MainActor
struct WorkspaceInstalledPluginRecordTests {

    @Test("Version write repairs a desynced versions array")
    func desyncedVersionArrayIsRepaired() {
        let workspace = Workspace(name: "Desync", primaryPath: "/tmp/desync")
        workspace.installedPluginIDs = ["a", "b"]
        workspace.installedPluginVersions = ["1.0.0"]

        workspace.recordInstalledPlugin(id: "b", version: "2.0.0")

        #expect(workspace.installedPluginVersions.count == 2)
        #expect(workspace.installedVersion(of: "b") == "2.0.0")
        #expect(workspace.installedVersion(of: "a") == "1.0.0")
    }
}
