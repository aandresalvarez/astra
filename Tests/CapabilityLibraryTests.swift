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

    @Test("remove deletes local package file")
    func removeDeletesLocalPackageFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-remove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.local.remove",
            name: "Local Remove",
            icon: "trash",
            description: "Local capability",
            author: "Stanford",
            category: "Local",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.install(package)

        let removed = try library.removePackage(id: package.id)

        #expect(removed.id == package.id)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: library.packageURL(for: package.id).path))
    }

    @Test("remove rejects built-in package file")
    func removeRejectsBuiltInPackageFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-remove-builtin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.builtin",
            name: "Built In",
            icon: "lock",
            description: "Built-in capability",
            author: "ASTRA",
            category: "Built In",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.install(package, sourceMetadata: .builtIn())

        do {
            _ = try library.removePackage(id: package.id)
            Issue.record("Built-in package removal should fail")
        } catch let error as CapabilityLibrary.RemovalError {
            #expect(error == .builtInPackage(package.name))
        }

        #expect(library.installedPackage(id: package.id) != nil)
    }

    @Test("catalog refresh does not restore removed local package")
    func catalogRefreshDoesNotRestoreRemovedLocalPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-remove-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let local = PluginPackage(
            id: "stanford.local.refresh",
            name: "Local Refresh",
            icon: "arrow.clockwise",
            description: "Local capability",
            author: "Stanford",
            category: "Local",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let builtIn = PluginPackage(
            id: "stanford.builtin.refresh",
            name: "Built In Refresh",
            icon: "checkmark.seal",
            description: "Built-in capability",
            author: "ASTRA",
            category: "Built In",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(local)
        try library.syncApprovedPackages([builtIn])
        _ = try library.removePackage(id: local.id)
        try library.syncApprovedPackages([builtIn])

        let ids = Set(library.installedPackages().map(\.id))
        #expect(!ids.contains(local.id))
        #expect(ids.contains(builtIn.id))
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
            "redcap-workflow",
            "security-auditor",
            "stanford-outlook-mail"
        ]

        #expect(ApprovedCapabilityBundle.bundledDirectory()?.lastPathComponent == "Capabilities")
        #expect(Set(packages.map(\.id)) == expectedIDs)
        #expect(packages.allSatisfy { $0.sourceMetadata == .builtIn() })
        #expect(packages.first { $0.id == "gcloud-workflow" }?.connectors.map(\.name) == ["Google Cloud"])
        #expect(packages.first { $0.id == "github-workflow" }?.connectors.isEmpty == true)
        #expect(packages.first { $0.id == "github-workflow" }?.localTools.map(\.command) == ["gh"])
        #expect(packages.first { $0.id == "github-workflow" }?.prerequisites.map(\.binary) == ["gh", "gh"])
        #expect(packages.first { $0.id == "redcap-workflow" }?.connectors.map(\.baseURL) == ["https://redcap.stanford.edu/api/"])
        #expect(packages.first { $0.id == "redcap-workflow" }?.connectors.first?.credentialHints.map(\.key) == ["REDCAP_API_TOKEN"])
        #expect(packages.first { $0.id == "stanford-outlook-mail" }?.localTools.map(\.command) == ["stanford-mail"])
    }

    @Test("resource bundle resolver exposes app icon")
    func resourceBundleResolverExposesAppIcon() throws {
        let bundle = AstraResourceBundle.current
        let iconURL = try #require(bundle.url(forResource: "AppIcon", withExtension: "icns"))
        #expect(FileManager.default.fileExists(atPath: iconURL.path))
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
