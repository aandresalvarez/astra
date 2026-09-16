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

    @Test("Built-in GitHub package requires gh and routes through host control")
    func builtInGitHubRequiresGhAndRoutesThroughHostControl() {
        let github = PluginCatalog.builtInPackages.first { $0.id == "github-workflow" }
        #expect(github != nil)
        #expect(github?.version == "2.2.0")
        #expect(github?.connectors.isEmpty == true)
        #expect(github?.browserAdapters.isEmpty == true)
        #expect(github?.localTools.isEmpty == true)
        #expect(github?.prerequisites.count == 2)
        #expect(github?.prerequisites.map(\.binary) == ["gh", "gh"])
        #expect(github?.prerequisites.last?.livenessArgs == ["auth", "status", "--hostname", "github.com"])
        #expect(github?.prerequisites.last?.contextualCheck == .githubRepositoryAccess)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh auth login") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("SAML SSO authorization") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("mcp__astra_host__github") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("astra_host-github") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("via Bash") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh search issues") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh search prs --author \"@me\"") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("Do not pipe JSON into `python3 - <<'PY'`") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh api /search/issues") == false)
    }

    @Test("Built-in REDCap package reaches Stanford through the broker, not curl")
    func builtInREDCapReachesStanfordThroughTheBroker() throws {
        let redcap = try #require(PluginCatalog.builtInPackages.first { $0.id == "redcap-workflow" })
        #expect(redcap.category == "Integrations")
        #expect(redcap.connectors.count == 1)
        #expect(redcap.connectors.first?.serviceType == "redcap")
        #expect(redcap.connectors.first?.baseURL == "https://redcap.stanford.edu/api/")
        #expect(redcap.connectors.first?.credentialHints.map(\.key) == ["REDCAP_API_TOKEN"])
        #expect(redcap.skills.first?.environmentKeys == ["REDCAP_API_URL"])
        #expect(redcap.skills.first?.environmentValues == ["https://redcap.stanford.edu/api/"])

        // The token is brokered now, so nothing in this package may point an
        // agent at a hand-built request or at the credential variable. The
        // capability shipped with a `curl` tool and a table of `content=`
        // values, which is how a project token ended up in a transcript.
        #expect(redcap.localTools.isEmpty)
        let instructions = try #require(redcap.skills.first?.behaviorInstructions)
        #expect(instructions.contains("astra-host-control redcap"))
        #expect(instructions.contains("mcp__astra_host__redcap"))
        #expect(instructions.contains("do not use curl, Python HTTP clients, or direct REDCap API calls"))
        #expect(!instructions.contains("curl -"))
        #expect(!instructions.contains("content=formEventMapping"))
        #expect(instructions.contains("export_path"))
        for skill in redcap.skills {
            #expect(
                !skill.behaviorInstructions.contains("REDCAP_API_TOKEN")
                    || skill.behaviorInstructions.contains("do not look for REDCAP_API_TOKEN"),
                "A brokered skill must not send the agent looking for the credential variable."
            )
        }
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

/// A built-in capability is ASTRA telling the agent how to reach a service, so
/// a stale one is not a documentation problem — it is the app instructing the
/// agent to work around its own broker, which is what produced the incident.
///
/// Two copies of every built-in exist: the bundled JSON and
/// `PluginCatalog.fallbackBuiltInPackages`, used when the resource bundle is
/// unreadable. Only the first is exercised in normal runs, and that is exactly
/// how the fallback kept shipping the pre-broker REDCap workflow — a `curl`
/// local tool and instructions to read the token from the environment — for
/// every release after the credential moved into the broker. Both sources are
/// held to the same rules here.
@Suite("Built-in capability broker parity")
@MainActor
struct BuiltInCapabilityBrokerParityTests {
    private static let sources: [(label: String, packages: [PluginPackage])] = [
        ("bundled", ApprovedCapabilityBundle.packages()),
        ("fallback", PluginCatalog.fallbackBuiltInPackages)
    ]

    /// The shape of an actual invocation, as opposed to the prohibition the
    /// brokered skills carry ("do not use curl, Python HTTP clients, ...").
    private static let directCallShapes = ["curl -", "curl \"", "curl '", "curl $", "curl http"]

    private static func brokeredServices(in package: PluginPackage) -> [String] {
        package.connectors
            .map(\.serviceType)
            .filter { HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration($0) }
    }

    @Test("Every built-in package for a brokered service routes through the broker")
    func brokeredBuiltInPackagesRouteThroughTheBroker() throws {
        for source in Self.sources {
            #expect(!source.packages.isEmpty, "No \(source.label) built-in packages to check")
            var checked = 0
            for package in source.packages {
                let services = Self.brokeredServices(in: package)
                guard !services.isEmpty else { continue }
                checked += 1
                let label = "\(source.label)/\(package.id)"

                for tool in package.localTools {
                    #expect(
                        !["curl", "wget", "http", "httpie"].contains(tool.command),
                        "\(label) ships an HTTP client tool (\(tool.command)) for a brokered service."
                    )
                }

                for skill in package.skills {
                    let instructions = skill.behaviorInstructions
                    for serviceType in services {
                        let toolName = try #require(
                            HostControlPlaneMCPProjection.connectorToolName(serviceType)
                        )
                        #expect(
                            instructions.contains("mcp__astra_host__\(toolName)"),
                            "\(label) skill '\(skill.name)' never names the \(serviceType) broker route."
                        )
                    }
                    for shape in Self.directCallShapes {
                        #expect(
                            !instructions.contains(shape),
                            "\(label) skill '\(skill.name)' instructs a direct call: \(shape)"
                        )
                    }
                    // The same lint the skill editor shows authors. ASTRA's own
                    // capabilities have to pass it, or the warning is noise.
                    let findings = BrokeredSkillInstructionLint.findings(
                        instructions: instructions,
                        environmentKeys: skill.environmentKeys
                    )
                    let flagged = findings.map(\.environmentKey).joined(separator: ", ")
                    #expect(
                        findings.isEmpty,
                        "\(label) skill '\(skill.name)' fails the brokered lint: \(flagged)"
                    )
                }
            }
            #expect(checked > 0, "No \(source.label) package declares a brokered connector")
        }
    }

    /// The fallback drifting *behind* the bundled definition is the failure
    /// mode: it is edited only when someone remembers it exists.
    @Test("The fallback definition of a brokered package matches the bundled one")
    func fallbackBrokeredPackagesMatchTheBundledDefinition() throws {
        let bundled = ApprovedCapabilityBundle.packages()
        try #require(!bundled.isEmpty)

        for package in PluginCatalog.fallbackBuiltInPackages
        where !Self.brokeredServices(in: package).isEmpty {
            let match = bundled.first { $0.id == package.id }
            let shipped = try #require(
                match,
                Comment(rawValue: "Fallback ships brokered package \(package.id) that the bundle does not.")
            )
            #expect(package.version == shipped.version, "\(package.id): fallback version is stale.")
            #expect(
                package.skills.map(\.behaviorInstructions) == shipped.skills.map(\.behaviorInstructions),
                "\(package.id): fallback instructions differ from the bundled definition."
            )
            #expect(package.localTools.map(\.command) == shipped.localTools.map(\.command))
            #expect(
                package.governance.requiresExplicitUserConsent
                    == shipped.governance.requiresExplicitUserConsent,
                "\(package.id): fallback grants the capability more freely than the bundled one."
            )
            #expect(package.governance.riskLevel == shipped.governance.riskLevel)
        }
    }
}
