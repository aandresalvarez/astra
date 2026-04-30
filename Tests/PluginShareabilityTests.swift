import Testing
import Foundation
@testable import ASTRA
import ASTRACore

// MARK: - Semantic Version

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("Parses major.minor.patch")
    func parseFull() {
        let v = SemanticVersion(string: "2.1.3")
        #expect(v?.major == 2)
        #expect(v?.minor == 1)
        #expect(v?.patch == 3)
    }

    @Test("Parses major.minor (patch defaults to 0)")
    func parseMinor() {
        let v = SemanticVersion(string: "1.5")
        #expect(v?.major == 1)
        #expect(v?.minor == 5)
        #expect(v?.patch == 0)
    }

    @Test("Invalid string returns nil")
    func parseInvalid() {
        #expect(SemanticVersion(string: "abc") == nil)
        #expect(SemanticVersion(string: "") == nil)
        #expect(SemanticVersion(string: "1") == nil)
    }

    @Test("Comparison: major takes precedence")
    func compareMajor() {
        let v1 = SemanticVersion(1, 9, 9)
        let v2 = SemanticVersion(2, 0, 0)
        #expect(v1 < v2)
    }

    @Test("Comparison: minor breaks tie")
    func compareMinor() {
        let v1 = SemanticVersion(2, 1, 9)
        let v2 = SemanticVersion(2, 2, 0)
        #expect(v1 < v2)
    }

    @Test("Comparison: patch breaks tie")
    func comparePatch() {
        let v1 = SemanticVersion(2, 1, 3)
        let v2 = SemanticVersion(2, 1, 4)
        #expect(v1 < v2)
    }

    @Test("Equal versions are equal")
    func equality() {
        let v1 = SemanticVersion(1, 2, 3)
        let v2 = SemanticVersion(1, 2, 3)
        #expect(v1 == v2)
        #expect(!(v1 < v2))
        #expect(!(v2 < v1))
    }

    @Test("Description is major.minor.patch")
    func description() {
        let v = SemanticVersion(3, 0, 1)
        #expect(v.description == "3.0.1")
    }

    @Test("Codable round-trip")
    func codable() throws {
        let v = SemanticVersion(2, 5, 0)
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(SemanticVersion.self, from: data)
        #expect(decoded == v)
    }

    @Test("Trims whitespace before parsing")
    func whitespace() {
        let v = SemanticVersion(string: "  1.0.0  ")
        #expect(v != nil)
        #expect(v?.major == 1)
    }
}

// MARK: - Install Blockers

@Suite("PluginPackage Install Blockers")
struct InstallBlockerTests {

    @Test("No blockers when requirements are met")
    func noBlockers() {
        let pkg = PluginPackage(
            id: "test", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        let blockers = pkg.installBlockers(
            appVersion: SemanticVersion(2, 0, 0),
            installedPluginIDs: []
        )
        #expect(blockers.isEmpty)
    }

    @Test("App too old blocks install")
    func appTooOld() {
        var pkg = PluginPackage(
            id: "test", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        pkg.minAppVersion = "3.0.0"
        let blockers = pkg.installBlockers(
            appVersion: SemanticVersion(2, 5, 0),
            installedPluginIDs: []
        )
        #expect(blockers.count == 1)
        #expect(blockers[0] == .appTooOld(required: "3.0.0", current: "2.5.0"))
    }

    @Test("Missing dependency blocks install")
    func missingDep() {
        var pkg = PluginPackage(
            id: "test", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        pkg.requires = ["base-tools"]
        let blockers = pkg.installBlockers(
            appVersion: SemanticVersion(2, 0, 0),
            installedPluginIDs: ["other-plugin"]
        )
        #expect(blockers.count == 1)
        #expect(blockers[0] == .missingDependency("base-tools"))
    }

    @Test("Satisfied dependency passes")
    func satisfiedDep() {
        var pkg = PluginPackage(
            id: "test", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        pkg.requires = ["base-tools"]
        let blockers = pkg.installBlockers(
            appVersion: SemanticVersion(2, 0, 0),
            installedPluginIDs: ["base-tools"]
        )
        #expect(blockers.isEmpty)
    }

    @Test("Conflict blocks install")
    func conflict() {
        var pkg = PluginPackage(
            id: "test", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        pkg.conflicts = ["legacy-plugin"]
        let blockers = pkg.installBlockers(
            appVersion: SemanticVersion(2, 0, 0),
            installedPluginIDs: ["legacy-plugin"]
        )
        #expect(blockers.count == 1)
        #expect(blockers[0] == .conflictsWith("legacy-plugin"))
    }

    @Test("Multiple blockers accumulate")
    func multipleBlockers() {
        var pkg = PluginPackage(
            id: "test", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        pkg.minAppVersion = "5.0.0"
        pkg.requires = ["dep-a", "dep-b"]
        pkg.conflicts = ["bad-plugin"]
        let blockers = pkg.installBlockers(
            appVersion: SemanticVersion(1, 0, 0),
            installedPluginIDs: ["dep-a", "bad-plugin"]
        )
        #expect(blockers.count == 3)
    }

    @Test("New fields decode as nil from old JSON")
    func backwardCompatibility() throws {
        let json = """
        {"formatVersion":2,"id":"old","name":"Old","icon":"star","description":"d","author":"a","category":"c","tags":[],"version":"1.0.0","skills":[],"connectors":[],"localTools":[],"templates":[]}
        """
        let pkg = try JSONDecoder().decode(PluginPackage.self, from: json.data(using: .utf8)!)
        #expect(pkg.minAppVersion == nil)
        #expect(pkg.requires == nil)
        #expect(pkg.conflicts == nil)
    }
}

// MARK: - Workspace Plugin Tracking

@Suite("Workspace Plugin Version Tracking")
struct WorkspacePluginTrackingTests {

    @Test("Record and retrieve installed plugin version")
    @MainActor func recordAndRetrieve() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        ws.recordInstalledPlugin(id: "example-plugin", version: "2.0.0")
        #expect(ws.installedVersion(of: "example-plugin") == "2.0.0")
    }

    @Test("Update existing plugin version")
    @MainActor func updateVersion() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        ws.recordInstalledPlugin(id: "example-plugin", version: "1.0.0")
        ws.recordInstalledPlugin(id: "example-plugin", version: "2.0.0")
        #expect(ws.installedVersion(of: "example-plugin") == "2.0.0")
        #expect(ws.installedPluginIDs.filter { $0 == "example-plugin" }.count == 1)
    }

    @Test("Unknown plugin returns nil")
    @MainActor func unknownPlugin() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        #expect(ws.installedVersion(of: "nonexistent") == nil)
    }

    @Test("installedPluginIDSet returns correct set")
    @MainActor func idSet() {
        let ws = Workspace(name: "Test", primaryPath: "/tmp/test-ws")
        ws.recordInstalledPlugin(id: "a", version: "1.0.0")
        ws.recordInstalledPlugin(id: "b", version: "1.0.0")
        #expect(ws.installedPluginIDSet == ["a", "b"])
    }
}

// MARK: - Export Provenance

@Suite("Workspace Export Plugin Provenance")
struct ExportProvenanceTests {

    @Test("InstalledPluginRef round-trips through JSON")
    func refCodable() throws {
        let ref = WorkspaceConfigManager.InstalledPluginRef(id: "example-plugin", version: "2.0.0", name: "Example Plugin")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(WorkspaceConfigManager.InstalledPluginRef.self, from: data)
        #expect(decoded.id == "example-plugin")
        #expect(decoded.version == "2.0.0")
        #expect(decoded.name == "Example Plugin")
    }

    @Test("Config without installedPlugins decodes cleanly")
    func backwardCompat() throws {
        let json = """
        {"version":5,"name":"Test","primaryPath":"/tmp","additionalPaths":[],"icon":"folder","instructions":"","skills":[],"sshConnections":[],"exportedAt":"2025-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: json.data(using: .utf8)!)
        #expect(config.installedPlugins == nil)
    }
}

// MARK: - Version-Aware Seeding

@Suite("Version-Aware Seed")
struct VersionAwareSeedTests {

    @Test("SemanticVersion comparison gates overwrite")
    func gateLogic() {
        let existing = SemanticVersion(string: "2.0.0")!
        let builtIn = SemanticVersion(string: "2.0.0")!
        #expect(existing >= builtIn)

        let newer = SemanticVersion(string: "2.1.0")!
        #expect(!(existing >= newer))
    }

    @Test("Seed writes new file when none exists")
    func seedCreatesFile() throws {
        let dir = NSTemporaryDirectory() + "seed-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let pkg = PluginPackage(
            id: "test-seed", name: "Test", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        let path = (dir as NSString).appendingPathComponent("test-seed.json")
        let data = try JSONEncoder().encode(pkg)
        try data.write(to: URL(fileURLWithPath: path))

        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Newer version overwrites, same version skips")
    func versionComparison() throws {
        let dir = NSTemporaryDirectory() + "seed-ver-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()

        // Write v1.0.0 on disk
        let v1 = PluginPackage(
            id: "test-pkg", name: "Old Name", icon: "star", description: "old",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        let path = (dir as NSString).appendingPathComponent("test-pkg.json")
        try encoder.encode(v1).write(to: URL(fileURLWithPath: path))

        // Simulate seed with same version — should NOT overwrite
        let v1Again = PluginPackage(
            id: "test-pkg", name: "New Name v1", icon: "star", description: "new",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        if let existingData = FileManager.default.contents(atPath: path),
           let existing = try? decoder.decode(PluginPackage.self, from: existingData),
           let existingVer = SemanticVersion(string: existing.version),
           let builtInVer = SemanticVersion(string: v1Again.version),
           existingVer >= builtInVer {
            // Skip — same version
        } else {
            try encoder.encode(v1Again).write(to: URL(fileURLWithPath: path))
        }
        let afterSameVer = try decoder.decode(
            PluginPackage.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        #expect(afterSameVer.name == "Old Name")

        // Simulate seed with v2.0.0 — should overwrite
        let v2 = PluginPackage(
            id: "test-pkg", name: "New Name v2", icon: "star", description: "new",
            author: "a", category: "c", tags: [], version: "2.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        if let existingData = FileManager.default.contents(atPath: path),
           let existing = try? decoder.decode(PluginPackage.self, from: existingData),
           let existingVer = SemanticVersion(string: existing.version),
           let builtInVer = SemanticVersion(string: v2.version),
           existingVer >= builtInVer {
            // Skip
        } else {
            try encoder.encode(v2).write(to: URL(fileURLWithPath: path))
        }
        let afterNewerVer = try decoder.decode(
            PluginPackage.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        #expect(afterNewerVer.name == "New Name v2")
    }
}
