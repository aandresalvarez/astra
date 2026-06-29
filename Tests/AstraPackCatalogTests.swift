import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("ASTRA Pack Catalog")
struct AstraPackCatalogTests {
    @Test("built-in pack catalog loads bundled DevOps pack")
    func builtInPackCatalogLoadsBundledDevOpsPack() throws {
        let snapshot = AstraPackCatalog(localStorageRoot: nil).load()

        let entry = try #require(snapshot.entries.first { $0.manifest.id == "astra.pack.devops" })
        #expect(entry.manifest.name == "DevOps Pack")
        #expect(entry.manifest.coreAPIVersion == "1.0")
        #expect(entry.source.kind == .builtIn)
        #expect(entry.source.manifestURL?.lastPathComponent == "devops-pack.json")
    }

    @Test("DevOps pack loads from bundled resources")
    func devOpsPackLoadsFromBundledResources() throws {
        let entry = try Self.bundledDevOpsEntry()
        let manifest = entry.manifest

        #expect(manifest.capabilityPackageIDs == ["github-workflow"])
        #expect(manifest.shelfDefaults.map(\.id) == ["plan", "files"])
        #expect(manifest.shelfDefaults.allSatisfy { $0.kind == "nativeShelf" })
        #expect(manifest.appTemplates.map(\.id) == ["pr-ci-review"])
        #expect(manifest.appTemplates.first?.name == "PR / CI Review")
        #expect(manifest.appTemplates.first?.templateID == "workspace-app.pr-ci-review")
        #expect(manifest.appTemplates.first?.capabilityPackageIDs == ["github-workflow"])
        #expect(manifest.vocabulary["prQueue"] == "PR Queue")
        #expect(manifest.vocabulary["ciReview"] == "CI Review")

        let rootURL = try #require(entry.source.rootURL)
        #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("devops/README.md").path))
        #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("devops/pr-ci-review-template.md").path))
    }

    @Test("DevOps pack profile keeps Files and Plan visible while hiding Browser by default")
    func devOpsPackProfileKeepsFilesAndPlanVisibleAndHidesBrowserByDefault() throws {
        let manifest = try Self.bundledDevOpsEntry().manifest

        let profile = AstraPackProfileResolver.resolve(enabledPacks: [manifest])

        #expect(profile.visibleShelfIDs == Set([.plan, .files]))
        #expect(profile.hiddenShelfIDs == Set([.browser, .query, .appPreview]))
        #expect(profile.capabilityPackageIDsByShelfID[.plan] == ["github-workflow"])
        #expect(profile.capabilityPackageIDsByShelfID[.files] == ["github-workflow"])
        #expect(profile.vocabularyValue(for: "prQueue") == "PR Queue")
        #expect(profile.vocabularyValue(for: "ciReview") == "CI Review")
    }

    @Test("DevOps pack does not widen policy floor")
    func devOpsPackDoesNotWidenPolicyFloor() throws {
        let manifest = try Self.bundledDevOpsEntry().manifest
        let report = AstraPackManifestValidator.validate(manifest)

        #expect(manifest.capabilityPackageIDs == ["github-workflow"])
        #expect(manifest.policyRestrictions.isEmpty)
        #expect(!report.issues.contains { $0.code == .policyWidening })
        #expect(report.blockers.isEmpty)
    }

    @Test("catalog skips invalid pack and reports diagnostic")
    func catalogSkipsInvalidPackAndReportsDiagnostic() throws {
        let root = try Self.makeTemporaryDirectory(named: "invalid-pack")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeManifest(Self.manifest(id: "astra.pack.valid"), to: root.appendingPathComponent("valid.json"))
        try Self.writeManifest(
            Self.manifest(id: "Invalid Pack ID"),
            to: root.appendingPathComponent("invalid.json")
        )

        let snapshot = AstraPackCatalog(builtInDirectory: root, localStorageRoot: nil).load()

        #expect(snapshot.packs.map(\.id) == ["astra.pack.valid"])
        #expect(snapshot.diagnostics.contains {
            $0.code == .invalidManifest
                && $0.source.manifestURL?.lastPathComponent == "invalid.json"
                && $0.validationIssues.contains { $0.code == .invalidPackID }
        })
    }

    @Test("catalog distinguishes unsupported format version from malformed JSON")
    func catalogDistinguishesUnsupportedFormatVersionFromMalformedJSON() throws {
        let root = try Self.makeTemporaryDirectory(named: "format-diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }
        let unsupported = """
        {
          "formatVersion": 2,
          "id": "astra.pack.future",
          "name": "Future Pack",
          "version": "1.0.0",
          "coreAPIVersion": "1.0",
          "description": "Requires a future pack manifest format."
        }
        """
        let malformed = """
        {
          "formatVersion": 1,
          "id": "astra.pack.broken",
        """
        try Data(unsupported.utf8).write(to: root.appendingPathComponent("future.json"))
        try Data(malformed.utf8).write(to: root.appendingPathComponent("broken.json"))

        let snapshot = AstraPackCatalog(builtInDirectory: root, localStorageRoot: nil).load()

        #expect(snapshot.packs.isEmpty)
        #expect(snapshot.diagnostics.contains {
            $0.code == .invalidManifest
                && $0.source.manifestURL?.lastPathComponent == "future.json"
                && $0.validationIssues.contains { $0.code == .unsupportedFormatVersion }
        })
        #expect(snapshot.diagnostics.contains {
            $0.code == .malformedManifest
                && $0.source.manifestURL?.lastPathComponent == "broken.json"
        })
    }

    @Test("duplicate pack IDs resolve deterministically")
    func duplicatePackIDsResolveDeterministically() throws {
        let root = try Self.makeTemporaryDirectory(named: "duplicate-packs")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIns = root.appendingPathComponent("built-ins", isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIns, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        try Self.writeManifest(
            Self.manifest(id: "astra.pack.duplicate", name: "Built-in Duplicate", version: "1.0.0"),
            to: builtIns.appendingPathComponent("built-in.json")
        )
        try Self.writeManifest(
            Self.manifest(id: "astra.pack.duplicate", name: "Local Duplicate", version: "99.0.0"),
            to: local.appendingPathComponent("local.json")
        )

        let snapshot = AstraPackCatalog(builtInDirectory: builtIns, localStorageRoot: local).load()

        #expect(snapshot.packs.map(\.id) == ["astra.pack.duplicate"])
        #expect(snapshot.entries.first?.manifest.name == "Built-in Duplicate")
        #expect(snapshot.entries.first?.source.kind == .builtIn)
        #expect(snapshot.diagnostics.contains {
            $0.code == .duplicatePackID
                && $0.source.kind == .local
                && $0.message.contains("built-in")
        })
    }

    @Test("catalog reads local packs through HostFileAccessBroker")
    func catalogReadsLocalPacksThroughHostFileAccessBroker() throws {
        let root = try Self.makeTemporaryDirectory(named: "local-pack-broker")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        try Self.writeManifest(
            Self.manifest(id: "astra.pack.local", name: "Local Pack"),
            to: local.appendingPathComponent("local.json")
        )
        try Self.writeManifest(
            Self.manifest(id: "astra.pack.escape", name: "Escaped Pack"),
            to: outside.appendingPathComponent("escape.json")
        )
        try FileManager.default.createSymbolicLink(
            at: local.appendingPathComponent("escape.json"),
            withDestinationURL: outside.appendingPathComponent("escape.json")
        )

        let snapshot = AstraPackCatalog(builtInDirectory: nil, localStorageRoot: local).load()

        #expect(snapshot.packs.map(\.id) == ["astra.pack.local"])
        #expect(snapshot.entries.first?.source.kind == .local)
        #expect(!snapshot.packs.map(\.id).contains("astra.pack.escape"))
        #expect(!snapshot.diagnostics.contains {
            $0.source.manifestURL?.lastPathComponent == "escape.json"
        })
    }

    @Test("catalog returns packs in stable identifier order")
    func catalogReturnsPacksInStableIdentifierOrder() throws {
        let root = try Self.makeTemporaryDirectory(named: "stable-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeManifest(Self.manifest(id: "astra.pack.zeta"), to: root.appendingPathComponent("zeta.json"))
        try Self.writeManifest(Self.manifest(id: "astra.pack.alpha"), to: root.appendingPathComponent("alpha.json"))

        let snapshot = AstraPackCatalog(builtInDirectory: root, localStorageRoot: nil).load()

        #expect(snapshot.packs.map(\.id) == ["astra.pack.alpha", "astra.pack.zeta"])
    }

    private static func bundledDevOpsEntry() throws -> AstraPackCatalogEntry {
        let snapshot = AstraPackCatalog(localStorageRoot: nil).load()
        #expect(!snapshot.diagnostics.contains {
            $0.source.manifestURL?.lastPathComponent == "devops-pack.json"
        })
        return try #require(snapshot.entries.first { $0.manifest.id == "astra.pack.devops" })
    }

    private static func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-pack-catalog-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeManifest(_ manifest: AstraPackManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url)
    }

    private static func manifest(
        id: String,
        name: String = "Test Pack",
        version: String = "1.0.0"
    ) -> AstraPackManifest {
        AstraPackManifest(
            id: id,
            name: name,
            version: version,
            coreAPIVersion: "1.0",
            description: "Pack catalog test fixture."
        )
    }
}
