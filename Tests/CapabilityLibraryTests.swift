import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Library")
struct CapabilityLibraryTests {
    @Test("capability directory is isolated by app channel")
    func channelDirectoriesAreIsolated() {
        let dev = CapabilityLibrary.capabilitiesDirectory(for: .development).path
        let prod = CapabilityLibrary.capabilitiesDirectory(for: .production).path
        let beta = CapabilityLibrary.capabilitiesDirectory(for: .beta).path

        #expect(dev.contains("AstraDev/Capabilities"))
        #expect(prod.contains("Astra/Capabilities"))
        #expect(beta.contains("AstraBeta/Capabilities"))
        #expect(dev != prod)
        #expect(dev != beta)
        #expect(prod != beta)
    }

    @Test("install writes and reloads capability package")
    func installAndLoadPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.bigquery/analyst",
            name: "BigQuery Analyst",
            icon: "folder",
            description: "Analyze BigQuery datasets",
            author: "Stanford",
            category: "Data",
            tags: ["bigquery"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(package)

        let expectedURL = library.packageURL(for: package.id)
        #expect(expectedURL.lastPathComponent == "stanford-bigquery-analyst.json")
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(library.installedVersion(of: package.id) == "1.0.0")
        #expect(library.installedPackage(id: package.id)?.sourceMetadata == .localLibrary())
    }

    @Test("capability library detects package updates")
    func detectsPackageUpdates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-updates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let installed = PluginPackage(
            id: "stanford.bigquery.analyst",
            name: "BigQuery Analyst",
            icon: "folder",
            description: "Analyze BigQuery datasets",
            author: "Stanford",
            category: "Data",
            tags: ["bigquery"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        var newer = installed
        newer.version = "1.1.0"
        var same = installed
        same.version = "1.0.0"

        try library.install(installed)

        #expect(library.hasUpdate(for: newer))
        #expect(!library.hasUpdate(for: same))
    }

    @Test("seed approved packages writes package files and preserves newer local versions")
    func seedApprovedPackages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        var approved = PluginPackage(
            id: "stanford.approved",
            name: "Approved",
            icon: "checkmark.seal",
            description: "Approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.seedApprovedPackages([approved])

        #expect(library.installedPackages().map(\.id) == ["stanford.approved"])
        #expect(library.installedPackage(id: approved.id)?.sourceMetadata == .builtIn())

        approved.version = "0.9.0"
        try library.seedApprovedPackages([approved])
        #expect(library.installedPackage(id: approved.id)?.version == "1.0.0")
    }

    @Test("sync approved packages removes stale built-in packages but keeps local packages")
    func syncApprovedPackages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let kept = PluginPackage(
            id: "stanford.kept",
            name: "Kept",
            icon: "checkmark.seal",
            description: "Approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let staleBuiltIn = PluginPackage(
            id: "stanford.stale",
            name: "Stale",
            icon: "xmark.seal",
            description: "Removed approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let local = PluginPackage(
            id: "stanford.local",
            name: "Local",
            icon: "person",
            description: "User-created capability",
            author: "Stanford",
            category: "Local",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(staleBuiltIn, sourceMetadata: .builtIn())
        try library.install(local, sourceMetadata: .localLibrary())
        try library.syncApprovedPackages([kept])

        let ids = Set(library.installedPackages().map(\.id))
        #expect(ids.contains("stanford.kept"))
        #expect(ids.contains("stanford.local"))
        #expect(!ids.contains("stanford.stale"))
    }

    @Test("bundled approved capability folder exposes repo-maintained packages")
    func bundledApprovedCapabilityFolder() throws {
        let packages = ApprovedCapabilityBundle.packages()
        let expectedIDs: Set<String> = [
            "gcloud-workflow",
            "github-workflow",
            "jira-workflow",
            "security-auditor"
        ]

        #expect(ApprovedCapabilityBundle.bundledDirectory()?.lastPathComponent == "Capabilities")
        #expect(Set(packages.map(\.id)) == expectedIDs)
        #expect(packages.allSatisfy { $0.sourceMetadata == .builtIn() })
        #expect(packages.first { $0.id == "gcloud-workflow" }?.connectors.map(\.name) == ["Google Cloud"])
        #expect(packages.first { $0.id == "github-workflow" }?.connectors.isEmpty == true)
        #expect(packages.first { $0.id == "github-workflow" }?.localTools.map(\.command) == ["gh"])
        #expect(packages.first { $0.id == "github-workflow" }?.prerequisites.map(\.binary) == ["gh", "gh"])
    }

    @Test("local catalog source reads installed capability packages")
    @MainActor
    func localCatalogSourceReadsInstalledPackages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.redcap.qa",
            name: "REDCap QA",
            icon: "checklist",
            description: "Validate REDCap exports",
            author: "Stanford",
            category: "Research",
            tags: ["redcap"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.install(package)

        let source = LocalCapabilityCatalogSource(library: library)
        #expect(source.id == "local")
        #expect(try source.packages().map(\.id) == [package.id])
        #expect(try source.packages().first?.sourceMetadata?.kind == "local")
    }

    @Test("built-in catalog source exposes built-in packages")
    @MainActor
    func builtInCatalogSourceReadsBuiltIns() throws {
        let source = BuiltInCapabilityCatalogSource()
        #expect(source.id == "built-in")
        #expect(try !source.packages().isEmpty)
        #expect(try source.packages().allSatisfy { $0.sourceMetadata == .builtIn() })
    }
}
