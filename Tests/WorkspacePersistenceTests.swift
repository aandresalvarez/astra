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

@MainActor
private func makeRichWorkspace(in context: ModelContext, root: String) throws -> Workspace {
    let workspace = Workspace(name: "Persistence", primaryPath: root)
    workspace.enabledCapabilityIDs = ["stanford.builder"]
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
    task.captureSkillSnapshots()
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

@Suite("Workspace Persistence v9")
struct WorkspacePersistenceTests {
    @Test("v9 export and import preserve IDs, stars, history, artifacts, and redacted credentials")
    @MainActor
    func v9RoundTripPreservesDurableIDs() throws {
        let tempRoot = "/tmp/astra_persistence_\(UUID().uuidString)"
        let container = try makeWorkspacePersistenceContainer()
        let context = container.mainContext
        let workspace = try makeRichWorkspace(in: context, root: tempRoot)
        let sourceTask = try #require(workspace.tasks.first)
        sourceTask.isPinned = true
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.version == WorkspaceConfigManager.currentVersion)
        #expect(config.id == workspace.id.uuidString)
        #expect(config.isStarred == true)
        #expect(config.skills.first?.id == workspace.skills.first?.id.uuidString)
        #expect(config.connectors?.first?.id == workspace.connectors.first?.id.uuidString)
        #expect(config.localTools?.first?.id == workspace.localTools.first?.id.uuidString)
        #expect(config.templates?.first?.id == workspace.templates.first?.id.uuidString)
        #expect(config.tasks?.first?.id == workspace.tasks.first?.id.uuidString)
        #expect(config.tasks?.first?.runs.first?.id == workspace.tasks.first?.runs.first?.id.uuidString)
        #expect(config.tasks?.first?.events.first?.id == workspace.tasks.first?.events.first?.id.uuidString)
        #expect(config.tasks?.first?.artifacts?.first?.id == workspace.tasks.first?.artifacts.first?.id.uuidString)
        #expect(config.tasks?.first?.skillIDs == [workspace.skills.first?.id.uuidString].compactMap { $0 })
        #expect(config.tasks?.first?.skillSnapshots?.first?.id == workspace.skills.first?.id.uuidString)
        #expect(config.tasks?.first?.isPinned == true)
        #expect(config.tasks?.first?.unreadAt == sourceTask.unreadAt)
        #expect(config.enabledCapabilityIDs == ["stanford.builder"])

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

        #expect(imported.id == workspace.id)
        #expect(imported.isStarred == true)
        #expect(imported.skills.first?.id == workspace.skills.first?.id)
        #expect(imported.connectors.first?.id == workspace.connectors.first?.id)
        #expect(imported.connectors.first?.credentialKeys == ["API_TOKEN"])
        #expect(imported.connectors.first?.credentialValues == [""])
        #expect(imported.enabledCapabilityIDs == ["stanford.builder"])
        #expect(imported.installedVersion(of: "stanford.builder") == "1.0.0")
        #expect(imported.tasks.first?.id == workspace.tasks.first?.id)
        #expect(imported.tasks.first?.isPinned == true)
        #expect(imported.tasks.first?.unreadAt == sourceTask.unreadAt)
        #expect(imported.tasks.first?.skills.first?.id == workspace.skills.first?.id)
        #expect(imported.tasks.first?.runs.first?.id == workspace.tasks.first?.runs.first?.id)
        #expect(imported.tasks.first?.events.first?.id == workspace.tasks.first?.events.first?.id)
        #expect(imported.tasks.first?.artifacts.first?.id == workspace.tasks.first?.artifacts.first?.id)
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
        task.captureSkillSnapshots()
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
        schedule.model = AgentRuntimeID.copilotCLI.defaultModel
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
        #expect(target.url?.path == root.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName).path)
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
        #expect(sourceTask.events.contains { $0.type == "user.message" && $0.payload.contains("Scheduled run: Reply Monitor") })
    }
}
