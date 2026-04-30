import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Phase 2 regression tests: `PluginPackage.prerequisites` is additive to
/// the wire format, the built-in catalog wires prerequisites to the two
/// CLI-dependent packages, and legacy JSON fixtures (pre-`prerequisites`)
/// still decode cleanly with `prerequisites == []`.
@Suite("PluginPackage prerequisites")
@MainActor
struct PluginPackagePrereqTests {

    @Test("Default prerequisites is empty for zero-config packages")
    func defaultPrerequisitesEmpty() {
        let pkg = PluginPackage(
            id: "x", name: "X", icon: "circle", description: "d",
            author: "a", category: "c", tags: [],
            version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: []
        )
        #expect(pkg.prerequisites.isEmpty)
    }

    @Test("Legacy JSON without prerequisites decodes with empty array")
    func legacyJsonDecodesToEmpty() throws {
        // Format-version-1 snapshot of a package that pre-dates the new
        // field — intentionally omits `prerequisites` to simulate an
        // on-disk file written by an older app build.
        let legacy = """
        {
          "id": "legacy-pkg",
          "name": "Legacy",
          "icon": "star",
          "description": "from before",
          "author": "ASTRA",
          "category": "Other",
          "tags": [],
          "version": "1.0.0",
          "skills": [],
          "connectors": [],
          "localTools": [],
          "templates": []
        }
        """.data(using: .utf8)!
        let pkg = try JSONDecoder().decode(PluginPackage.self, from: legacy)
        #expect(pkg.id == "legacy-pkg")
        #expect(pkg.prerequisites.isEmpty)
        #expect(pkg.sourceMetadata == nil)
    }

    @Test("Encoded JSON round-trips with prerequisites preserved")
    func roundTripWithPrerequisites() throws {
        let pkg = PluginPackage(
            id: "rt", name: "RT", icon: "circle", description: "d",
            author: "a", category: "c", tags: [],
            version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: [],
            prerequisites: [
                CommonCLIPrerequisites.gcloud,
                CommonCLIPrerequisites.gcloudAuth
            ]
        )
        let data = try JSONEncoder().encode(pkg)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)
        #expect(decoded.prerequisites.count == 2)
        #expect(decoded.prerequisites.first?.binary == "gcloud")
    }

    @Test("Encoded JSON round-trips source metadata")
    func roundTripWithSourceMetadata() throws {
        let source = CapabilitySourceMetadata.remoteApproved(
            id: "stanford-approved",
            displayName: "Stanford Approved",
            url: URL(string: "https://capabilities.stanford.edu")
        )
        let pkg = PluginPackage(
            id: "rt-source", name: "RT Source", icon: "circle", description: "d",
            author: "a", category: "c", tags: [],
            version: "1.0.0",
            skills: [], connectors: [], localTools: [], templates: [],
            sourceMetadata: source
        )
        let data = try JSONEncoder().encode(pkg)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)

        #expect(decoded.sourceMetadata == source)
        #expect(decoded.sourceMetadata?.trustLevel == "remote-approved")
    }

    @Test("Built-in Google Cloud package has gcloud + auth prereqs")
    func builtInGCloudHasPrereqs() {
        let gcp = PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" }
        #expect(gcp != nil)
        #expect(gcp?.prerequisites.count == 2)
        #expect(gcp?.prerequisites.first?.binary == "gcloud")
        #expect(gcp?.prerequisites.last?.semantic == .stdoutNonEmpty)
    }

    @Test("Built-in GitHub package is CLI-only and requires gh")
    func builtInGitHubIsCLIOnly() {
        let github = PluginCatalog.builtInPackages.first { $0.id == "github-workflow" }
        #expect(github != nil)
        #expect(github?.connectors.isEmpty == true)
        #expect(github?.localTools.map(\.command) == ["gh"])
        #expect(github?.prerequisites.count == 2)
        #expect(github?.prerequisites.map(\.binary) == ["gh", "gh"])
        #expect(github?.prerequisites.last?.livenessArgs == ["auth", "status"])
        #expect(github?.skills.first?.behaviorInstructions.contains("gh auth login") == true)
    }

    @Test("Built-in Docker package has docker prereq")
    func builtInDockerHasPrereq() {
        let docker = PluginCatalog.builtInPackages.first { $0.id == "docker-manager" }
        #expect(docker != nil)
        #expect(docker?.prerequisites.count == 1)
        #expect(docker?.prerequisites.first?.binary == "docker")
        #expect(docker?.prerequisites.first?.semantic == .stderrNoDaemonError)
    }

    @Test("Zero-config built-ins have no prerequisites")
    func builtInZeroConfigHasNoPrereqs() {
        // `test-runner` and `read-only-explorer` used to live here but
        // were removed from the catalog because they duplicated skills
        // every workspace already ships with (see PluginCatalog's
        // `deprecated` list).
        let zeroConfigIDs = [
            "code-reviewer",
            "security-auditor"
        ]
        for id in zeroConfigIDs {
            let pkg = PluginCatalog.builtInPackages.first { $0.id == id }
            #expect(pkg?.prerequisites.isEmpty == true, "\(id) should have no prerequisites")
        }
    }

    @Test("Deprecated package IDs no longer ship in the catalog")
    func deprecatedPackagesAreGone() {
        // Guardrail: if anyone re-adds `test-runner` or
        // `read-only-explorer`, this test fires. Those names collide with
        // skills auto-seeded by TaskLifecycleCoordinator, so installing
        // them would create a duplicate in the workspace sidebar.
        let removed = ["test-runner", "read-only-explorer"]
        for id in removed {
            let pkg = PluginCatalog.builtInPackages.first { $0.id == id }
            #expect(pkg == nil, "\(id) must not be in the catalog — duplicates an auto-seeded workspace skill")
        }
    }
}
