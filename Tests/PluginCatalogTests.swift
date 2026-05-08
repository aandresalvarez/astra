import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

private func makeContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "plugin-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func writePackage(_ pkg: PluginPackage, to dir: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(pkg)
    let path = (dir as NSString).appendingPathComponent("\(pkg.id).json")
    try data.write(to: URL(fileURLWithPath: path))
}

private let testPackage = PluginPackage(
    id: "test-plugin",
    name: "Test Plugin",
    icon: "star",
    description: "A test plugin",
    author: "Test",
    category: "Development",
    tags: ["test"],
    version: "1.0.0",
    skills: [PluginSkill(
        name: "Test Skill",
        icon: "star",
        description: "Test skill desc",
        allowedTools: ["Read", "Grep"],
        disallowedTools: ["Write"],
        customTools: [],
        behaviorInstructions: "Be careful.",
        environmentKeys: [],
        environmentValues: []
    )],
    connectors: [],
    localTools: [],
    templates: []
)

// MARK: - Load Catalog

@Suite("PluginCatalog Load")
@MainActor
struct PluginCatalogLoadTests {

    @Test("Empty directory returns empty packages")
    func emptyDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.loadCatalog()
        #expect(catalog.packages.isEmpty)
    }

    @Test("Non-existent directory returns empty packages")
    func nonExistentDir() {
        let catalog = PluginCatalog()
        catalog.catalogDirectory = "/tmp/does-not-exist-\(UUID().uuidString)"
        catalog.loadCatalog()
        #expect(catalog.packages.isEmpty)
    }

    @Test("Valid JSON files are loaded and sorted")
    func loadsAndSorts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var pkg1 = testPackage
        pkg1.category = "B-Category"
        try writePackage(pkg1, to: dir)

        var pkg2 = PluginPackage(
            id: "another-plugin", name: "Another", icon: "gear",
            description: "d", author: "a", category: "A-Category",
            tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        try writePackage(pkg2, to: dir)

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.loadCatalog()
        #expect(catalog.packages.count == 2)
        #expect(catalog.packages[0].category == "A-Category")
        #expect(catalog.packages[1].category == "B-Category")
    }

    @Test("Malformed JSON files are skipped")
    func malformedSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try writePackage(testPackage, to: dir)
        let badPath = (dir as NSString).appendingPathComponent("broken.json")
        try "not valid json{{{".write(to: URL(fileURLWithPath: badPath), atomically: true, encoding: .utf8)

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.loadCatalog()
        #expect(catalog.packages.count == 1)
        #expect(catalog.packages[0].id == "test-plugin")
    }

    @Test("Approved capability catalog loads from capability folder")
    func approvedCatalogLoadsFromCapabilityFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-approved-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let package = PluginPackage(
            id: "approved-only",
            name: "Approved Only",
            icon: "checkmark.seal",
            description: "Approved folder package",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let library = CapabilityLibrary(directory: root)
        let catalog = PluginCatalog()

        catalog.loadApprovedCapabilities(library: library)
        #expect(catalog.packages.map(\.id).contains("security-auditor"))

        try library.install(package)
        catalog.loadApprovedCapabilities(library: library)
        #expect(catalog.packages.map(\.id).contains("approved-only"))
        #expect(catalog.packages.allSatisfy { FileManager.default.fileExists(atPath: library.packageURL(for: $0.id).path) })
    }

    @Test("Categories preserves order")
    func categoriesOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        for (id, cat) in [("a", "Security"), ("b", "Development"), ("c", "Security")] {
            var pkg = PluginPackage(
                id: id, name: id, icon: "star", description: "d",
                author: "a", category: cat, tags: [], version: "1.0.0",
                skills: [], connectors: [], localTools: [], templates: []
            )
            try writePackage(pkg, to: dir)
        }

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.loadCatalog()
        let cats = catalog.categories
        #expect(cats.count == 2)
    }

    @Test("Jira capability uses permission probe and current search endpoint")
    func jiraCapabilityGuidesAuthAndSearch() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let skill = try #require(package.skills.first)

        #expect(package.version == "2.0.3")
        #expect(skill.behaviorInstructions.contains("/rest/api/3/mypermissions?permissions=BROWSE_PROJECTS"))
        #expect(skill.behaviorInstructions.contains("/rest/api/3/search/jql?jql="))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/search?jql="))
        #expect(skill.behaviorInstructions.contains("First verify auth with /rest/api/3/mypermissions"))
        #expect(skill.behaviorInstructions.contains("Use /rest/api/3/myself only as a fallback"))
        #expect(!skill.behaviorInstructions.contains("If /myself returns 401/403, stop"))
        #expect(skill.behaviorInstructions.contains("Do not call /rest/api/3/permissions"))
        #expect(skill.behaviorInstructions.contains("Only recommend generating a new API token when both permission and fallback auth probes return 401/403"))
    }

    @Test("Security auditor bundled capability version matches fallback catalog")
    func securityAuditorVersionMatchesFallbackCatalog() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "security-auditor" })

        #expect(package.version == "2.0.1")
    }
}

// MARK: - isInstalled

@Suite("PluginCatalog isInstalled")
@MainActor
struct PluginCatalogIsInstalledTests {

    @Test("Returns true when workspace has matching skill name")
    func matchingSkill() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/installed-test")
        ctx.insert(ws)
        let skill = Skill(name: "Test Skill", allowedTools: ["Read"], disallowedTools: [], behaviorInstructions: "")
        skill.workspace = ws
        ctx.insert(skill)
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.packages = [testPackage]
        #expect(catalog.isInstalled("test-plugin", in: ws))
    }

    @Test("Returns false when no matching skill or connector")
    func noMatch() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/installed-test-2")
        ctx.insert(ws)
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.packages = [testPackage]
        #expect(!catalog.isInstalled("test-plugin", in: ws))
    }

    @Test("Returns true for empty skills+connectors package")
    func emptyPackageIsInstalled() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/installed-test-3")
        ctx.insert(ws)
        try ctx.save()

        let emptyPkg = PluginPackage(
            id: "empty", name: "Empty", icon: "star", description: "d",
            author: "a", category: "c", tags: [], version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        let catalog = PluginCatalog()
        catalog.packages = [emptyPkg]
        #expect(catalog.isInstalled("empty", in: ws))
    }
}

// MARK: - Install

@Suite("PluginCatalog Install")
@MainActor
struct PluginCatalogInstallTests {

    @Test("Install creates skill in workspace")
    func installsSkill() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/install-test")
        ctx.insert(ws)
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.install(testPackage, into: ws, modelContext: ctx)

        #expect(ws.skills.count == 1)
        #expect(ws.skills[0].name == "Test Skill")
        #expect(ws.skills[0].allowedTools == ["Read", "Grep"])
        #expect(ws.skills[0].disallowedTools == ["Write"])
        #expect(ws.skills[0].behaviorInstructions == "Be careful.")
    }

    @Test("Install records plugin version")
    func recordsVersion() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/install-ver")
        ctx.insert(ws)
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.install(testPackage, into: ws, modelContext: ctx)

        #expect(ws.installedVersion(of: "test-plugin") == "1.0.0")
    }

    @Test("Duplicate install skips existing skill")
    func skipsDuplicate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/install-dup")
        ctx.insert(ws)
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.install(testPackage, into: ws, modelContext: ctx)
        catalog.install(testPackage, into: ws, modelContext: ctx)

        #expect(ws.skills.count == 1)
    }

    @Test("Install creates template")
    func installsTemplate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/install-tmpl")
        ctx.insert(ws)
        try ctx.save()

        var pkgWithTemplate = testPackage
        pkgWithTemplate.templates = [PluginTemplate(
            name: "Review Template",
            icon: "doc",
            description: "Code review",
            mainGoal: "Review {{file}}",
            beforeGoal: "",
            afterGoal: "",
            mainBudget: 5000,
            beforeBudget: 0,
            afterBudget: 0,
            variablesJSON: "{}",
            passContextToMain: false,
            passContextToAfter: false
        )]

        let catalog = PluginCatalog()
        catalog.install(pkgWithTemplate, into: ws, modelContext: ctx)

        #expect(ws.templates.count == 1)
        #expect(ws.templates[0].name == "Review Template")
        #expect(ws.templates[0].mainGoal == "Review {{file}}")
    }
}

// MARK: - Version Checking

@Suite("PluginCatalog Version Checks")
@MainActor
struct PluginCatalogVersionTests {

    @Test("hasUpdate returns true when catalog is newer")
    func hasUpdateTrue() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/ver-test")
        ctx.insert(ws)
        ws.recordInstalledPlugin(id: "test-plugin", version: "1.0.0")
        try ctx.save()

        var v2 = testPackage
        v2.version = "2.0.0"

        let catalog = PluginCatalog()
        catalog.packages = [v2]
        #expect(catalog.hasUpdate(for: "test-plugin", in: ws))
    }

    @Test("hasUpdate returns false for same version")
    func hasUpdateFalse() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/ver-test-2")
        ctx.insert(ws)
        ws.recordInstalledPlugin(id: "test-plugin", version: "1.0.0")
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.packages = [testPackage]
        #expect(!catalog.hasUpdate(for: "test-plugin", in: ws))
    }

    @Test("availableUpdates returns only updatable packages")
    func availableUpdates() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/ver-test-3")
        ctx.insert(ws)
        ws.recordInstalledPlugin(id: "test-plugin", version: "1.0.0")
        ws.recordInstalledPlugin(id: "other", version: "3.0.0")
        try ctx.save()

        var v2 = testPackage
        v2.version = "2.0.0"
        let otherPkg = PluginPackage(
            id: "other", name: "Other", icon: "gear", description: "d",
            author: "a", category: "c", tags: [], version: "3.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )

        let catalog = PluginCatalog()
        catalog.packages = [v2, otherPkg]
        let updates = catalog.availableUpdates(for: ws)
        #expect(updates.count == 1)
        #expect(updates[0].id == "test-plugin")
    }
}

// MARK: - Update

@Suite("PluginCatalog Update")
@MainActor
struct PluginCatalogUpdateTests {

    @Test("Update modifies existing skill fields")
    func updatesExistingSkill() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/update-test")
        ctx.insert(ws)
        try ctx.save()

        let catalog = PluginCatalog()
        catalog.install(testPackage, into: ws, modelContext: ctx)
        #expect(ws.skills[0].behaviorInstructions == "Be careful.")

        var v2 = testPackage
        v2.version = "2.0.0"
        v2.skills[0].behaviorInstructions = "Be very careful and thorough."
        v2.skills[0].allowedTools = ["Read", "Grep", "Glob"]

        catalog.update(v2, in: ws, modelContext: ctx)

        #expect(ws.skills.count == 1)
        #expect(ws.skills[0].behaviorInstructions == "Be very careful and thorough.")
        #expect(ws.skills[0].allowedTools == ["Read", "Grep", "Glob"])
        #expect(ws.installedVersion(of: "test-plugin") == "2.0.0")
    }

    @Test("Update creates new skill if not present")
    func createsNewSkill() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let ws = Workspace(name: "Test", primaryPath: "/tmp/update-new")
        ctx.insert(ws)
        try ctx.save()

        var v2 = testPackage
        v2.version = "2.0.0"
        v2.skills.append(PluginSkill(
            name: "New Skill",
            icon: "plus",
            description: "Brand new",
            allowedTools: ["Bash"],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "New instructions",
            environmentKeys: [],
            environmentValues: []
        ))

        let catalog = PluginCatalog()
        catalog.update(v2, in: ws, modelContext: ctx)

        let skillNames = ws.skills.map(\.name).sorted()
        #expect(skillNames.contains("New Skill"))
    }
}

// MARK: - Seed Built-in Packages

@Suite("PluginCatalog Seed")
@MainActor
struct PluginCatalogSeedTests {

    @Test("Seed creates built-in package files")
    func seedCreatesFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.seedBuiltInPlugins()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == PluginCatalog.builtInPackages.count)
    }

    @Test("Seed removes deprecated packages")
    func seedRemovesDeprecated() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let deprecatedPath = (dir as NSString).appendingPathComponent("safe-executor.json")
        try "{}".write(to: URL(fileURLWithPath: deprecatedPath), atomically: true, encoding: .utf8)

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.seedBuiltInPlugins()

        #expect(!FileManager.default.fileExists(atPath: deprecatedPath))
    }

    @Test("Seed skips overwrite when on-disk version >= built-in")
    func seedSkipsSameVersion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let catalog = PluginCatalog()
        catalog.catalogDirectory = dir
        catalog.seedBuiltInPlugins()

        // Modify a built-in file on disk
        let firstPkg = PluginCatalog.builtInPackages[0]
        let path = (dir as NSString).appendingPathComponent("\(firstPkg.id).json")
        var modified = try JSONDecoder().decode(
            PluginPackage.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let originalDesc = modified.description

        // Manually write a modified description at same version
        var customPkg = firstPkg
        // Keep same version but change description to prove it's not overwritten
        let customJSON = try JSONEncoder().encode(customPkg)
        // Write a marker we can detect
        var jsonObj = try JSONSerialization.jsonObject(with: customJSON) as! [String: Any]
        jsonObj["description"] = "CUSTOM_MARKER"
        let markedData = try JSONSerialization.data(withJSONObject: jsonObj, options: .prettyPrinted)
        try markedData.write(to: URL(fileURLWithPath: path))

        // Re-seed — same version should NOT overwrite
        catalog.seedBuiltInPlugins()

        let afterSeed = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))
        ) as? [String: Any]
        #expect(afterSeed?["description"] as? String == "CUSTOM_MARKER")
    }

    @Test("Built-in packages all have valid versions")
    func builtInVersionsValid() {
        for pkg in PluginCatalog.builtInPackages {
            let ver = SemanticVersion(string: pkg.version)
            #expect(ver != nil, "Package \(pkg.id) has invalid version: \(pkg.version)")
        }
    }

    @Test("Built-in packages have unique IDs")
    func builtInUniqueIDs() {
        let ids = PluginCatalog.builtInPackages.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
