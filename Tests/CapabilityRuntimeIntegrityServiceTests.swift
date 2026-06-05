import SwiftData
import Testing
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
}
