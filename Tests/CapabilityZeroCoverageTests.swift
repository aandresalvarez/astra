import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

// Behavioral coverage for previously untested capability services:
// ApprovedCapabilityBundle, CapabilityAudit, CapabilitySetupCopier,
// BundledToolInstaller, and MailTaskIntent.

private func zeroCoverageTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeZeroCoverageContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private let validPackageJSON = """
{"formatVersion":2,"id":"bundle-pkg","name":"Bundle Package","icon":"star","description":"d","author":"a","category":"Zeta","tags":[],"version":"1.0.0","skills":[],"connectors":[],"localTools":[],"templates":[]}
"""

private let secondPackageJSON = """
{"formatVersion":2,"id":"alpha-pkg","name":"Alpha Package","icon":"star","description":"d","author":"a","category":"Alpha","tags":[],"version":"1.0.0","skills":[],"connectors":[],"localTools":[],"templates":[]}
"""

@Suite("ApprovedCapabilityBundle ZeroCoverage")
struct ApprovedCapabilityBundleZeroCoverageTests {

    @Test("Bundle without Capabilities subdirectory yields no packages")
    func emptyBundleYieldsNoPackages() throws {
        let root = try zeroCoverageTempDirectory(named: "astra-empty-bundle")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try #require(Bundle(path: root.path))
        #expect(ApprovedCapabilityBundle.packages(bundle: bundle).isEmpty)
        #expect(ApprovedCapabilityBundle.bundledDirectory(bundle: bundle) == nil)
    }

    @Test("Bundled package JSON decodes, gets built-in source metadata, and sorts by category")
    func bundledPackagesDecodeAndSort() throws {
        let root = try zeroCoverageTempDirectory(named: "astra-bundle-decode")
        defer { try? FileManager.default.removeItem(at: root) }

        let capabilities = root.appendingPathComponent("Capabilities", isDirectory: true)
        try FileManager.default.createDirectory(at: capabilities, withIntermediateDirectories: true)
        try Data(validPackageJSON.utf8).write(to: capabilities.appendingPathComponent("bundle-pkg.json"))
        try Data(secondPackageJSON.utf8).write(to: capabilities.appendingPathComponent("alpha-pkg.json"))
        // Malformed JSON must be skipped, not crash the decode.
        try Data("{not json".utf8).write(to: capabilities.appendingPathComponent("broken.json"))

        let bundle = try #require(Bundle(path: root.path))
        let packages = ApprovedCapabilityBundle.packages(bundle: bundle)
        #expect(packages.count == 2)
        #expect(packages.map(\.id) == ["alpha-pkg", "bundle-pkg"])
        #expect(packages.allSatisfy { $0.sourceMetadata == .builtIn() })
        let directory = try #require(ApprovedCapabilityBundle.bundledDirectory(bundle: bundle))
        #expect(directory.lastPathComponent == "Capabilities")
    }

    @Test("builtInPackages falls back to curated in-code definitions when bundle is empty")
    func builtInPackagesFallBackToCode() {
        // Under `swift test` there is no app resource bundle with a
        // Capabilities directory, so the fallback in-code catalog is used.
        let packages = PluginCatalog.builtInPackages
        #expect(!packages.isEmpty)
        let ids = Set(packages.map(\.id))
        #expect(ids.contains("jira-workflow"))
        #expect(ids.contains("security-auditor"))
    }
}

@Suite("CapabilityAudit ZeroCoverage")
@MainActor
struct CapabilityAuditZeroCoverageTests {

    @Test("governanceFields emits expected keys and only enum/bool values")
    func governanceFieldsShape() {
        let governance = CapabilityGovernance()
        let fields = CapabilityAudit.governanceFields(governance)

        #expect(Set(fields.keys) == [
            "approval_status",
            "risk_level",
            "visibility",
            "requires_admin_approval",
            "requires_explicit_user_consent"
        ])
        #expect(fields["approval_status"] == governance.approvalStatus.rawValue)
        #expect(fields["risk_level"] == governance.riskLevel.rawValue)
        #expect(fields["visibility"] == governance.visibility.rawValue)
        // Values must never look like credentials: only short enum raw
        // values and booleans are allowed.
        for value in fields.values {
            #expect(value == "true" || value == "false" || (value.count < 24 && !value.contains("=")))
            #expect(!value.lowercased().contains("token"))
            #expect(!value.lowercased().contains("secret"))
            #expect(!value.lowercased().contains("password"))
        }
    }

    @Test("compactNames truncates, trims, and reports hidden count")
    func compactNamesBehavior() {
        #expect(CapabilityAudit.compactNames([]) == "none")
        #expect(CapabilityAudit.compactNames(["  ", "\n"]) == "none")
        #expect(CapabilityAudit.compactNames([" a ", "b"]) == "a,b")
        let many = (1...10).map { "n\($0)" }
        #expect(CapabilityAudit.compactNames(many) == "n1,n2,n3,n4,n5,n6,n7,n8,+2")
        #expect(CapabilityAudit.compactNames(many, limit: 10) == many.joined(separator: ","))
        #expect(CapabilityAudit.compactNames(["x", "y", "z"], limit: 1) == "x,+2")
    }

    @Test("taskContextFields emits the expected key shape for an empty task")
    func taskContextFieldsShape() throws {
        let container = try makeZeroCoverageContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Audit", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "G", workspace: workspace)
        context.insert(task)
        try context.save()

        let fields = CapabilityAudit.taskContextFields(source: "unit_test", task: task)

        #expect(fields["source"] == "unit_test")
        #expect(fields["workspace_id"] == workspace.id.uuidString)
        #expect(fields["runtime"] == task.resolvedRuntimeID.rawValue)
        #expect(fields["task_skill_count"] == "0")
        #expect(fields["resolved_skill_count"] == "0")
        #expect(fields["connector_count"] == "0")
        #expect(fields["local_tool_count"] == "0")
        #expect(fields["skill_names"] == "none")
        #expect(fields["connector_names"] == "none")
        for key in ["capability_scope", "scope_pruned", "configured_skill_count",
                    "configured_connector_count", "configured_local_tool_count",
                    "workspace_enabled_capabilities_count"] {
            #expect(fields[key] != nil, "missing \(key)")
        }
    }

    @Test("packageFields merges governance fields")
    func packageFieldsMergeGovernance() {
        let workspace = Workspace(name: "Audit", primaryPath: NSTemporaryDirectory())
        let fields = CapabilityAudit.packageFields(
            packageID: "p",
            packageName: "P",
            packageVersion: "1.0.0",
            workspace: workspace,
            source: "unit_test",
            skillsCount: 1,
            connectorsCount: 2,
            toolsCount: 3,
            governance: CapabilityGovernance()
        )
        #expect(fields["package_id"] == "p")
        #expect(fields["skills_count"] == "1")
        #expect(fields["connectors_count"] == "2")
        #expect(fields["tools_count"] == "3")
        #expect(fields["templates_count"] == "0")
        #expect(fields["approval_status"] == CapabilityGovernance().approvalStatus.rawValue)
    }
}

@Suite("CapabilitySetupCopier ZeroCoverage")
@MainActor
struct CapabilitySetupCopierZeroCoverageTests {

    private func makeJiraPackage() -> PluginPackage {
        PluginPackage(
            id: "jira-workflow",
            name: "Jira",
            icon: "list.bullet.clipboard",
            description: "d",
            author: "ASTRA",
            category: "Workflow",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [
                PluginConnector(
                    name: "Jira",
                    serviceType: "jira",
                    icon: "network",
                    description: "Jira connector",
                    baseURL: "https://your-domain.atlassian.net",
                    authMethod: "basic",
                    credentialHints: [
                        .init(key: "JIRA_EMAIL", hint: "Email"),
                        .init(key: "JIRA_API_TOKEN", hint: "Token")
                    ],
                    configHints: [
                        .init(key: "JIRA_PROJECTS", hint: "Projects", isList: true)
                    ],
                    notes: ""
                )
            ],
            localTools: [],
            templates: []
        )
    }

    @Test("Copies credentials, config, and base URL override from a configured workspace")
    func copyHappyPath() throws {
        let container = try makeZeroCoverageContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Source", primaryPath: NSTemporaryDirectory())
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://acme.atlassian.net",
            authMethod: "basic"
        )
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = ["ABC,DEF"]
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        workspace.connectors.append(connector)
        workspace.enabledCapabilityIDs = ["jira-workflow"]
        context.insert(workspace)
        try context.save()

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: entityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "tok-123", entityID: entityID, label: nil)

        let copier = CapabilitySetupCopier(secretStore: store)
        #expect(copier.copyablePackageIDs(from: workspace) == ["jira-workflow"])

        let summary = copier.copySetup(from: workspace, packages: [makeJiraPackage()])
        #expect(summary.sourceWorkspaceName == "Source")
        #expect(summary.selectedPackageIDs == ["jira-workflow"])
        #expect(summary.packageCount == 1)

        let inputs = try #require(summary.inputsByPackageID["jira-workflow"])
        #expect(inputs.credentialInputs["JIRA_EMAIL"] == "user@example.com")
        #expect(inputs.credentialInputs["JIRA_API_TOKEN"] == "tok-123")
        #expect(inputs.configInputs["JIRA_PROJECTS"] == "ABC,DEF")
        #expect(inputs.baseURLOverrides["Jira"] == "https://acme.atlassian.net")
        #expect(summary.copiedCredentialCount == 2)
        // JIRA_PROJECTS config + base URL override
        #expect(summary.copiedConfigCount == 2)
    }

    @Test("Workspace with no matching setup copies nothing")
    func copyNoSourceSetup() throws {
        let container = try makeZeroCoverageContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Bare", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        try context.save()

        let copier = CapabilitySetupCopier(secretStore: MockSecretStore())
        #expect(copier.copyablePackageIDs(from: workspace).isEmpty)

        let summary = copier.copySetup(from: workspace, packages: [makeJiraPackage()])
        #expect(summary.selectedPackageIDs.isEmpty)
        #expect(summary.inputsByPackageID.isEmpty)
        #expect(summary.copiedCredentialCount == 0)
        #expect(summary.copiedConfigCount == 0)
    }

    @Test("shouldMapBaseURL requires URL-shaped keys scoped to the connector")
    func shouldMapBaseURLPredicate() {
        let connector = PluginConnector(
            name: "REDCap",
            serviceType: "redcap",
            icon: "network",
            description: "",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key",
            credentialHints: [],
            configHints: [],
            notes: ""
        )
        #expect(CapabilitySetupCopier.shouldMapBaseURL(
            "https://x.example.edu", toEnvironmentKey: "REDCAP_API_URL", connector: connector))
        #expect(!CapabilitySetupCopier.shouldMapBaseURL(
            "https://x.example.edu", toEnvironmentKey: "REDCAP_API_TOKEN", connector: connector))
        #expect(!CapabilitySetupCopier.shouldMapBaseURL(
            "https://x.example.edu", toEnvironmentKey: "JIRA_BASE_URL", connector: connector))
        #expect(!CapabilitySetupCopier.shouldMapBaseURL(
            "   ", toEnvironmentKey: "REDCAP_API_URL", connector: connector))
        // Without a connector, any URL-shaped key maps.
        #expect(CapabilitySetupCopier.shouldMapBaseURL("https://x", toEnvironmentKey: "SOME_URL"))
    }
}

@Suite("BundledToolInstaller ZeroCoverage")
struct BundledToolInstallerZeroCoverageTests {

    @Test("Bundle without a Tools resource is a deterministic no-op")
    func missingToolsResourceIsNoOp() throws {
        // The real Tools directory only exists inside the packaged app
        // bundle, which is unavailable under `swift test`; only the
        // early-return no-op path is deterministically testable here.
        let root = try zeroCoverageTempDirectory(named: "astra-no-tools-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try #require(Bundle(path: root.path))
        #expect(bundle.url(forResource: "Tools", withExtension: nil) == nil)
        BundledToolInstaller.installBundledTools(bundle: bundle)
    }
}

@Suite("MailTaskIntent ZeroCoverage")
struct MailTaskIntentZeroCoverageTests {

    @Test("Read-only mail requests are detected")
    func readOnlyMailRequests() {
        #expect(MailTaskIntent.isReadOnlyMailRequest(["Check my inbox for updates"]))
        #expect(MailTaskIntent.isReadOnlyMailRequest(["summarize", "recent EMAILS"]))
        #expect(MailTaskIntent.isReadOnlyMailRequest(["open outlook and read the latest message"]))
    }

    @Test("Mutation terms disqualify read-only classification")
    func mutationTermsBlock() {
        #expect(!MailTaskIntent.isReadOnlyMailRequest(["send an email to Bob"]))
        #expect(!MailTaskIntent.isReadOnlyMailRequest(["check inbox and reply to the first message"]))
        #expect(!MailTaskIntent.isReadOnlyMailRequest(["delete old emails"]))
        #expect(!MailTaskIntent.isReadOnlyMailRequest(["draft a message in outlook"]))
    }

    @Test("Non-mail requests and edge cases are rejected")
    func nonMailEdgeCases() {
        #expect(!MailTaskIntent.isReadOnlyMailRequest([]))
        #expect(!MailTaskIntent.isReadOnlyMailRequest([""]))
        #expect(!MailTaskIntent.isReadOnlyMailRequest(["fix the build"]))
        // Whole-word matching: "mailbox" is not the term "mail".
        #expect(!MailTaskIntent.isReadOnlyMailRequest(["repair the mailbox flag"]))
        // Punctuation is normalized to spaces, so "e-mail" does not match "email".
        #expect(MailTaskIntent.isReadOnlyMailRequest(["read my email!"]))
    }

    @Test("Outlook URL detection covers hosts and rejects others")
    func outlookURLDetection() {
        #expect(MailTaskIntent.isOutlookURL("https://outlook.office.com/mail/"))
        #expect(MailTaskIntent.isOutlookURL("https://outlook.cloud.microsoft/mail"))
        #expect(MailTaskIntent.isOutlookURL("https://eur.outlook.office.com/x"))
        #expect(MailTaskIntent.isOutlookURL("https://outlook.live.com/mail"))
        #expect(!MailTaskIntent.isOutlookURL("https://example.com/outlook"))
        // Any host containing "outlook." matches, by design.
        #expect(MailTaskIntent.isOutlookURL("https://notoutlook.office.com"))
        #expect(!MailTaskIntent.isOutlookURL("https://office.com/mail"))
        #expect(!MailTaskIntent.isOutlookURL(nil))
        #expect(!MailTaskIntent.isOutlookURL("not a url"))
    }
}
