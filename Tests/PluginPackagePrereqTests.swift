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
        #expect(pkg.browserAdapters.isEmpty)
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
        #expect(pkg.browserAdapters.isEmpty)
        #expect(pkg.sourceMetadata == nil)
    }

    @Test("Encoded JSON round-trips browser adapters")
    func roundTripWithBrowserAdapters() throws {
        let pkg = PluginPackage(
            id: "browser-adapter",
            name: "Browser Adapter",
            icon: "globe",
            description: "d",
            author: "a",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [BrowserSiteAdapterID.googleDrive]
        )
        let data = try JSONEncoder().encode(pkg)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)
        #expect(decoded.browserAdapters == [BrowserSiteAdapterID.googleDrive])
        #expect(decoded.contentSummary == "1 browser adapter")
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

    @Test("Built-in Google Drive browser package exposes adapter only")
    func builtInGoogleDriveBrowserHasAdapter() {
        let drive = PluginCatalog.builtInPackages.first { $0.id == "google-drive-browser" }
        #expect(drive != nil)
        #expect(drive?.category == "Browser")
        #expect(drive?.browserAdapters == [BrowserSiteAdapterID.googleDrive])
        #expect(drive?.skills.isEmpty == true)
        #expect(drive?.connectors.isEmpty == true)
        #expect(drive?.localTools.isEmpty == true)
    }

    @Test("Built-in GitHub package requires gh and exposes browser adapter")
    func builtInGitHubRequiresGhAndExposesBrowserAdapter() {
        let github = PluginCatalog.builtInPackages.first { $0.id == "github-workflow" }
        #expect(github != nil)
        #expect(github?.version == "2.1.4")
        #expect(github?.connectors.isEmpty == true)
        #expect(github?.browserAdapters == [BrowserSiteAdapterID.github])
        #expect(github?.localTools.isEmpty == true)
        #expect(github?.prerequisites.count == 2)
        #expect(github?.prerequisites.map(\.binary) == ["gh", "gh"])
        #expect(github?.prerequisites.last?.livenessArgs == ["auth", "status", "--hostname", "github.com"])
        #expect(github?.skills.first?.behaviorInstructions.contains("gh auth login") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh search issues") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh search prs --author \"@me\"") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("Do not pipe JSON into `python3 - <<'PY'`") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh api /search/issues") == false)
    }

    @Test("Built-in REDCap package has Stanford API connector")
    func builtInREDCapHasStanfordConnector() {
        let redcap = PluginCatalog.builtInPackages.first { $0.id == "redcap-workflow" }
        #expect(redcap != nil)
        #expect(redcap?.category == "Integrations")
        #expect(redcap?.connectors.count == 1)
        #expect(redcap?.connectors.first?.serviceType == "redcap")
        #expect(redcap?.connectors.first?.baseURL == "https://redcap.stanford.edu/api/")
        #expect(redcap?.connectors.first?.credentialHints.map(\.key) == ["REDCAP_API_TOKEN"])
        #expect(redcap?.localTools.map(\.command) == ["curl"])
        #expect(redcap?.skills.first?.environmentKeys == ["REDCAP_API_URL"])
        #expect(redcap?.skills.first?.environmentValues == ["https://redcap.stanford.edu/api/"])
        #expect(redcap?.skills.first?.behaviorInstructions.contains("content=formEventMapping") == true)
    }

    @Test("Built-in Stanford Apple Mail package is local and text-only")
    func builtInStanfordAppleMailUsesLocalMailBridge() {
        let mail = PluginCatalog.builtInPackages.first { $0.id == "stanford-apple-mail" }
        #expect(mail != nil)
        #expect(mail?.category == "Integrations")
        #expect(mail?.connectors.isEmpty == true)
        #expect(mail?.localTools.map(\.command) == ["stanford-apple-mail"])
        #expect(mail?.prerequisites.map(\.binary) == ["osascript"])
        #expect(mail?.skills.first?.environmentKeys == ["ASTRA_APPLE_MAIL_ACCOUNT"])
        #expect(mail?.skills.first?.environmentValues == [""])
        #expect(mail?.setupGuide.contains("Graph is blocked") == true)
        #expect(mail?.setupGuide.contains("@stanford.edu") == true)
        #expect(mail?.skills.first?.behaviorInstructions.contains("V1 is text-only") == true)
        #expect(mail?.skills.first?.behaviorInstructions.contains("auto-detects exactly one @stanford.edu account") == true)
    }

    @Test("Built-in SHC Graph Mail package is local tool based")
    func builtInSHCGraphMailUsesPowerShellBridge() {
        let mail = PluginCatalog.builtInPackages.first { $0.id == "stanford-healthcare-graph-mail" }
        #expect(mail != nil)
        #expect(mail?.category == "Integrations")
        #expect(mail?.connectors.isEmpty == true)
        #expect(mail?.localTools.map(\.command) == ["stanford-graph-mail"])
        #expect(mail?.prerequisites.map(\.binary) == ["pwsh"])
        #expect(mail?.skills.first?.environmentKeys == ["ASTRA_GRAPH_MAIL_TENANT", "ASTRA_GRAPH_MAIL_ACCOUNT"])
        #expect(mail?.skills.first?.environmentValues == ["stanfordhealthcare.org", ""])
        #expect(mail?.skills.first?.behaviorInstructions.contains("Graph PowerShell") == true)
        #expect(mail?.skills.first?.behaviorInstructions.contains("@stanfordhealthcare.org") == true)
        #expect(mail?.skills.first?.behaviorInstructions.contains("Do not use it for @stanford.edu") == true)
    }

    @Test("Zero-config built-ins have no prerequisites")
    func builtInZeroConfigHasNoPrereqs() {
        // `test-runner` and `read-only-explorer` used to live here but
        // were removed from the catalog because they duplicated skills
        // every workspace already ships with (see PluginCatalog's
        // `deprecated` list).
        let zeroConfigIDs = [
            "security-auditor"
        ]
        for id in zeroConfigIDs {
            let pkg = PluginCatalog.builtInPackages.first { $0.id == id }
            #expect(pkg?.prerequisites.isEmpty == true, "\(id) should have no prerequisites")
        }
    }

    @Test("Deprecated package IDs no longer ship in the catalog")
    func deprecatedPackagesAreGone() {
        // Guardrail: if anyone re-adds these removed packages, this test
        // fires so they stay out of the approved catalog.
        let removed = [
            "test-runner", "read-only-explorer",
            "code-reviewer", "docker-manager",
            "starr-dbt-usage", "starr-dbt", "star-dbt-usage", "star-dbt",
            "stanford-outlook-mail", "stanford-graph-mail"
        ]
        for id in removed {
            let pkg = PluginCatalog.builtInPackages.first { $0.id == id }
            #expect(pkg == nil, "\(id) must not be in the catalog")
        }
    }
}
