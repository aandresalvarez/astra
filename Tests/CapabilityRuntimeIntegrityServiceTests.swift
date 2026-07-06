import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeRuntimeIntegrityContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("CapabilityRuntimeIntegrityServiceTests")
@MainActor
struct CapabilityRuntimeIntegrityServiceTests {
    @Test("provider launch scope ignores irrelevant enabled package resources")
    func providerLaunchScopeIgnoresIrrelevantEnabledPackageResources() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Artifact With Jira Enabled", primaryPath: "/tmp/artifact-jira-enabled")
        workspace.enabledCapabilityIDs = [jiraPackage.id]
        context.insert(workspace)
        let task = AgentTask(
            title: "Create an HTML demo",
            goal: "create a standalone HTML and JavaScript page for a puzzle",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let scopedIssues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            scope: .providerLaunch(contextText: task.goal)
        )
        let fullInventoryIssues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false
        )

        #expect(scopedIssues.isEmpty)
        #expect(!fullInventoryIssues.isEmpty)
    }

    @Test("provider launch scope still blocks relevant enabled package resources")
    func providerLaunchScopeStillBlocksRelevantEnabledPackageResources() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Relevant Jira Enabled", primaryPath: "/tmp/relevant-jira-enabled")
        workspace.enabledCapabilityIDs = [jiraPackage.id]
        context.insert(workspace)
        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets for STAR",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            scope: .providerLaunch(contextText: task.goal)
        )

        #expect(issues.contains { $0.source == .enabledPackage && $0.resourceKind == .connector })
        #expect(issues.contains { $0.source == .enabledPackage && $0.resourceKind == .skill })
    }

    @Test("runtime integrity accepts enabled shared Jira when stale local Jira credentials are missing")
    func runtimeIntegrityUsesUsableSharedConnectorOverStaleLocalMatch() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "JSL Jira", primaryPath: "/tmp/jsl-jira")
        workspace.enabledCapabilityIDs = [jiraPackage.id]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let staleLocal = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Old local Jira row",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        staleLocal.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        staleLocal.workspace = workspace
        context.insert(staleLocal)

        let sharedJira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured shared Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        sharedJira.isGlobal = true
        sharedJira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        workspace.enabledGlobalConnectorIDs = [sharedJira.id.uuidString]
        context.insert(sharedJira)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let store = MockSecretStore()
        let sharedEntityID = KeychainSecretStore.connectorEntityID(for: sharedJira.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: sharedEntityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "token", entityID: sharedEntityID, label: nil)

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            secretStore: store
        )

        #expect(issues.isEmpty)
    }

    @Test("runtime integrity credential issue names the concrete connector row")
    func runtimeIntegrityCredentialIssueNamesConcreteConnector() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Unreadable Shared Jira", primaryPath: "/tmp/unreadable-shared-jira")
        workspace.enabledCapabilityIDs = [jiraPackage.id]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let sharedJira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured shared Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        sharedJira.isGlobal = true
        sharedJira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        workspace.enabledGlobalConnectorIDs = [sharedJira.id.uuidString]
        context.insert(sharedJira)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            secretStore: MockSecretStore()
        )

        let issue = try #require(issues.first { $0.resourceKind == .credential })
        #expect(issue.resourceName == "Jira-new")
        #expect(issue.message == "connector Jira-new is missing Keychain value: JIRA_EMAIL, JIRA_API_TOKEN")
    }

    @Test("runtime integrity normalizes connector credential gaps in diagnostics")
    func runtimeIntegrityNormalizesConnectorCredentialGapsInDiagnostics() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Padded Shared Jira", primaryPath: "/tmp/padded-shared-jira")
        workspace.enabledCapabilityIDs = [jiraPackage.id]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let sharedJira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured shared Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        sharedJira.isGlobal = true
        sharedJira.credentialKeys = [" JIRA_EMAIL ", "  ", "\nJIRA_API_TOKEN\t"]
        workspace.enabledGlobalConnectorIDs = [sharedJira.id.uuidString]
        context.insert(sharedJira)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            secretStore: MockSecretStore()
        )

        let issue = try #require(issues.first { $0.resourceKind == .credential })
        #expect(issue.resourceName == "Jira-new")
        #expect(issue.message == "connector Jira-new is missing Keychain value: JIRA_EMAIL, JIRA_API_TOKEN")
    }

    @Test("provider launch audit separates configured and scoped capabilities")
    func providerLaunchAuditSeparatesConfiguredAndScopedCapabilities() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Audit Scope", primaryPath: "/tmp/audit-scope")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Read Stanford email through Microsoft Graph",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use the mail bridge."
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let task = AgentTask(
            title: "Create a JavaScript page",
            goal: "create a standalone HTML and JavaScript page",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        let fields = CapabilityAudit.taskContextFields(
            source: "test",
            task: task,
            scope: .providerLaunch(contextText: task.goal)
        )

        #expect(fields["capability_scope"] == "provider_launch")
        #expect(fields["scope_pruned"] == "true")
        #expect(fields["configured_skill_count"] == "1")
        #expect(fields["resolved_skill_count"] == "0")
        #expect(fields["configured_skill_names"] == "Stanford Graph Mail Agent")
        #expect(fields["scope_excluded_skill_names"] == "Stanford Graph Mail Agent")
    }

    @Test("enabled package denied by catalog policy blocks runtime activation")
    func enabledPackageDeniedByCatalogPolicyBlocksRuntimeActivation() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Runtime Policy", primaryPath: "/tmp/runtime-policy")
        let package = PluginPackage(
            id: "runtime-draft",
            name: "Runtime Draft",
            icon: "puzzlepiece.extension",
            description: "Draft package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use draft", goal: "Run draft capability", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(issues.map(\.resourceKind) == [.policy])
        #expect(issues.first?.message.contains("catalog policy blocks runtime activation") == true)
    }

    @Test("pack-disabled enabled package does not block runtime activation")
    func packDisabledEnabledPackageDoesNotBlockRuntimeActivation() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let package = PluginPackage(
            id: "runtime-pack-disabled",
            name: "Runtime Pack Disabled",
            icon: "puzzlepiece.extension",
            description: "Disabled by pack policy",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [PluginSkill(
                name: "Missing Pack Skill",
                icon: "puzzlepiece.extension",
                description: "Missing skill",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Read carefully.",
                environmentKeys: [],
                environmentValues: []
            )],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved()
        )
        let workspace = Workspace(name: "Runtime Pack Policy", primaryPath: "/tmp/runtime-pack-policy")
        workspace.enabledCapabilityIDs = [package.id]
        workspace.enabledPackIDs = ["astra.pack.policy-test"]
        context.insert(workspace)
        let task = AgentTask(title: "Use disabled package", goal: "Run disabled capability", workspace: workspace)
        context.insert(task)
        try context.save()
        let packPolicy = runtimePackPolicy(restrictions: [
            AstraPackPolicyRestriction(
                id: "disable-runtime",
                contributionKind: "capabilityPackage",
                action: "disableCapability",
                effect: "restrict",
                targetID: package.id
            )
        ])

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            policyContext: CapabilityCatalogPolicyContext.currentUser(
                workspace: workspace,
                approvalRecords: [],
                packPolicy: packPolicy
            )
        )

        #expect(issues.isEmpty)
    }

    @Test("pack review-gated enabled package reports policy issue")
    func packReviewGatedEnabledPackageReportsPolicyIssue() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let package = PluginPackage(
            id: "runtime-pack-review",
            name: "Runtime Pack Review",
            icon: "puzzlepiece.extension",
            description: "Review gated by pack policy",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved()
        )
        let workspace = Workspace(name: "Runtime Pack Review", primaryPath: "/tmp/runtime-pack-review")
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use review-gated package", goal: "Run review-gated capability", workspace: workspace)
        context.insert(task)
        try context.save()
        let packPolicy = runtimePackPolicy(restrictions: [
            AstraPackPolicyRestriction(
                id: "review-runtime",
                contributionKind: "capabilityPackage",
                action: "requireReviewGate",
                effect: "restrict",
                targetID: package.id,
                message: "Runtime pack review is required."
            )
        ])

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            policyContext: CapabilityCatalogPolicyContext.currentUser(
                workspace: workspace,
                approvalRecords: [],
                packPolicy: packPolicy
            )
        )

        #expect(issues.map(\.resourceKind) == [.policy])
        #expect(issues.first?.message.contains("Runtime pack review is required") == true)
    }

    @Test("enabled package with unauthenticated prerequisite blocks runtime activation")
    func enabledPackageWithUnauthenticatedPrerequisiteBlocksRuntimeActivation() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let prerequisite = CommonCLIPrerequisites.githubAuth
        let package = PluginPackage(
            id: "runtime-auth-prereq",
            name: "Runtime Auth Prereq",
            icon: "terminal",
            description: "Package requiring CLI auth",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )
        let workspace = Workspace(name: "Runtime Auth", primaryPath: "/tmp/runtime-auth")
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use auth package", goal: "Use GitHub", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            prerequisiteStatuses: [prerequisite.id: .unauthenticated(detail: "not logged in")]
        )

        #expect(issues.map(\.resourceKind) == [.credential])
        #expect(issues.first?.resourceName == "GitHub login")
        #expect(issues.first?.message.contains("Run `gh auth login`.") == true)
    }

    @Test("inactive matching local tool reports active workspace wording")
    func inactiveMatchingLocalToolReportsActiveWorkspaceWording() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let package = PluginPackage(
            id: "runtime-local-tool",
            name: "Runtime Local Tool",
            icon: "terminal",
            description: "Package requiring a local tool",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [
                PluginLocalTool(
                    name: "Shared Helper",
                    description: "Shared helper",
                    icon: "terminal",
                    toolType: "cli",
                    command: "shared-helper",
                    arguments: ""
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )
        let workspace = Workspace(name: "Runtime Local Tool", primaryPath: "/tmp/runtime-local-tool")
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)

        let globalTool = LocalTool(name: "Shared Helper", toolType: "cli", command: "shared-helper")
        globalTool.isGlobal = true
        context.insert(globalTool)

        let task = AgentTask(title: "Use local tool", goal: "Use shared helper", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false
        )

        #expect(issues.map(\.resourceKind) == [.localTool])
        #expect(issues.first?.resourceName == "Shared Helper")
        #expect(issues.first?.message == "local tool Shared Helper is not active for this workspace")
    }

    @Test("runtime integrity validates matched local tool executable")
    func runtimeIntegrityValidatesMatchedLocalToolExecutable() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let packageCommand = "astra-missing-helper-\(UUID().uuidString)"
        let package = PluginPackage(
            id: "runtime-local-tool-executable",
            name: "Runtime Local Tool Executable",
            icon: "terminal",
            description: "Package requiring a local tool",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [
                PluginLocalTool(
                    name: "Shared Helper",
                    description: "Shared helper",
                    icon: "terminal",
                    toolType: "cli",
                    command: packageCommand,
                    arguments: ""
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )
        let workspace = Workspace(name: "Runtime Local Tool Executable", primaryPath: "/tmp/runtime-local-tool-executable")
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapabilityRuntimeIntegrityServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("shared-helper")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let configuredTool = LocalTool(name: "Shared Helper", toolType: "cli", command: executable.path)
        configuredTool.workspace = workspace
        context.insert(configuredTool)

        let task = AgentTask(title: "Use local tool", goal: "Use shared helper", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: true
        )

        #expect(issues.isEmpty)
    }

    @Test("unknown browser adapter IDs are runtime integrity issues")
    func unknownBrowserAdapterIDsAreRuntimeIntegrityIssues() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unknown Adapter", primaryPath: "/tmp/runtime-unknown-adapter")
        let package = PluginPackage(
            id: "unknown-browser-package",
            name: "Unknown Browser Package",
            icon: "safari",
            description: "Unknown browser adapter",
            author: "Tests",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: ["unknownAdapter"],
            governance: .builtInApproved(riskLevel: .high)
        )
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use browser", goal: "Use unknown adapter", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false
        )

        #expect(issues.map(\.resourceKind) == [.browserAdapter])
        #expect(issues.first?.resourceName == "unknownAdapter")
        #expect(issues.first?.message.contains("not known to ASTRA") == true)
    }

    private func runtimePackPolicy(restrictions: [AstraPackPolicyRestriction]) -> PackResolvedPolicy {
        AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [
                AstraPackManifest(
                    formatVersion: 1,
                    id: "astra.pack.policy-test",
                    name: "Policy Test",
                    version: "1.0.0",
                    coreAPIVersion: "1.0",
                    description: "Policy test pack.",
                    policyRestrictions: restrictions
                )
            ])
        )
    }
}
