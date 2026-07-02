import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeWorkspacePersistenceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func runGit(_ arguments: [String], in directory: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func gitPathIsIgnored(_ relativePath: String, in repository: URL) throws -> Bool {
    let status = try runGit(["check-ignore", relativePath], in: repository)
    if status == 0 { return true }
    if status == 1 { return false }
    Issue.record("git check-ignore failed for \(relativePath) with status \(status)")
    return false
}

@MainActor
private func makeRichWorkspace(in context: ModelContext, root: String) throws -> Workspace {
    let workspace = Workspace(name: "Persistence", primaryPath: root)
    workspace.enabledCapabilityIDs = ["stanford.builder"]
    workspace.enabledPackIDs = ["astra.pack.devops"]
    workspace.shelfVisibilityOverrides = [
        "browser": true,
        "query": false
    ]
    workspace.isStarred = true
    workspace.recordInstalledPlugin(id: "stanford.builder", version: "1.0.0")
    context.insert(workspace)

    let connector = Connector(
        name: "Shared API",
        serviceType: "rest_api",
        icon: "network",
        connectorDescription: "REST connector",
        baseURL: "https://example.test",
        authMethod: "bearer"
    )
    connector.credentialKeys = ["API_TOKEN"]
    connector.credentialValues = ["plaintext-secret-should-not-export"]
    connector.configKeys = ["PROJECT"]
    connector.configValues = ["alpha"]
    connector.originPackageID = "stanford.builder"
    connector.originPackageVersion = "1.0.0"
    connector.originComponentID = "connector:rest_api:shared-api"
    connector.originComponentKind = "connector"
    connector.originSourceKind = "local"
    connector.workspace = workspace
    context.insert(connector)

    let tool = LocalTool(
        name: "Build Tool",
        toolDescription: "Runs builds",
        icon: "terminal",
        toolType: "cli",
        command: "swift",
        arguments: "build"
    )
    tool.originPackageID = "stanford.builder"
    tool.originPackageVersion = "1.0.0"
    tool.originComponentID = "tool:cli:swift:build-tool"
    tool.originComponentKind = "local_tool"
    tool.originSourceKind = "local"
    tool.workspace = workspace
    context.insert(tool)

    let skill = Skill(
        name: "Builder",
        icon: "hammer",
        skillDescription: "Builds projects",
        allowedTools: ["Read", "Bash"],
        disallowedTools: ["Write"],
        customTools: ["mcp__build__run"],
        behaviorInstructions: "Build only."
    )
    skill.environmentKeys = ["ENV"]
    skill.environmentValues = ["test"]
    skill.originPackageID = "stanford.builder"
    skill.originPackageVersion = "1.0.0"
    skill.originComponentID = "skill:builder"
    skill.originComponentKind = "skill"
    skill.originSourceKind = "local"
    skill.workspace = workspace
    connector.skill = skill
    tool.skill = skill
    context.insert(skill)

    let template = TaskTemplate(
        name: "Build Template",
        mainGoal: "Build {{target}}",
        workspace: workspace,
        icon: "rectangle.3.group",
        templateDescription: "Build task"
    )
    template.originPackageID = "stanford.builder"
    template.originPackageVersion = "1.0.0"
    template.originComponentID = "template:build-template"
    template.originComponentKind = "template"
    template.originSourceKind = "local"
    context.insert(template)

    let task = AgentTask(
        title: "Run build",
        goal: "Build the project",
        workspace: workspace,
        tokenBudget: 25_000,
        model: "claude-sonnet-4-6"
    )
    task.status = .completed
    task.unreadAt = Date(timeIntervalSince1970: 1_701_234_567)
    task.skills = [skill]
    TaskCapabilitySnapshotter.capture(for: task)
    context.insert(task)

    let run = TaskRun(task: task)
    run.status = .completed
    run.tokensUsed = 123
    run.inputTokens = 100
    run.outputTokens = 23
    run.exitCode = 0
    run.output = "Build complete"
    run.costUSD = 0.12
    run.stopReason = "completed"
    context.insert(run)

    let event = TaskEvent(task: task, type: "task.completed", payload: "Done", run: run)
    event.category = "lifecycle"
    context.insert(event)

    let artifact = Artifact(task: task, type: "file", path: "\(root)/build.log", content: "Build complete", version: 2)
    context.insert(artifact)

    try context.save()
    return workspace
}

@Suite("Workspace Persistence v11")
struct WorkspacePersistenceTests {
    @Test("shelf visibility overrides normalize persisted keys at the model boundary")
    @MainActor
    func shelfVisibilityOverridesNormalizePersistedKeys() {
        let workspace = Workspace(name: "Shelf Keys", primaryPath: "/tmp/shelf-keys")

        workspace.shelfVisibilityOverrides = [
            "  browser  ": true,
            "\nquery\t": false,
            "   ": true,
            "": false
        ]

        #expect(workspace.shelfVisibilityOverrides == [
            "browser": true,
            "query": false
        ])
        #expect(workspace.shelfVisibilityOverrideIDs == ["browser", "query"])
        #expect(workspace.shelfVisibilityOverrideValues == [true, false])
    }

    @Test("v11 export and import preserve IDs, profile state, history, artifacts, and redacted credentials")
    @MainActor
    func v11RoundTripPreservesDurableIDs() throws {
        let tempRoot = "/tmp/astra_persistence_\(UUID().uuidString)"
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: tempRoot)
        let sourceTask = try #require(workspace.tasks.first)
        let historicalTaskUpdatedAt = Date(timeIntervalSince1970: 1_700_000_123)
        sourceTask.isPinned = true
        sourceTask.isDone = true
        sourceTask.updatedAt = historicalTaskUpdatedAt
        let sourceRun = try #require(sourceTask.runs.first)
        let approvalGrant = PermissionGrant.shellCommand(executable: "gh", pattern: "search prs *")
        let openApprovalPayload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .shell(command: "gh search prs author:@me --limit 10", toolName: "Bash"),
            reason: "The shell command requires user approval by the effective ASTRA policy.",
            grants: [approvalGrant],
            requestID: "mirror-open-request"
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
            payload: openApprovalPayload,
            task: sourceTask,
            at: historicalTaskUpdatedAt
        )
        let grantPayload = TaskRuntimePermissionGrants.Payload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: .claudeCode,
            grants: [approvalGrant],
            approvedAt: historicalTaskUpdatedAt,
            source: "mirror-test"
        )
        sourceTask.runtimePermissionGrantsJSON = String(
            decoding: try JSONEncoder().encode([grantPayload]),
            as: UTF8.self
        )
        sourceRun.providerLaunchSignatureJSON = #"{"runtime":"claudeCode","model":"claude-sonnet-4-6"}"#
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.version == WorkspaceConfigManager.currentVersion)
        #expect(config.id == workspace.id.uuidString)
        #expect(config.isStarred == true)
        #expect(config.skills.first?.id == workspace.skills.first?.id.uuidString)
        #expect(config.connectors?.first?.id == workspace.connectors.first?.id.uuidString)
        #expect(config.localTools?.first?.id == workspace.localTools.first?.id.uuidString)
        #expect(config.templates?.first?.id == workspace.templates.first?.id.uuidString)
        #expect(config.skills.first?.originPackageID == "stanford.builder")
        #expect(config.connectors?.first?.originComponentKind == "connector")
        #expect(config.localTools?.first?.originComponentKind == "local_tool")
        #expect(config.templates?.first?.originComponentKind == "template")
        #expect(config.tasks?.first?.id == workspace.tasks.first?.id.uuidString)
        #expect(config.tasks?.first?.runs.first?.id == workspace.tasks.first?.runs.first?.id.uuidString)
        #expect(config.tasks?.first?.events.first?.id == workspace.tasks.first?.events.first?.id.uuidString)
        #expect(config.tasks?.first?.artifacts?.first?.id == workspace.tasks.first?.artifacts.first?.id.uuidString)
        #expect(config.tasks?.first?.skillIDs == [workspace.skills.first?.id.uuidString].compactMap { $0 })
        #expect(config.tasks?.first?.skillSnapshots?.first?.id == workspace.skills.first?.id.uuidString)
        #expect(config.tasks?.first?.isPinned == true)
        #expect(config.tasks?.first?.isDone == true)
        #expect(config.tasks?.first?.unreadAt == sourceTask.unreadAt)
        #expect(config.tasks?.first?.updatedAt == historicalTaskUpdatedAt)
        #expect(config.tasks?.first?.runtimePermissionOpenRequestsJSON == sourceTask.runtimePermissionOpenRequestsJSON)
        #expect(config.tasks?.first?.runtimePermissionGrantsJSON == sourceTask.runtimePermissionGrantsJSON)
        #expect(config.tasks?.first?.runs.first?.providerLaunchSignatureJSON == sourceRun.providerLaunchSignatureJSON)
        #expect(config.enabledCapabilityIDs == ["stanford.builder"])
        #expect(config.enabledPackIDs == ["astra.pack.devops"])
        #expect(config.shelfVisibilityOverrides == [
            "browser": true,
            "query": false
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(config), encoding: .utf8) ?? ""
        #expect(!json.contains("plaintext-secret-should-not-export"))
        #expect(json.contains("API_TOKEN"))
        #expect(config.skills.first?.environmentValues == ["test"])
        #expect(config.tasks?.first?.skillSnapshots?.first?.environmentValues == [""])

        let importedContainer = try makeWorkspacePersistenceContainer()
        let importedContext = importedContainer.mainContext
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContext)
        try importedContext.save()
        let importedTask = try #require(imported.tasks.first)
        let importedRun = try #require(importedTask.runs.first)

        #expect(imported.id == workspace.id)
        #expect(imported.isStarred == true)
        #expect(imported.skills.first?.id == workspace.skills.first?.id)
        #expect(imported.connectors.first?.id == workspace.connectors.first?.id)
        #expect(imported.connectors.first?.credentialKeys == ["API_TOKEN"])
        #expect(imported.connectors.first?.credentialValues == [""])
        #expect(imported.skills.first?.originPackageID == "stanford.builder")
        #expect(imported.connectors.first?.originPackageID == "stanford.builder")
        #expect(imported.localTools.first?.originPackageID == "stanford.builder")
        #expect(imported.templates.first?.originPackageID == "stanford.builder")
        #expect(imported.enabledCapabilityIDs == ["stanford.builder"])
        #expect(imported.enabledPackIDs == ["astra.pack.devops"])
        #expect(imported.shelfVisibilityOverrides == [
            "browser": true,
            "query": false
        ])
        #expect(imported.installedVersion(of: "stanford.builder") == "1.0.0")
        #expect(imported.tasks.first?.id == workspace.tasks.first?.id)
        #expect(imported.tasks.first?.isPinned == true)
        #expect(imported.tasks.first?.isDone == true)
        #expect(imported.tasks.first?.updatedAt == historicalTaskUpdatedAt)
        #expect(imported.tasks.first?.unreadAt == sourceTask.unreadAt)
        #expect(imported.tasks.first?.skills.first?.id == workspace.skills.first?.id)
        #expect(imported.tasks.first?.runs.first?.id == workspace.tasks.first?.runs.first?.id)
        #expect(imported.tasks.first?.events.first?.id == workspace.tasks.first?.events.first?.id)
        #expect(imported.tasks.first?.artifacts.first?.id == workspace.tasks.first?.artifacts.first?.id)
        #expect(importedTask.runtimePermissionOpenRequestsJSON == sourceTask.runtimePermissionOpenRequestsJSON)
        #expect(importedTask.runtimePermissionGrantsJSON == sourceTask.runtimePermissionGrantsJSON)
        #expect(importedRun.providerLaunchSignatureJSON == sourceRun.providerLaunchSignatureJSON)
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: importedTask))
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: importedTask) == [approvalGrant])
    }

    @Test("recovery export and import preserve WorkspaceApps, OAuth profiles, and task execution metadata")
    @MainActor
    func recoveryRoundTripPreservesAppsOAuthAndExecutionMetadata() throws {
        let root = "/tmp/astra_recovery_roundtrip_\(UUID().uuidString)"
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: root)
        let task = try #require(workspace.tasks.first)
        let forkedFromID = UUID()
        let schedule = TaskSchedule(name: "Morning Review", goal: "Summarize changes", workspace: workspace)
        context.insert(schedule)

        task.queuePosition = 42
        task.forkedFromID = forkedFromID
        task.forkedAtRunIndex = 3
        task.originScheduleID = schedule.id
        task.executionRootPath = "\(root)/worktrees/feature"

        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "review-dashboard",
            name: "Review Dashboard",
            icon: "chart.bar",
            appDescription: "Tracks review status",
            lifecycleStatus: .published,
            permissionMode: .approvalRequired,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/review-dashboard/manifest.json",
            appDirectoryRelativePath: ".astra/apps/review-dashboard",
            manifestDigest: "digest-current",
            publishedManifestDigest: "digest-published",
            lastKnownGoodManifestDigest: "digest-good",
            latestVersionNumber: 7,
            sourcePackageID: "review.pack",
            sourcePackageVersion: "2.0.0",
            sourcePackageDigest: "pack-digest"
        )
        app.lastOpenedAt = Date(timeIntervalSince1970: 1_710_000_001)
        app.lastRefreshedAt = Date(timeIntervalSince1970: 1_710_000_002)
        app.lastRunAt = Date(timeIntervalSince1970: 1_710_000_003)
        context.insert(app)

        let appRun = WorkspaceAppRun(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            actionID: "refresh",
            trigger: .automation,
            status: .waiting,
            startedAt: Date(timeIntervalSince1970: 1_710_000_004),
            inputSummary: "Refresh PR data",
            outputSummary: "Awaiting task",
            errorMessage: nil
        )
        appRun.completedAt = Date(timeIntervalSince1970: 1_710_000_005)
        appRun.linkedTaskID = task.id
        appRun.linkedArtifactPath = "artifacts/review.json"
        appRun.pendingActionID = "approval"
        appRun.pendingStepIndex = 5
        appRun.consumedTokens = 1234
        appRun.awaitedTaskIDs = [task.id]
        appRun.pendingApprovalActionID = "human-gate"
        context.insert(appRun)

        let appEvent = WorkspaceAppRunEvent(
            runID: appRun.id,
            workspaceID: workspace.id,
            appID: app.id,
            actionID: appRun.actionID,
            type: "workspace_app.run.waiting",
            payload: #"{"reason":"approval"}"#,
            timestamp: Date(timeIntervalSince1970: 1_710_000_006)
        )
        context.insert(appEvent)

        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "github.prs",
            contract: "pullRequest.read",
            operations: ["list", "get"],
            optional: false,
            status: .mapped,
            implementationID: "github.cli",
            provider: "github",
            transport: .cli
        )
        context.insert(binding)

        let automation = WorkspaceAppAutomationState(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            automationID: "daily-refresh",
            automationType: "schedule",
            actionID: "refresh",
            isEnabled: true,
            status: .enabled,
            lastRunAt: Date(timeIntervalSince1970: 1_710_000_007),
            nextRunAt: Date(timeIntervalSince1970: 1_710_086_400)
        )
        context.insert(automation)

        let profile = GoogleOAuthAccountProfile(
            subject: "google-subject-1",
            email: "Researcher@Example.COM",
            displayName: "Researcher",
            avatarURLString: "https://example.test/avatar.png",
            hostedDomain: "Example.COM",
            grantedScopes: ["https://www.googleapis.com/auth/drive.file"],
            requestedScopes: [
                "https://www.googleapis.com/auth/drive.file",
                "https://www.googleapis.com/auth/spreadsheets"
            ],
            authState: .needsReauth,
            authStateReason: "scope_upgrade",
            createdAt: Date(timeIntervalSince1970: 1_710_000_008),
            updatedAt: Date(timeIntervalSince1970: 1_710_000_009),
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_710_000_010)
        )
        context.insert(profile)
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.tasks?.first?.queuePosition == 42)
        #expect(config.tasks?.first?.forkedFromID == forkedFromID.uuidString)
        #expect(config.tasks?.first?.originScheduleID == schedule.id.uuidString)
        #expect(config.tasks?.first?.executionRootPath == "\(root)/worktrees/feature")
        #expect(config.workspaceApps?.first?.logicalID == "review-dashboard")
        #expect(config.workspaceAppRuns?.first?.awaitedTaskIDsJSON?.contains(task.id.uuidString) == true)
        #expect(config.workspaceAppRunEvents?.first?.type == "workspace_app.run.waiting")
        #expect(config.workspaceAppDependencyBindings?.first?.transport == "cli")
        #expect(config.workspaceAppAutomationStates?.first?.status == "enabled")
        #expect(config.googleOAuthAccountProfiles?.first?.authState == "needsReauth")

        let importedContainer = try makeWorkspacePersistenceContainer()
        let importedContext = importedContainer.mainContext
        let importedWorkspace = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContext)
        try importedContext.save()

        let importedTask = try #require(importedWorkspace.tasks.first)
        #expect(importedTask.queuePosition == 42)
        #expect(importedTask.forkedFromID == forkedFromID)
        #expect(importedTask.forkedAtRunIndex == 3)
        #expect(importedTask.originScheduleID == schedule.id)
        #expect(importedTask.executionRootPath == "\(root)/worktrees/feature")

        #expect(try importedContext.fetch(FetchDescriptor<WorkspaceApp>()).first?.publishedManifestDigest == "digest-published")
        #expect(try importedContext.fetch(FetchDescriptor<WorkspaceAppRun>()).first?.pendingApprovalActionID == "human-gate")
        #expect(try importedContext.fetch(FetchDescriptor<WorkspaceAppRunEvent>()).first?.payload == #"{"reason":"approval"}"#)
        #expect(try importedContext.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>()).first?.transportRaw == "cli")
        #expect(try importedContext.fetch(FetchDescriptor<WorkspaceAppAutomationState>()).first?.isEnabled == true)
        let importedProfile = try #require(importedContext.fetch(FetchDescriptor<GoogleOAuthAccountProfile>()).first)
        #expect(importedProfile.email == "researcher@example.com")
        #expect(importedProfile.authState == .needsReauth)
        #expect(importedProfile.authStateReason == "scope_upgrade")
    }

    @Test("legacy task configs without done state import as not done")
    @MainActor
    func legacyTaskConfigsWithoutDoneStateDefaultToOpen() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: "/tmp/astra_legacy_done_\(UUID().uuidString)")
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.version = 9
        config.tasks?[0].isDone = nil

        let importedContainer = try makeWorkspacePersistenceContainer()
        let importedContext = importedContainer.mainContext
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContext)
        try importedContext.save()

        #expect(imported.tasks.first?.isDone == false)
    }

    @Test("active worktree focus travels only when it remains inside imported workspace roots")
    @MainActor
    func activeWorkingPathRoundTrips() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext

        let root = "/tmp/astra_active_path_\(UUID().uuidString)"
        let worktree = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("repo-worktree", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let workspace = try makeRichWorkspace(in: context, root: root)
        workspace.activeWorkingPath = worktree

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.activeWorkingPath == worktree)

        // Worktree present inside an imported root -> focus is restored.
        let presentContainer = try makeWorkspacePersistenceContainer()
        let present = WorkspaceConfigManager.importWorkspace(from: config, modelContext: presentContainer.mainContext)
        #expect(present.activeWorkingPath == worktree)
        #expect(present.isUsingWorktree == true)

        // Worktree absent (different machine) -> focus resets to root.
        var staleConfig = config
        staleConfig.activeWorkingPath = "/gone/\(UUID().uuidString)"
        let absentContainer = try makeWorkspacePersistenceContainer()
        let absent = WorkspaceConfigManager.importWorkspace(from: staleConfig, modelContext: absentContainer.mainContext)
        #expect(absent.activeWorkingPath == nil)
        #expect(absent.isUsingWorktree == false)

        // Existing outside path from imported config -> focus resets to root so
        // new tasks cannot launch outside imported workspace roots.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-outside-wt-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }

        var outsideConfig = config
        outsideConfig.activeWorkingPath = outside
        let outsideContainer = try makeWorkspacePersistenceContainer()
        let outsideContext = outsideContainer.mainContext
        let imported = WorkspaceConfigManager.importWorkspace(from: outsideConfig, modelContext: outsideContext)
        let task = AgentTask(title: "Check root", goal: "Stay inside roots", workspace: imported)

        #expect(imported.activeWorkingPath == nil)
        #expect(imported.isUsingWorktree == false)
        #expect(task.executionRootPath == nil)
    }

    @Test("active working path import expands tilde and requires a directory")
    @MainActor
    func activeWorkingPathImportStandardizesTildeAndRequiresDirectory() throws {
        let relativeRoot = ".astra-active-path-\(UUID().uuidString)"
        let homeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeRoot, isDirectory: true)
        let activeDirectory = homeRoot.appendingPathComponent("repo-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeRoot) }

        let config = minimalWorkspaceConfig(
            name: "Tilde",
            path: "~/\(relativeRoot)",
            skillID: UUID().uuidString
        )
        var presentConfig = config
        presentConfig.activeWorkingPath = "~/\(relativeRoot)/repo-worktree"

        let presentContainer = try makeWorkspacePersistenceContainer()
        let present = WorkspaceConfigManager.importWorkspace(
            from: presentConfig,
            modelContext: presentContainer.mainContext
        )
        #expect(present.activeWorkingPath == WorkspacePathPresentation.standardizedPath(activeDirectory.path))

        let activeFile = homeRoot.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: activeFile.path, contents: Data())

        var fileConfig = config
        fileConfig.activeWorkingPath = "~/\(relativeRoot)/not-a-directory"
        let fileContainer = try makeWorkspacePersistenceContainer()
        let fileImported = WorkspaceConfigManager.importWorkspace(
            from: fileConfig,
            modelContext: fileContainer.mainContext
        )
        #expect(fileImported.activeWorkingPath == nil)
    }

    @Test("active working path import accepts canonical containment through symlinks")
    @MainActor
    func activeWorkingPathImportUsesCanonicalContainment() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-canonical-active-\(UUID().uuidString)", isDirectory: true)
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        let linkRoot = parent.appendingPathComponent("link", isDirectory: true)
        let activeDirectory = realRoot.appendingPathComponent("repo-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: parent) }

        var config = minimalWorkspaceConfig(name: "Linked", path: linkRoot.path, skillID: UUID().uuidString)
        config.activeWorkingPath = activeDirectory.path

        let container = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext)

        #expect(imported.activeWorkingPath == WorkspacePathPresentation.standardizedPath(activeDirectory.path))
        #expect(imported.isUsingWorktree == true)
    }

    @Test("active working path import treats filesystem root as containing descendants")
    @MainActor
    func activeWorkingPathImportHandlesFilesystemRootContainment() throws {
        let activeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-root-contained-active-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: activeDirectory) }

        var config = minimalWorkspaceConfig(name: "Root", path: "/", skillID: UUID().uuidString)
        config.activeWorkingPath = activeDirectory.path

        let container = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext)

        #expect(imported.activeWorkingPath == WorkspacePathPresentation.standardizedPath(activeDirectory.path))
        #expect(imported.isUsingWorktree == true)
    }

    @Test("active working path import rejects unrelated external git repositories")
    @MainActor
    func activeWorkingPathImportRejectsUnrelatedExternalGitRepositories() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-unrelated-worktree-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = parent.appendingPathComponent("repo", isDirectory: true)
        let repoGit = workspaceRoot.appendingPathComponent(".git", isDirectory: true)
        let activeDirectory = parent
            .appendingPathComponent("other-worktrees", isDirectory: true)
            .appendingPathComponent("feature", isDirectory: true)
        let activeGit = activeDirectory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        var config = minimalWorkspaceConfig(name: "Unrelated", path: workspaceRoot.path, skillID: UUID().uuidString)
        config.activeWorkingPath = activeDirectory.path

        let container = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext)

        #expect(imported.activeWorkingPath == nil)
        #expect(imported.isUsingWorktree == false)
    }

    @Test("active working path import accepts git-registered worktrees outside workspace roots")
    @MainActor
    func activeWorkingPathImportAllowsRegisteredWorktrees() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-registered-worktree-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = parent.appendingPathComponent("repo", isDirectory: true)
        let repoGit = workspaceRoot.appendingPathComponent(".git", isDirectory: true)
        let worktreeAdmin = repoGit
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feature", isDirectory: true)
        let externalWorktree = parent.appendingPathComponent("outside-feature", isDirectory: true)
        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try writeLinkedWorktree(activeDirectory: externalWorktree, adminDirectory: worktreeAdmin, commonGitDirectory: repoGit)
        defer { try? FileManager.default.removeItem(at: parent) }

        var config = minimalWorkspaceConfig(name: "Registered", path: workspaceRoot.path, skillID: UUID().uuidString)
        config.activeWorkingPath = externalWorktree.path

        let container = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext)

        #expect(imported.activeWorkingPath == WorkspacePathPresentation.standardizedPath(externalWorktree.path))
        #expect(imported.isUsingWorktree == true)
    }

    @Test("active working path import rejects forged worktree gitdir references")
    @MainActor
    func activeWorkingPathImportRejectsForgedWorktreeGitdirReferences() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-forged-worktree-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = parent.appendingPathComponent("repo", isDirectory: true)
        let repoGit = workspaceRoot.appendingPathComponent(".git", isDirectory: true)
        let forgedAdmin = repoGit
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feature", isDirectory: true)
        let externalWorktree = parent.appendingPathComponent("outside-feature", isDirectory: true)
        let unrelatedWorktree = parent.appendingPathComponent("other-feature", isDirectory: true)
        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalWorktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedWorktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: forgedAdmin, withIntermediateDirectories: true)
        try "gitdir: \(forgedAdmin.path)\n".write(
            to: externalWorktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try ".\n".write(
            to: forgedAdmin.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(unrelatedWorktree.appendingPathComponent(".git").path)\n".write(
            to: forgedAdmin.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        var config = minimalWorkspaceConfig(name: "Forged", path: workspaceRoot.path, skillID: UUID().uuidString)
        config.activeWorkingPath = externalWorktree.path

        let container = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext)

        #expect(imported.activeWorkingPath == nil)
        #expect(imported.isUsingWorktree == false)
    }

    @Test("active working path import resolves linked roots through the common git directory")
    @MainActor
    func activeWorkingPathImportResolvesLinkedRootsThroughCommonGitDirectory() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-linked-root-worktree-\(UUID().uuidString)", isDirectory: true)
        let commonGit = parent.appendingPathComponent("repo.git", isDirectory: true)
        let rootWorktree = parent.appendingPathComponent("main", isDirectory: true)
        let rootAdmin = commonGit
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
        let activeDirectory = parent.appendingPathComponent("feature", isDirectory: true)
        let activeAdmin = commonGit
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: commonGit, withIntermediateDirectories: true)
        try writeLinkedWorktree(activeDirectory: rootWorktree, adminDirectory: rootAdmin, commonGitDirectory: commonGit)
        try writeLinkedWorktree(activeDirectory: activeDirectory, adminDirectory: activeAdmin, commonGitDirectory: commonGit)
        defer { try? FileManager.default.removeItem(at: parent) }

        var config = minimalWorkspaceConfig(name: "Linked Root", path: rootWorktree.path, skillID: UUID().uuidString)
        config.activeWorkingPath = activeDirectory.path

        let container = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext)

        #expect(imported.activeWorkingPath == WorkspacePathPresentation.standardizedPath(activeDirectory.path))
        #expect(imported.isUsingWorktree == true)
    }

    @Test("import skips unsafe local tool definitions from workspace config")
    @MainActor
    func importSkipsUnsafeLocalToolDefinitions() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: "/tmp/astra_unsafe_tool_\(UUID().uuidString)")
        let toolID = workspace.localTools.first?.id.uuidString
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.localTools?[0].command = "sh -c curl https://evil.example"
        config.localTools?[0].arguments = ""
        config.skills[0].localToolIDs = toolID.map { [$0] }

        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)

        #expect(imported.localTools.isEmpty)
        #expect(imported.skills.first?.localTools.isEmpty == true)
    }

    @Test("import skips credentialed connectors over remote cleartext HTTP")
    @MainActor
    func importSkipsCredentialedHTTPConnectors() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: "/tmp/astra_unsafe_connector_\(UUID().uuidString)")
        let connectorID = workspace.connectors.first?.id.uuidString
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.connectors?[0].baseURL = "http://evil.example/api"
        config.skills[0].connectorIDs = connectorID.map { [$0] }

        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)

        #expect(imported.connectors.isEmpty)
        #expect(imported.skills.first?.connectors.isEmpty == true)
    }

    @Test("renamed resources relink by ID, not name")
    @MainActor
    func renamedResourcesRelinkByID() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: "/tmp/astra_renamed_\(UUID().uuidString)")
        let skillID = workspace.skills.first!.id.uuidString
        let connectorID = workspace.connectors.first!.id.uuidString
        let toolID = workspace.localTools.first!.id.uuidString

        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.skills[0].name = "Renamed Skill"
        config.skills[0].connectorNames = ["wrong connector name"]
        config.skills[0].localToolNames = ["wrong tool name"]
        config.connectors?[0].name = "Renamed Connector"
        config.localTools?[0].name = "Renamed Tool"
        config.tasks?[0].skillNames = ["wrong skill name"]

        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)
        let importedSkill = imported.skills.first { $0.id.uuidString == skillID }
        #expect(importedSkill?.connectors.first?.id.uuidString == connectorID)
        #expect(importedSkill?.localTools.first?.id.uuidString == toolID)
        #expect(imported.tasks.first?.skills.first?.id.uuidString == skillID)
    }

    @Test("duplicate resource names link correctly by ID")
    @MainActor
    func duplicateNamesUseIDs() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Duplicate Names", primaryPath: "/tmp/astra_dupes_\(UUID().uuidString)")
        context.insert(workspace)

        let skillA = Skill(name: "Same", allowedTools: ["Read"])
        let skillB = Skill(name: "Same", allowedTools: ["Bash"])
        skillA.workspace = workspace
        skillB.workspace = workspace
        context.insert(skillA)
        context.insert(skillB)

        let toolA = LocalTool(name: "Same Tool", command: "tool-a")
        let toolB = LocalTool(name: "Same Tool", command: "tool-b")
        toolA.workspace = workspace
        toolB.workspace = workspace
        toolA.skill = skillA
        toolB.skill = skillB
        context.insert(toolA)
        context.insert(toolB)

        let task = AgentTask(title: "Use B", goal: "Use second skill", workspace: workspace)
        task.skills = [skillB]
        TaskCapabilitySnapshotter.capture(for: task)
        context.insert(task)
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)
        let importedTaskSkill = imported.tasks.first?.skills.first
        let importedSkillB = imported.skills.first { $0.id == skillB.id }

        #expect(importedTaskSkill?.id == skillB.id)
        #expect(importedSkillB?.localTools.first?.id == toolB.id)
        #expect(importedSkillB?.localTools.first?.command == "tool-b")
    }

    @Test("schedule routing fields round-trip through workspace config")
    @MainActor
    func scheduleRoutingFieldsRoundTrip() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Scheduled", primaryPath: "/tmp/astra_schedule_\(UUID().uuidString)")
        context.insert(workspace)

        let sourceTask = AgentTask(title: "Source Thread", goal: "Watch this", workspace: workspace)
        context.insert(sourceTask)

        let schedule = TaskSchedule(name: "Watcher", goal: "Check updates", workspace: workspace)
        schedule.routineDescription = "Daily ticket watcher"
        schedule.routinePaths = ["/tmp/routine-docs"]
        schedule.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        schedule.model = AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
        schedule.conversationContext = "User asked for a concise summary."
        schedule.resultMode = .scheduleLog
        schedule.sourceTaskID = sourceTask.id
        schedule.runResultsJSON = """
        [{"date":"2026-04-24T10:00:00Z","status":"completed","summary":"OK","taskID":"\(UUID().uuidString)"}]
        """
        schedule.lastFiredAt = Date(timeIntervalSince1970: 1_777_000_000)
        context.insert(schedule)
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.schedules?.first?.conversationContext == schedule.conversationContext)
        #expect(config.schedules?.first?.resultMode == ScheduleResultMode.scheduleLog.rawValue)
        #expect(config.schedules?.first?.sourceTaskID == sourceTask.id.uuidString)
        #expect(config.schedules?.first?.runResultsJSON == schedule.runResultsJSON)
        #expect(config.schedules?.first?.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(config.schedules?.first?.lastFiredAt == schedule.lastFiredAt)
        #expect(config.schedules?.first?.routineDescription == schedule.routineDescription)
        #expect(config.schedules?.first?.routineInstructions == schedule.routineInstructions)
        #expect(config.schedules?.first?.routinePaths == schedule.routinePaths)

        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)
        let importedSchedule = try #require(imported.schedules.first)
        #expect(importedSchedule.conversationContext == schedule.conversationContext)
        #expect(importedSchedule.resultMode == .scheduleLog)
        #expect(importedSchedule.sourceTaskID == sourceTask.id)
        #expect(importedSchedule.runResultsJSON == schedule.runResultsJSON)
        #expect(importedSchedule.resolvedRuntimeID == .copilotCLI)
        #expect(importedSchedule.lastFiredAt == schedule.lastFiredAt)
        #expect(importedSchedule.routineDescription == schedule.routineDescription)
        #expect(importedSchedule.routineInstructions == schedule.routineInstructions)
        #expect(importedSchedule.routinePaths == schedule.routinePaths)
    }

    @Test("task import stores sanitized runtime ID")
    @MainActor
    func taskImportStoresSanitizedRuntimeID() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        var config = minimalWorkspaceConfig(
            name: "Imported Runtime",
            path: "/tmp/astra_import_runtime_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        let taskID = UUID().uuidString
        let now = Date(timeIntervalSince1970: 1_777_001_000)
        config.tasks = [
            WorkspaceConfigManager.TaskConfig(
                id: taskID,
                title: "Imported Copilot",
                goal: "Preserve sanitized runtime",
                status: TaskStatus.completed.rawValue,
                isPinned: nil,
                isDone: nil,
                inputs: [],
                constraints: [],
                acceptanceCriteria: [],
                tokenBudget: 25_000,
                tokensUsed: 0,
                model: AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI),
                runtimeID: "  \(AgentRuntimeID.copilotCLI.rawValue)\n",
                costUSD: 0,
                sessionId: nil,
                maxTurns: 25,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                unreadAt: nil,
                isolationStrategy: nil,
                validationStrategy: nil,
                testCommand: nil,
                draftMessages: nil,
                chainedGoal: nil,
                chainedFromID: nil,
                useAgentTeam: nil,
                teamSize: nil,
                teamInstructions: nil,
                templateID: nil,
                templateHooksJSON: nil,
                runs: [],
                events: [],
                artifacts: nil,
                skillIDs: nil,
                skillNames: [],
                skillSnapshots: nil
            )
        ]

        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: context)
        let importedTask = try #require(imported.tasks.first)

        #expect(importedTask.id.uuidString == taskID)
        #expect(importedTask.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(importedTask.resolvedRuntimeID == .copilotCLI)
    }

    @Test("imported task shell validation commands keep run-tests intent before durable storage")
    @MainActor
    func importedTaskShellValidationCommandsKeepRunTestsIntent() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        var config = minimalWorkspaceConfig(
            name: "Imported Unsafe Validation",
            path: "/tmp/astra_import_unsafe_validation_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        let now = Date(timeIntervalSince1970: 1_777_001_500)
        config.tasks = [
            WorkspaceConfigManager.TaskConfig(
                id: UUID().uuidString,
                title: "Imported Unsafe Tests",
                goal: "Do not persist untrusted shell composition",
                status: TaskStatus.queued.rawValue,
                isPinned: nil,
                isDone: nil,
                inputs: [],
                constraints: [],
                acceptanceCriteria: [],
                tokenBudget: 25_000,
                tokensUsed: 0,
                model: AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode),
                runtimeID: AgentRuntimeID.claudeCode.rawValue,
                costUSD: 0,
                sessionId: nil,
                maxTurns: 25,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                unreadAt: nil,
                isolationStrategy: nil,
                validationStrategy: ValidationStrategy.runTests.rawValue,
                testCommand: "swift test; touch should-not-run",
                draftMessages: nil,
                chainedGoal: nil,
                chainedFromID: nil,
                useAgentTeam: nil,
                teamSize: nil,
                teamInstructions: nil,
                templateID: nil,
                templateHooksJSON: nil,
                runs: [],
                events: [],
                artifacts: nil,
                skillIDs: nil,
                skillNames: [],
                skillSnapshots: nil
            )
        ]

        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: context)
        let importedTask = try #require(imported.tasks.first)

        #expect(importedTask.validationStrategy == .runTests)
        #expect(importedTask.testCommand.isEmpty)
    }

    @Test("imported task empty run-tests commands keep run-tests intent before durable storage")
    @MainActor
    func importedTaskEmptyRunTestsCommandsKeepRunTestsIntent() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        var config = minimalWorkspaceConfig(
            name: "Imported Empty Validation",
            path: "/tmp/astra_import_empty_validation_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        let now = Date(timeIntervalSince1970: 1_777_001_600)
        config.tasks = [
            WorkspaceConfigManager.TaskConfig(
                id: UUID().uuidString,
                title: "Imported Empty Tests",
                goal: "Keep the explicit run-tests requirement",
                status: TaskStatus.queued.rawValue,
                isPinned: nil,
                isDone: nil,
                inputs: [],
                constraints: [],
                acceptanceCriteria: [],
                tokenBudget: 25_000,
                tokensUsed: 0,
                model: AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode),
                runtimeID: AgentRuntimeID.claudeCode.rawValue,
                costUSD: 0,
                sessionId: nil,
                maxTurns: 25,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                unreadAt: nil,
                isolationStrategy: nil,
                validationStrategy: ValidationStrategy.runTests.rawValue,
                testCommand: "   ",
                draftMessages: nil,
                chainedGoal: nil,
                chainedFromID: nil,
                useAgentTeam: nil,
                teamSize: nil,
                teamInstructions: nil,
                templateID: nil,
                templateHooksJSON: nil,
                runs: [],
                events: [],
                artifacts: nil,
                skillIDs: nil,
                skillNames: [],
                skillSnapshots: nil
            )
        ]

        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: context)
        let importedTask = try #require(imported.tasks.first)

        #expect(importedTask.validationStrategy == .runTests)
        #expect(importedTask.testCommand.isEmpty)
    }

    @Test("imported task validation preserves allowed test commands")
    @MainActor
    func importedTaskValidationPreservesAllowedTestCommands() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(
            in: context,
            root: "/tmp/astra_import_allowed_validation_\(UUID().uuidString)"
        )
        let sourceTask = try #require(workspace.tasks.first)
        sourceTask.validationStrategy = .runTests
        sourceTask.testCommand = "swift test --filter WorkspacePersistenceTests"
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(
            from: config,
            modelContext: importedContainer.mainContext
        )
        let importedTask = try #require(imported.tasks.first)

        #expect(importedTask.validationStrategy == .runTests)
        #expect(importedTask.testCommand == "swift test --filter WorkspacePersistenceTests")
    }

    @Test("imported task validation clears package paths outside workspace")
    @MainActor
    func importedTaskValidationClearsPackagePathsOutsideWorkspace() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(
            in: context,
            root: "/tmp/astra_import_path_validation_\(UUID().uuidString)"
        )
        let sourceTask = try #require(workspace.tasks.first)
        sourceTask.validationStrategy = .runTests
        sourceTask.testCommand = "swift test --filter WorkspacePersistenceTests"
        try context.save()

        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        var tasks = try #require(config.tasks)
        tasks[0].testCommand = "swift test --package-path /tmp/astra_import_outside_\(UUID().uuidString)"
        config.tasks = tasks
        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(
            from: config,
            modelContext: importedContainer.mainContext
        )
        let importedTask = try #require(imported.tasks.first)

        #expect(importedTask.validationStrategy == .runTests)
        #expect(importedTask.testCommand.isEmpty)
    }

    @Test("legacy v4 configs use name fallback only when IDs are absent")
    @MainActor
    func legacyV4NameFallback() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: "/tmp/astra_legacy_\(UUID().uuidString)")

        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.version = 4
        config.id = nil
        config.skills[0].id = nil
        config.skills[0].connectorIDs = nil
        config.skills[0].localToolIDs = nil
        config.connectors?[0].id = nil
        config.localTools?[0].id = nil
        config.tasks?[0].skillIDs = nil
        config.tasks?[0].skillSnapshots = nil

        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)
        #expect(imported.tasks.first?.skills.first?.name == "Builder")
        #expect(imported.skills.first?.connectors.first?.name == "Shared API")
        #expect(imported.skills.first?.localTools.first?.name == "Build Tool")
    }

    @Test("task snapshots recreate missing skills and attached resources")
    @MainActor
    func snapshotFallbackRestoresMissingSkill() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: "/tmp/astra_snapshot_\(UUID().uuidString)")
        let originalSkillID = workspace.skills.first!.id
        let originalConnectorID = workspace.connectors.first!.id
        let originalToolID = workspace.localTools.first!.id

        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.skills = []
        config.connectors = []
        config.localTools = []
        config.tasks?[0].skillIDs = [originalSkillID.uuidString]

        let importedContainer = try makeWorkspacePersistenceContainer()
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContainer.mainContext)
        let restoredSkill = imported.tasks.first?.skills.first

        #expect(restoredSkill?.id == originalSkillID)
        #expect(restoredSkill?.name.contains("Restored") == true)
        #expect(restoredSkill?.connectors.first?.id == originalConnectorID)
        #expect(restoredSkill?.localTools.first?.id == originalToolID)
    }

    @Test("automatic recovery imports configs without duplicates")
    @MainActor
    func recoveryImportsWithoutDuplicates() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_recovery_\(UUID().uuidString)")
        let workspaceFolder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceContainer = try makeWorkspacePersistenceContainer()
        let sourceContext = sourceContainer.mainContext
        let sourceWorkspace = try makeRichWorkspace(in: sourceContext, root: workspaceFolder.path)
        let sourceTask = try #require(sourceWorkspace.tasks.first)
        sourceTask.isPinned = true
        sourceTask.isDone = true
        let sourceSchedule = TaskSchedule(name: "Recovered Routine", goal: "Keep running", workspace: sourceWorkspace)
        sourceSchedule.isEnabled = true
        sourceSchedule.nextFireDate = Date.distantFuture
        sourceContext.insert(sourceSchedule)
        try sourceContext.save()
        let configURL = workspaceFolder.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try WorkspaceConfigManager.exportToFile(workspace: sourceWorkspace, modelContext: sourceContext, url: configURL)

        let recoveryContainer = try makeWorkspacePersistenceContainer()
        let recoveryContext = recoveryContainer.mainContext
        let importedCount = WorkspaceRecoveryService.recoverMissingWorkspaces(
            modelContext: recoveryContext,
            extraRoots: [root.path],
            includeDefaultRoots: false
        )
        let secondImportCount = WorkspaceRecoveryService.recoverMissingWorkspaces(
            modelContext: recoveryContext,
            extraRoots: [root.path],
            includeDefaultRoots: false
        )
        let workspaces = (try? recoveryContext.fetch(FetchDescriptor<Workspace>())) ?? []

        #expect(importedCount == 1)
        #expect(secondImportCount == 0)
        #expect(workspaces.count == 1)
        #expect(workspaces.first?.id == sourceWorkspace.id)
        #expect(workspaces.first?.tasks.first?.isPinned == true)
        #expect(workspaces.first?.tasks.first?.isDone == true)
        #expect(workspaces.first?.schedules.first { $0.name == "Recovered Routine" }?.isEnabled == true)
    }

    @Test("automatic recovery resolves canonical support config to workspace root")
    @MainActor
    func recoveryImportsCanonicalSupportConfigAtWorkspaceRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_recovery_canonical_\(UUID().uuidString)")
        let workspaceFolder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceContainer = try makeWorkspacePersistenceContainer()
        let sourceContext = sourceContainer.mainContext
        let sourceWorkspace = try makeRichWorkspace(in: sourceContext, root: workspaceFolder.path)
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspaceFolder.path))
        try WorkspaceConfigManager.exportToFile(workspace: sourceWorkspace, modelContext: sourceContext, url: configURL)

        let recoveryContainer = try makeWorkspacePersistenceContainer()
        let recoveryContext = recoveryContainer.mainContext
        let importedCount = WorkspaceRecoveryService.recoverMissingWorkspaces(
            modelContext: recoveryContext,
            extraRoots: [root.path],
            includeDefaultRoots: false
        )
        let secondImportCount = WorkspaceRecoveryService.recoverMissingWorkspaces(
            modelContext: recoveryContext,
            extraRoots: [root.path],
            includeDefaultRoots: false
        )
        let workspaces = (try? recoveryContext.fetch(FetchDescriptor<Workspace>())) ?? []

        #expect(importedCount == 1)
        #expect(secondImportCount == 0)
        #expect(workspaces.count == 1)
        #expect(workspaces.first?.primaryPath == workspaceFolder.path)
        #expect(workspaces.first?.primaryPath != configURL.deletingLastPathComponent().path)
    }

    @Test("async launch recovery resolves canonical support config to workspace root")
    @MainActor
    func asyncLaunchRecoveryImportsCanonicalSupportConfigAtWorkspaceRoot() async throws {
        let root = URL(fileURLWithPath: "/tmp/astra_async_recovery_canonical_\(UUID().uuidString)")
        let workspaceFolder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceContainer = try makeWorkspacePersistenceContainer()
        let sourceContext = sourceContainer.mainContext
        let sourceWorkspace = try makeRichWorkspace(in: sourceContext, root: workspaceFolder.path)
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspaceFolder.path))
        try WorkspaceConfigManager.exportToFile(workspace: sourceWorkspace, modelContext: sourceContext, url: configURL)

        let recoveryContainer = try makeWorkspacePersistenceContainer()
        let recoveryContext = recoveryContainer.mainContext
        WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: recoveryContext,
            extraRoots: [root.path],
            includeDefaultRoots: false
        )

        var workspaces: [Workspace] = []
        for _ in 0..<100 {
            workspaces = (try? recoveryContext.fetch(FetchDescriptor<Workspace>())) ?? []
            if !workspaces.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(workspaces.count == 1)
        #expect(workspaces.first?.primaryPath == workspaceFolder.path)
        #expect(workspaces.first?.primaryPath != configURL.deletingLastPathComponent().path)
    }

    @Test("deleting workspace removes canonical and legacy generated mirrors")
    @MainActor
    func deletingWorkspaceRemovesCanonicalAndLegacyGeneratedMirrors() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_delete_legacy_mirror_\(UUID().uuidString)")
        let workspaceFolder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: workspaceFolder.path)
        let canonicalURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspaceFolder.path))
        let legacyURL = URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspaceFolder.path))
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: canonicalURL)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: legacyURL)

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        _ = coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace])

        #expect(!FileManager.default.fileExists(atPath: canonicalURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))

        let recoveryContainer = try makeWorkspacePersistenceContainer()
        let recoveryContext = recoveryContainer.mainContext
        let importedCount = WorkspaceRecoveryService.recoverMissingWorkspaces(
            modelContext: recoveryContext,
            extraRoots: [root.path],
            includeDefaultRoots: false
        )
        let recoveredWorkspaces = (try? recoveryContext.fetch(FetchDescriptor<Workspace>())) ?? []

        #expect(importedCount == 0)
        #expect(recoveredWorkspaces.isEmpty)
    }

    @Test("automatic recovery skips privacy-sensitive user media folders")
    func recoverySkipsPrivacySensitiveUserMediaFolders() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_recovery_privacy_\(UUID().uuidString)")
        let ordinaryWorkspace = root.appendingPathComponent("Projects/safe-project", isDirectory: true)
        let photosWorkspace = root.appendingPathComponent("Pictures/photo-project", isDirectory: true)
        let musicWorkspace = root.appendingPathComponent("Music/music-project", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photosWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: musicWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: ordinaryWorkspace.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))
        try Data("{}".utf8).write(to: photosWorkspace.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))
        try Data("{}".utf8).write(to: musicWorkspace.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))

        let configs = WorkspaceRecoveryService.discoverWorkspaceConfigFiles(
            extraRoots: [root.path],
            includeDefaultRoots: false,
            privacyHomeDirectory: root
        )
        let discoveredParents = Set(configs.map { $0.deletingLastPathComponent().path })

        #expect(discoveredParents.count == 1)
        #expect(discoveredParents.first?.hasSuffix("/Projects/safe-project") == true)
        #expect(!discoveredParents.contains { $0.hasSuffix("/Pictures/photo-project") })
        #expect(!discoveredParents.contains { $0.hasSuffix("/Music/music-project") })
    }

    @Test("auto-export skips unavailable workspace paths")
    func autoExportTargetSkipsUnavailableWorkspacePaths() {
        let missing = "/tmp/astra_missing_workspace_\(UUID().uuidString)"
        let missingTarget = WorkspaceConfigManager.autoExportTarget(for: missing)

        #expect(missingTarget.url == nil)
        #expect(missingTarget.reason == "primary_path_unavailable")
    }

    @Test("auto-export targets existing workspace folders")
    func autoExportTargetUsesExistingWorkspaceFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_export_target_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = WorkspaceConfigManager.autoExportTarget(for: root.path)

        #expect(target.reason == "ready")
        #expect(target.url?.path == root
            .appendingPathComponent(WorkspaceFileLayout.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
            .path)
    }

    @Test("workspace layout keeps generated mirror under ASTRA metadata")
    func workspaceLayoutUsesSupportDirectoryForGeneratedMirror() {
        let root = "/tmp/astra_layout_\(UUID().uuidString)"

        #expect(
            WorkspaceFileLayout.workspaceConfigFile(for: root)
                == "\(root)/.astra/\(WorkspaceFileLayout.workspaceConfigFileName)"
        )
        #expect(WorkspaceFileLayout.legacyWorkspaceConfigFile(for: root) == "\(root)/\(WorkspaceFileLayout.workspaceConfigFileName)")
    }

    @Test("workspace import discovery accepts canonical support config before legacy root config")
    func importDiscoveryPrefersSupportConfigAndKeepsLegacyRootCompatibility() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_import_discovery_\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent(WorkspaceFileLayout.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let canonical = support.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        let legacy = root.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try Data("{}".utf8).write(to: canonical)
        try Data("{}".utf8).write(to: legacy)

        let preferred = try #require(WorkspaceImportDiscovery.candidates(for: [root]).first)
        #expect(preferred.folderURL.path == root.path)
        #expect(preferred.configURL?.path == canonical.path)

        try FileManager.default.removeItem(at: canonical)
        let legacyCandidate = try #require(WorkspaceImportDiscovery.candidates(for: [root]).first)
        #expect(legacyCandidate.folderURL.path == root.path)
        #expect(legacyCandidate.configURL?.path == legacy.path)
    }

    @Test("workspace config file selection resolves support mirror to workspace root")
    func supportMirrorSelectionResolvesWorkspaceRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_config_selection_\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent(WorkspaceFileLayout.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let canonical = support.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try Data("{}".utf8).write(to: canonical)

        let candidate = try #require(WorkspaceImportDiscovery.candidates(for: [canonical]).first)
        #expect(candidate.folderURL.path == root.path)
        #expect(candidate.configURL?.path == canonical.path)
    }

    @Test("workspace generated state is excluded through local git info exclude")
    func generatedWorkspaceStateIsExcludedFromGitCheckout() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_git_exclude_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(try runGit(["init", "-q"], in: root) == 0)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = root.appendingPathComponent(".git/info", isDirectory: true)
        let exclude = info.appendingPathComponent("exclude")
        try "# user excludes\n".write(to: exclude, atomically: true, encoding: .utf8)

        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: root.path)
        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: root.path)

        let contents = try String(contentsOf: exclude, encoding: .utf8)
        #expect(contents.contains("# user excludes"))
        #expect(contents.components(separatedBy: "/.astra/").count == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))

        let rootGeneratedFile = root
            .appendingPathComponent(".astra", isDirectory: true)
            .appendingPathComponent("state.json")
        let nestedGeneratedFile = root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent(".astra", isDirectory: true)
            .appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: rootGeneratedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedGeneratedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: rootGeneratedFile)
        try Data("{}".utf8).write(to: nestedGeneratedFile)

        #expect(try gitPathIsIgnored(".astra/state.json", in: root) == true)
        #expect(try gitPathIsIgnored("nested/.astra/state.json", in: root) == false)
    }

    @Test("workspace generated state is excluded when workspace is nested in a git checkout")
    func nestedWorkspaceGeneratedStateIsExcludedFromContainingGitCheckout() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_nested_git_exclude_\(UUID().uuidString)", isDirectory: true)
        let workspace = root
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(try runGit(["init", "-q"], in: root) == 0)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = root.appendingPathComponent(".git/info", isDirectory: true)
        let exclude = info.appendingPathComponent("exclude")
        try "# user excludes\n".write(to: exclude, atomically: true, encoding: .utf8)

        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspace.path)
        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspace.path)

        let contents = try String(contentsOf: exclude, encoding: .utf8)
        #expect(contents.contains("# user excludes"))
        #expect(contents.components(separatedBy: "/packages/project/.astra/").count == 2)
        #expect(!contents.split(whereSeparator: \.isNewline).contains(".astra/"))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".gitignore").path))

        let intendedFile = root
            .appendingPathComponent("packages/project/.astra/state.json", isDirectory: false)
        let siblingFile = root
            .appendingPathComponent("packages/other/.astra/state.json", isDirectory: false)
        let rootGeneratedFile = root
            .appendingPathComponent(".astra/state.json", isDirectory: false)
        try FileManager.default.createDirectory(at: intendedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootGeneratedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: intendedFile)
        try Data("{}".utf8).write(to: siblingFile)
        try Data("{}".utf8).write(to: rootGeneratedFile)

        #expect(try gitPathIsIgnored("packages/project/.astra/state.json", in: root) == true)
        #expect(try gitPathIsIgnored("packages/other/.astra/state.json", in: root) == false)
        #expect(try gitPathIsIgnored(".astra/state.json", in: root) == false)
    }

    @Test("nested workspace generated state escapes git ignore metacharacters")
    func nestedWorkspaceGeneratedStateEscapesGitIgnorePatterns() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_nested_git_escape_\(UUID().uuidString)", isDirectory: true)
        let info = root.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaces = [
            ("#project", "/packages/\\#project/.astra/"),
            ("!project", "/packages/\\!project/.astra/"),
            ("project[1]", "/packages/project\\[1\\]/.astra/"),
            ("project*?", "/packages/project\\*\\?/.astra/"),
            (" spaced project ", "/packages/\\ spaced\\ project\\ /.astra/")
        ]

        for (name, _) in workspaces {
            let workspace = root
                .appendingPathComponent("packages", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspace.path)
            try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspace.path)
        }

        let contents = try String(contentsOf: info.appendingPathComponent("exclude"), encoding: .utf8)
        for (_, expectedPattern) in workspaces {
            #expect(contents.components(separatedBy: expectedPattern).count == 2)
        }
    }

    @Test("workspace mirror export bounds runs events and output")
    @MainActor
    func workspaceMirrorExportBoundsRunsEventsAndOutput() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Bounded Mirror", primaryPath: "/tmp/astra_bounded_mirror_\(UUID().uuidString)")
        context.insert(workspace)
        let task = AgentTask(title: "Long history", goal: "Create lots of output", workspace: workspace)
        context.insert(task)

        for index in 0..<15 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: TimeInterval(index))
            run.output = String(repeating: "\(index)", count: 12_000)
            context.insert(run)

            let event = TaskEvent(
                task: task,
                type: "task.event.\(index)",
                payload: String(repeating: "payload-\(index)", count: 2_000),
                run: run
            )
            event.timestamp = Date(timeIntervalSince1970: TimeInterval(index))
            context.insert(event)
        }
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let mirroredTask = try #require(config.tasks?.first)
        let firstRun = try #require(mirroredTask.runs.first)
        let firstEvent = try #require(mirroredTask.events.first)

        #expect(mirroredTask.runs.count == WorkspaceConfigManager.MirrorLimits.maxRunsPerTask)
        #expect(mirroredTask.events.count == WorkspaceConfigManager.MirrorLimits.maxEventsPerTask)
        #expect(firstRun.output.contains("[ASTRA mirror truncated"))
        #expect(firstEvent.payload.contains("[ASTRA mirror truncated"))
        #expect(firstRun.output.count <= WorkspaceConfigManager.MirrorLimits.maxRunOutputCharacters)
        #expect(firstEvent.payload.count <= WorkspaceConfigManager.MirrorLimits.maxEventPayloadCharacters)
        #expect(mirroredTask.runs.map(\.startedAt) == mirroredTask.runs.map(\.startedAt).sorted())
        #expect(mirroredTask.events.map(\.timestamp) == mirroredTask.events.map(\.timestamp).sorted())
    }

    @Test("workspace mirror export breaks task run and event timestamp ties by UUID")
    @MainActor
    func workspaceMirrorExportBreaksTaskRunEventTimestampTiesByUUID() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Tie Bounded Mirror", primaryPath: "/tmp/astra_tie_bounded_mirror_\(UUID().uuidString)")
        context.insert(workspace)
        let task = AgentTask(title: "Equal timestamps", goal: "Create tie keys", workspace: workspace)
        context.insert(task)

        let runIDs = (0..<11).map { UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", $0))")! }
        let eventIDs = (0..<11).map { UUID(uuidString: "10000000-0000-0000-0000-\(String(format: "%012d", $0))")! }
        let sharedDate = Date(timeIntervalSince1970: 42)

        for index in (0..<11).reversed() {
            let run = TaskRun(task: task)
            run.id = runIDs[index]
            run.startedAt = sharedDate
            context.insert(run)

            let event = TaskEvent(
                task: task,
                type: "task.tie.\(index)",
                payload: "{}",
                run: run
            )
            event.id = eventIDs[index]
            event.timestamp = sharedDate
            context.insert(event)
        }
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let mirroredTask = try #require(config.tasks?.first)
        let expectedRunIDs = runIDs.suffix(WorkspaceConfigManager.MirrorLimits.maxRunsPerTask).map(\.uuidString)
        let expectedEventIDs = eventIDs.suffix(WorkspaceConfigManager.MirrorLimits.maxEventsPerTask).map(\.uuidString)

        #expect(mirroredTask.runs.map(\.id) == expectedRunIDs)
        #expect(mirroredTask.events.map(\.id) == expectedEventIDs)
    }

    @Test("workspace mirror export bounds workspace app runs events and output")
    @MainActor
    func workspaceMirrorExportBoundsWorkspaceAppRunsEventsAndOutput() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Bounded App Mirror", primaryPath: "/tmp/astra_bounded_app_mirror_\(UUID().uuidString)")
        context.insert(workspace)
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "review-dashboard",
            name: "Review Dashboard",
            icon: "chart.bar",
            appDescription: "Tracks review status",
            lifecycleStatus: .published,
            permissionMode: .approvalRequired,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/review-dashboard/manifest.json",
            appDirectoryRelativePath: ".astra/apps/review-dashboard",
            manifestDigest: "digest-current"
        )
        context.insert(app)

        for index in 0..<15 {
            let run = WorkspaceAppRun(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                actionID: "refresh-\(index)",
                trigger: .automation,
                status: .completed,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                inputSummary: "Refresh PR data",
                outputSummary: String(repeating: "summary-\(index)", count: 2_000),
                errorMessage: nil
            )
            context.insert(run)

            let event = WorkspaceAppRunEvent(
                runID: run.id,
                workspaceID: workspace.id,
                appID: app.id,
                actionID: run.actionID,
                type: "workspace_app.run.event.\(index)",
                payload: String(repeating: "payload-\(index)", count: 2_000),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
            context.insert(event)
        }
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let mirroredRuns = try #require(config.workspaceAppRuns)
        let mirroredEvents = try #require(config.workspaceAppRunEvents)
        let firstRun = try #require(mirroredRuns.first)
        let firstEvent = try #require(mirroredEvents.first)

        #expect(mirroredRuns.count == WorkspaceConfigManager.MirrorLimits.maxWorkspaceAppRuns)
        #expect(mirroredEvents.count == WorkspaceConfigManager.MirrorLimits.maxWorkspaceAppRunEvents)
        #expect(firstRun.outputSummary.contains("[ASTRA mirror truncated"))
        #expect(firstEvent.payload.contains("[ASTRA mirror truncated"))
        #expect(firstRun.outputSummary.count <= WorkspaceConfigManager.MirrorLimits.maxWorkspaceAppRunOutputCharacters)
        #expect(firstEvent.payload.count <= WorkspaceConfigManager.MirrorLimits.maxWorkspaceAppRunEventPayloadCharacters)
        #expect(mirroredRuns.map(\.startedAt) == mirroredRuns.map(\.startedAt).sorted())
        #expect(mirroredEvents.map(\.timestamp) == mirroredEvents.map(\.timestamp).sorted())
        #expect(mirroredRuns.first?.actionID == "refresh-5")
        #expect(mirroredEvents.first?.type == "workspace_app.run.event.5")
    }

    @Test("workspace mirror export keeps workspace app run event references closed")
    @MainActor
    func workspaceMirrorExportKeepsWorkspaceAppRunEventReferencesClosed() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Closed App Mirror", primaryPath: "/tmp/astra_closed_app_mirror_\(UUID().uuidString)")
        context.insert(workspace)
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "review-dashboard",
            name: "Review Dashboard",
            icon: "chart.bar",
            appDescription: "Tracks review status",
            lifecycleStatus: .published,
            permissionMode: .approvalRequired,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/review-dashboard/manifest.json",
            appDirectoryRelativePath: ".astra/apps/review-dashboard",
            manifestDigest: "digest-current"
        )
        context.insert(app)

        var runs: [WorkspaceAppRun] = []
        for index in 0..<11 {
            let run = WorkspaceAppRun(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                actionID: "refresh-\(index)",
                trigger: .automation,
                status: .completed,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                inputSummary: "Refresh PR data",
                outputSummary: "Done",
                errorMessage: nil
            )
            runs.append(run)
            context.insert(run)

            if index > 0 {
                context.insert(WorkspaceAppRunEvent(
                    runID: run.id,
                    workspaceID: workspace.id,
                    appID: app.id,
                    actionID: run.actionID,
                    type: "workspace_app.run.event.\(index)",
                    payload: "{}",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index))
                ))
            }
        }

        context.insert(WorkspaceAppRunEvent(
            runID: runs[0].id,
            workspaceID: workspace.id,
            appID: app.id,
            actionID: runs[0].actionID,
            type: "workspace_app.run.event.omitted_parent",
            payload: "{}",
            timestamp: Date(timeIntervalSince1970: 100)
        ))
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let mirroredRuns = try #require(config.workspaceAppRuns)
        let mirroredEvents = try #require(config.workspaceAppRunEvents)
        let exportedRunIDs = Set(mirroredRuns.compactMap(\.id))

        #expect(mirroredRuns.map(\.actionID) == (1..<11).map { "refresh-\($0)" })
        #expect(mirroredEvents.allSatisfy { exportedRunIDs.contains($0.runID) })
        #expect(!mirroredEvents.contains { $0.type == "workspace_app.run.event.omitted_parent" })
    }

    @Test("workspace export result reports write diagnostics")
    @MainActor
    func workspaceExportResultReportsWriteDiagnostics() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_export_result_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Export Result", primaryPath: root.path)
        context.insert(workspace)

        let target = root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        let result = WorkspaceConfigManager.exportToFileResult(
            workspace: workspace,
            modelContext: context,
            url: target
        )

        #expect(result.status == .writeFailed)
        #expect(!result.didExport)
        #expect(result.path == target.path)
        #expect(result.parentExists == false)
        #expect(result.auditFields["result"] == "writeFailed")
        #expect(result.auditFields["error_domain"] != nil)
    }

    @Test("workspace load result separates unreadable and decode failures")
    func workspaceLoadResultReportsDecodeFailure() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_load_result_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigManager.loadConfigResult(from: url)

        #expect(result.status == .decodeFailed)
        #expect(!result.didLoad)
        #expect(result.path == url.path)
        #expect(result.errorDescription?.isEmpty == false)
    }

    @Test("workspace import result reports imported and skipped resource counts")
    @MainActor
    func workspaceImportResultReportsCounts() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        var config = minimalWorkspaceConfig(
            name: "Import Result",
            path: "/tmp/astra_import_result_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        config.skills[0].name = "Project Skill"
        config.connectors = [
            WorkspaceConfigManager.ConnectorConfig(
                id: UUID().uuidString,
                name: "Unsafe API",
                serviceType: "custom",
                icon: "link",
                description: "",
                baseURL: "http://example.com",
                authMethod: "bearer",
                credentialKeys: ["TOKEN"],
                configKeys: [],
                configValues: [],
                notes: ""
            )
        ]
        config.localTools = [
            WorkspaceConfigManager.LocalToolConfig(
                id: UUID().uuidString,
                name: "Unsafe Tool",
                description: "",
                icon: "terminal",
                toolType: "command",
                command: "bad command",
                arguments: ""
            )
        ]

        let result = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: context)

        #expect(result.status == .imported)
        #expect(result.didImport)
        #expect(result.skillCount == 1)
        #expect(result.connectorCount == 0)
        #expect(result.localToolCount == 0)
        #expect(result.skippedConnectorCount == 1)
        #expect(result.skippedLocalToolCount == 1)
        #expect(result.auditFields["skipped_connector_count"] == "1")
    }

    @Test("imported schedules are quarantined until local re-enable")
    @MainActor
    func importedSchedulesAreQuarantinedUntilLocalReenable() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        var config = minimalWorkspaceConfig(
            name: "Imported Schedule",
            path: "/tmp/astra_import_schedule_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        let dueDate = Date.distantPast
        config.schedules = [
            WorkspaceConfigManager.ScheduleConfig(
                id: UUID().uuidString,
                name: "Enabled Routine",
                isEnabled: true,
                goal: "Launch from imported config",
                templateVariablesJSON: "{}",
                model: "claude-sonnet-4-6",
                tokenBudget: 50_000,
                scheduleType: ScheduleType.once.rawValue,
                nextFireDate: dueDate,
                intervalSeconds: 3600,
                dailyHour: 9,
                dailyMinute: 0,
                weeklyDayOfWeek: 2,
                fireCount: 0
            ),
            WorkspaceConfigManager.ScheduleConfig(
                id: UUID().uuidString,
                name: "Already Disabled Routine",
                isEnabled: false,
                goal: "Already disabled before import",
                templateVariablesJSON: "{}",
                model: "claude-sonnet-4-6",
                tokenBudget: 50_000,
                scheduleType: ScheduleType.once.rawValue,
                nextFireDate: dueDate,
                intervalSeconds: 3600,
                dailyHour: 9,
                dailyMinute: 0,
                weeklyDayOfWeek: 2,
                fireCount: 0
            )
        ]

        let result = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: context)
        let importedSchedule = try #require(result.workspace.schedules.first { $0.name == "Enabled Routine" })
        let alreadyDisabled = try #require(result.workspace.schedules.first { $0.name == "Already Disabled Routine" })

        #expect(importedSchedule.isEnabled == false)
        #expect(alreadyDisabled.isEnabled == false)
        #expect(importedSchedule.nextFireDate == dueDate)
        #expect(importedSchedule.goal == "Launch from imported config")
        #expect(result.quarantinedScheduleCount == 1)
        #expect(result.auditFields["quarantined_schedule_count"] == "1")

        let scheduler = TaskScheduler()
        let queue = TaskQueue()
        scheduler.checkAndFire(modelContext: context, taskQueue: queue)
        #expect(result.workspace.tasks.filter { $0.originScheduleID == importedSchedule.id }.isEmpty)
        #expect(queue.hasProcessingLoop == false)

        importedSchedule.isEnabled = true
        try context.save()
        #expect(importedSchedule.isEnabled == true)
    }

    @Test("trusted local schedule reimports preserve enabled state")
    @MainActor
    func trustedLocalScheduleReimportsPreserveEnabledState() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        var config = minimalWorkspaceConfig(
            name: "Trusted Reimport",
            path: "/tmp/astra_trusted_schedule_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        config.schedules = [
            WorkspaceConfigManager.ScheduleConfig(
                id: UUID().uuidString,
                name: "Enabled Local Routine",
                isEnabled: true,
                goal: "Keep running after trusted replace",
                templateVariablesJSON: "{}",
                model: "claude-sonnet-4-6",
                tokenBudget: 50_000,
                scheduleType: ScheduleType.once.rawValue,
                nextFireDate: Date.distantFuture,
                intervalSeconds: 3600,
                dailyHour: 9,
                dailyMinute: 0,
                weeklyDayOfWeek: 2,
                fireCount: 0
            )
        ]

        let result = WorkspaceConfigManager.importWorkspaceResult(
            from: config,
            modelContext: context,
            scheduleTrustPolicy: .preserveEnabledState
        )
        let importedSchedule = try #require(result.workspace.schedules.first)

        #expect(importedSchedule.isEnabled == true)
        #expect(result.quarantinedScheduleCount == 0)
        #expect(result.auditFields["quarantined_schedule_count"] == "0")
    }

    @Test("folder replace preserves trusted local enabled schedules")
    @MainActor
    func folderReplacePreservesTrustedLocalEnabledSchedules() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra_trusted_replace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let workspace = Workspace(name: "Trusted Replace", primaryPath: folder.path)
        context.insert(workspace)
        let schedule = TaskSchedule(name: "Enabled Local Routine", goal: "Keep running", workspace: workspace)
        schedule.isEnabled = true
        context.insert(schedule)
        try context.save()

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        let replaced = try #require(coordinator.createWorkspaceFromFolder(
            folder,
            existingWorkspaces: [workspace],
            askDuplicateAction: { _, _ in .replace }
        ))
        let replacedSchedule = try #require(replaced.schedules.first)

        #expect(replaced.primaryPath == folder.path)
        #expect(replacedSchedule.isEnabled == true)
    }

    @Test("configured folder replace preserves trusted local enabled schedules")
    @MainActor
    func configuredFolderReplacePreservesTrustedLocalEnabledSchedules() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra_configured_trusted_replace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let workspace = Workspace(name: "Configured Trusted Replace", primaryPath: folder.path)
        context.insert(workspace)
        let schedule = TaskSchedule(name: "Enabled Config Routine", goal: "Keep running", workspace: workspace)
        schedule.isEnabled = true
        context.insert(schedule)
        try context.save()

        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try WorkspaceConfigManager.exportToFile(
            workspace: workspace,
            modelContext: context,
            url: configURL
        )

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        let replaced = try #require(coordinator.importFromConfig(
            at: configURL,
            existingWorkspaces: [workspace],
            askDuplicateAction: { _, _ in .replace }
        ))
        let replacedSchedule = try #require(replaced.schedules.first)

        #expect(replaced.primaryPath == folder.standardizedFileURL.path)
        #expect(replacedSchedule.isEnabled == true)
    }

    @Test("external config replace still quarantines enabled schedules")
    @MainActor
    func externalConfigReplaceStillQuarantinesEnabledSchedules() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let localFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra_local_replace_\(UUID().uuidString)", isDirectory: true)
        let externalFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra_external_replace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: localFolder)
            try? FileManager.default.removeItem(at: externalFolder)
        }

        let workspace = Workspace(name: "External Replace", primaryPath: localFolder.path)
        context.insert(workspace)
        let schedule = TaskSchedule(name: "Imported External Routine", goal: "Do not auto-arm", workspace: workspace)
        schedule.isEnabled = true
        context.insert(schedule)
        try context.save()

        let configURL = externalFolder.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try WorkspaceConfigManager.exportToFile(
            workspace: workspace,
            modelContext: context,
            url: configURL
        )

        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue())
        let replaced = try #require(coordinator.importFromConfig(
            at: configURL,
            existingWorkspaces: [workspace],
            askDuplicateAction: { _, _ in .replace }
        ))
        let replacedSchedule = try #require(replaced.schedules.first)

        #expect(replaced.primaryPath == externalFolder.standardizedFileURL.path)
        #expect(replacedSchedule.isEnabled == false)
    }

    @Test("schedule editor saves preserve existing enabled state")
    func scheduleEditorSavesPreserveExistingEnabledState() {
        #expect(ScheduleEditorPersistencePolicy.enabledStateAfterSave(existingIsEnabled: false) == false)
        #expect(ScheduleEditorPersistencePolicy.enabledStateAfterSave(existingIsEnabled: true) == true)
        #expect(ScheduleEditorPersistencePolicy.enabledStateAfterSave(existingIsEnabled: nil) == true)
    }

    @Test("auto-export skip launch flags are recognized")
    func autoExportSkipLaunchFlagsAreRecognized() {
        #expect(WorkspacePersistenceCoordinator.shouldSkipAutoExport(
            arguments: ["ASTRA Dev", "--skip-workspace-recovery"],
            environment: [:]
        ))
        #expect(WorkspacePersistenceCoordinator.shouldSkipAutoExport(
            arguments: ["ASTRA Dev", "--skip-workspace-auto-export"],
            environment: [:]
        ))
        #expect(WorkspacePersistenceCoordinator.shouldSkipAutoExport(
            arguments: ["ASTRA Dev"],
            environment: ["ASTRA_SKIP_WORKSPACE_AUTO_EXPORT": "true"]
        ))
        #expect(!WorkspacePersistenceCoordinator.shouldSkipAutoExport(
            arguments: ["ASTRA Dev"],
            environment: [:]
        ))
    }

    @Test("import reuses built-in global skills by name")
    @MainActor
    func importReusesBuiltInGlobalSkillsByName() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let firstConfig = minimalWorkspaceConfig(
            name: "First",
            path: "/tmp/astra_import_first_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )
        let secondConfig = minimalWorkspaceConfig(
            name: "Second",
            path: "/tmp/astra_import_second_\(UUID().uuidString)",
            skillID: UUID().uuidString
        )

        let first = WorkspaceConfigManager.importWorkspace(from: firstConfig, modelContext: context)
        let second = WorkspaceConfigManager.importWorkspace(from: secondConfig, modelContext: context)
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.name == "Read-Only" && $0.isGlobal })
        let readOnlySkills = try context.fetch(descriptor)

        #expect(readOnlySkills.count == 1)
        #expect(readOnlySkills.first?.isSystemBuiltIn == true)
        #expect(first.enabledGlobalSkillIDs == [readOnlySkills.first?.id.uuidString].compactMap { $0 })
        #expect(second.enabledGlobalSkillIDs == [readOnlySkills.first?.id.uuidString].compactMap { $0 })
    }

    private func minimalWorkspaceConfig(name: String, path: String, skillID: String) -> WorkspaceConfigManager.WorkspaceConfig {
        WorkspaceConfigManager.WorkspaceConfig(
            id: UUID().uuidString,
            name: name,
            primaryPath: path,
            additionalPaths: [],
            icon: "folder.fill",
            instructions: "",
            skills: [
                WorkspaceConfigManager.SkillConfig(
                    id: skillID,
                    name: "Read-Only",
                    icon: "eye",
                    description: "",
                    allowedTools: ["Read", "Glob", "Grep"],
                    disallowedTools: ["Write", "Edit", "Bash"],
                    customTools: [],
                    behaviorInstructions: "Read only.",
                    environmentKeys: [],
                    environmentValues: [],
                    isGlobal: false
                )
            ],
            sshConnections: [],
            exportedAt: Date()
        )
    }

    private func writeLinkedWorktree(
        activeDirectory: URL,
        adminDirectory: URL,
        commonGitDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: adminDirectory, withIntermediateDirectories: true)
        try "gitdir: \(adminDirectory.path)\n".write(
            to: activeDirectory.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let relativeCommon = relativePath(from: adminDirectory, to: commonGitDirectory)
        try "\(relativeCommon)\n".write(
            to: adminDirectory.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(activeDirectory.appendingPathComponent(".git").path)\n".write(
            to: adminDirectory.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func relativePath(from directory: URL, to target: URL) -> String {
        let sourceComponents = directory.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        let sharedPrefixCount = zip(sourceComponents, targetComponents)
            .prefix { $0 == $1 }
            .count
        let upward = Array(repeating: "..", count: sourceComponents.count - sharedPrefixCount)
        let downward = targetComponents.dropFirst(sharedPrefixCount)
        let components = upward + downward
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    @Test("workspace support files migrate under hidden astra folder")
    func workspaceSupportFilesUseHiddenFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_layout_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacySSH = root.appendingPathComponent(WorkspaceFileLayout.sshConnectionsFileName)
        let connection = SSHConnection(name: "dev", host: "example.test", user: "agent")
        let data = try JSONEncoder().encode([connection])
        try data.write(to: legacySSH)

        let loaded = SSHConnectionManager.load(workspacePath: root.path)
        let canonicalSSH = URL(fileURLWithPath: WorkspaceFileLayout.sshConnectionsFile(for: root.path))

        #expect(loaded.first?.id == connection.id)
        #expect(FileManager.default.fileExists(atPath: canonicalSSH.path))
        #expect(!FileManager.default.fileExists(atPath: legacySSH.path))

        SSHConnectionManager.save(loaded, workspacePath: root.path)
        #expect(FileManager.default.fileExists(atPath: canonicalSSH.path))
        #expect(!FileManager.default.fileExists(atPath: legacySSH.path))
    }

    @Test("SSH connection presence uses a lightweight persisted file predicate")
    func sshConnectionPresenceUsesLightweightPredicate() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_ssh_presence_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SSHConnectionManager.hasStoredConnections(workspacePath: root.path) == false)

        SSHConnectionManager.save([], workspacePath: root.path)
        #expect(SSHConnectionManager.hasStoredConnections(workspacePath: root.path) == false)

        SSHConnectionManager.save([
            SSHConnection(name: "dev", host: "example.test", user: "agent")
        ], workspacePath: root.path)
        #expect(SSHConnectionManager.hasStoredConnections(workspacePath: root.path) == true)
    }

    @Test("SSH connection presence recognizes legacy files without migrating them")
    func sshConnectionPresenceRecognizesLegacyFilesWithoutMigratingThem() throws {
        let root = URL(fileURLWithPath: "/tmp/astra_ssh_presence_legacy_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacySSH = root.appendingPathComponent(WorkspaceFileLayout.sshConnectionsFileName)
        let canonicalSSH = URL(fileURLWithPath: WorkspaceFileLayout.sshConnectionsFile(for: root.path))
        let data = try JSONEncoder().encode([
            SSHConnection(name: "legacy", host: "example.test", user: "agent")
        ])
        try data.write(to: legacySSH)

        #expect(SSHConnectionManager.hasStoredConnections(workspacePath: root.path) == true)
        #expect(FileManager.default.fileExists(atPath: legacySSH.path))
        #expect(!FileManager.default.fileExists(atPath: canonicalSSH.path))
    }

    @Test("same-thread schedule results merge back into the source task")
    @MainActor
    func sameThreadScheduleResultsMergeIntoSourceTask() throws {
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Schedules", primaryPath: "/tmp/astra_schedule_merge_\(UUID().uuidString)")
        context.insert(workspace)

        let sourceTask = AgentTask(
            title: "Original Thread",
            goal: "Watch this thread",
            workspace: workspace
        )
        sourceTask.status = .completed
        sourceTask.isDone = false
        context.insert(sourceTask)

        let scheduledTask = AgentTask(
            title: "Monitor Run",
            goal: "Check for updates",
            workspace: workspace
        )
        scheduledTask.status = .completed
        scheduledTask.tokensUsed = 321
        scheduledTask.costUSD = 0.42
        context.insert(scheduledTask)

        let run = TaskRun(task: scheduledTask)
        run.status = .completed
        run.startedAt = Date().addingTimeInterval(-120)
        run.completedAt = Date().addingTimeInterval(-60)
        run.tokensUsed = 321
        run.inputTokens = 200
        run.outputTokens = 121
        run.output = "Here is the scheduled follow-up output."
        run.costUSD = 0.42
        run.stopReason = "completed"
        context.insert(run)

        let schedule = TaskSchedule(name: "Reply Monitor", goal: "Check for updates", workspace: workspace)
        schedule.routineDescription = "Watch reply activity"
        schedule.routinePaths = ["/tmp/reply-context"]
        schedule.resultMode = .sameThread
        schedule.sourceTaskID = sourceTask.id
        context.insert(schedule)
        try context.save()

        let queue = TaskQueue()
        queue.mergeSameThreadScheduleResult(
            from: scheduledTask,
            into: sourceTask,
            schedule: schedule,
            latestRun: run,
            modelContext: context
        )

        #expect(sourceTask.status == .completed)
        #expect(sourceTask.isDone == false)
        #expect(sourceTask.tokensUsed == 321)
        #expect(sourceTask.costUSD == 0.42)
        #expect(sourceTask.runs.count == 1)
        #expect(sourceTask.runs.first?.output == "Here is the scheduled follow-up output.")
        #expect(sourceTask.events.contains { $0.type == "user.message" && $0.payload.contains("Routine run: Reply Monitor") })
        #expect(sourceTask.events.contains { $0.type == "user.message" && $0.payload.contains("Watch reply activity") })
        #expect(sourceTask.events.contains { $0.type == "user.message" && $0.payload.contains("/tmp/reply-context") })
    }
}
