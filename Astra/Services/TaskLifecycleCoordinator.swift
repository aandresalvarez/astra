import Foundation
import SwiftData
import ASTRACore

@Observable @MainActor
final class TaskLifecycleCoordinator {
    let modelContext: ModelContext
    let taskQueue: TaskQueue

    init(modelContext: ModelContext, taskQueue: TaskQueue) {
        self.modelContext = modelContext
        self.taskQueue = taskQueue
    }

    // MARK: - Task Lifecycle

    func runQueue() {
        if taskQueue.isProcessing {
            taskQueue.cancelAll()
            return
        }
        Task {
            await taskQueue.processQueue(modelContext: modelContext)
        }
    }

    func runSingleTask(_ task: AgentTask) {
        AppLogger.audit(.taskStarted, category: "UI", taskID: task.id, fields: [
            "source": "manual_run"
        ])
        Task {
            await taskQueue.executeTask(task, modelContext: modelContext) { event in
                if case .text(let text) = event {
                    AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                        "event": "stream_text_received",
                        "character_count": String(text.count)
                    ], level: .debug)
                }
            }
            AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                "status": task.status.rawValue
            ])
        }
    }

    func cancelTask(_ task: AgentTask) {
        AppLogger.audit(.taskCancelled, category: "UI", taskID: task.id, fields: [
            "source": "user_action"
        ])
        taskQueue.cancel(task: task)
        task.status = .cancelled
        task.updatedAt = Date()
        task.completedAt = Date()
        let event = TaskEvent(task: task, type: "task.cancelled", payload: "Task cancelled by user.")
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    func retryTask(_ task: AgentTask) {
        AppLogger.audit(.taskRetried, category: "UI", taskID: task.id)
        task.status = .queued
        task.tokensUsed = 0
        task.costUSD = 0
        task.updatedAt = Date()
        task.completedAt = nil
        let event = TaskEvent(task: task, type: "task.retried", payload: "Task re-queued for retry.")
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        runSingleTask(task)
    }

    func resumeTask(_ task: AgentTask) {
        guard task.sessionId != nil else {
            AppLogger.audit(.workerSessionCleared, category: "UI", taskID: task.id, fields: [
                "reason": "missing_session_id"
            ], level: .warning)
            return
        }
        AppLogger.audit(.taskResumed, category: "UI", taskID: task.id)
        task.status = .running
        task.updatedAt = Date()
        task.completedAt = nil
        let event = TaskEvent(task: task, type: "task.resumed", payload: "Resuming previous session — continuing where the agent left off.")
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        Task {
            await taskQueue.continueSession(task: task, message: "Continue where you left off. Complete the original goal.", modelContext: modelContext) { event in
                if case .text(let text) = event {
                    AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                        "event": "resume_stream_text_received",
                        "character_count": String(text.count)
                    ], level: .debug)
                }
            }
            AppLogger.audit(.taskCompleted, category: "UI", taskID: task.id, fields: [
                "status": task.status.rawValue,
                "source": "resume"
            ])
        }
    }

    func approveTask(_ task: AgentTask) {
        AppLogger.audit(.taskApproved, category: "UI", taskID: task.id)
        task.status = .completed
        task.updatedAt = Date()
        task.completedAt = Date()
        let event = TaskEvent(task: task, type: "task.approved", payload: "Task approved by user.")
        modelContext.insert(event)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    func deleteTask(_ task: AgentTask) -> Workspace? {
        AppLogger.audit(.taskDeleted, category: "UI", taskID: task.id)
        let workspace = task.workspace
        modelContext.delete(task)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        return workspace
    }

    func setDoneState(_ task: AgentTask, to isDone: Bool) {
        task.isDone = isDone
        task.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.taskFailed, category: "UI", taskID: task.id, fields: [
                "operation": "apply_done_state",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    func activeSameThreadSchedules(for task: AgentTask) -> [TaskSchedule] {
        task.workspace?.schedules
            .filter { $0.isEnabled && $0.resultMode == .sameThread && $0.sourceTaskID == task.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
    }

    func pauseSchedules(_ schedules: [TaskSchedule]) {
        for schedule in schedules {
            schedule.isEnabled = false
            schedule.updatedAt = Date()
        }
    }

    // MARK: - Workspace Lifecycle

    func createWorkspace(name: String, rootPath: String) -> Workspace {
        let folderName = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        let folderPath = (rootPath as NSString).appendingPathComponent(folderName)

        do {
            try PathValidator.validate(folderPath)
            try FileManager.default.createDirectory(
                atPath: folderPath, withIntermediateDirectories: true)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "UI", fields: [
                "operation": "create_workspace_folder",
                "path": folderPath,
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        let ws = Workspace(name: name, primaryPath: folderPath)
        modelContext.insert(ws)
        seedSkills(for: ws)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: ws, modelContext: modelContext)
        return ws
    }

    func deleteWorkspace(_ ws: Workspace, existingWorkspaces: [Workspace]) -> Workspace? {
        let configPath = WorkspaceFileLayout.workspaceConfigFile(for: ws.primaryPath)
        try? FileManager.default.removeItem(atPath: configPath)

        for connector in ws.connectors {
            connector.cleanupKeychain()
        }
        for skill in ws.skills {
            skill.cleanupKeychain()
            for connector in skill.connectors {
                connector.cleanupKeychain()
            }
        }
        modelContext.delete(ws)

        let next = existingWorkspaces.first(where: { $0.id != ws.id })
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: next, modelContext: modelContext)
        return next
    }

    func importFromConfig(at url: URL, existingWorkspaces: [Workspace],
                          askDuplicateAction: (String, Int) -> DuplicateAction) -> Workspace? {
        do {
            var config = try WorkspaceConfigManager.loadConfig(from: url)
            let configID = config.id
            if let existing = existingWorkspaces.first(where: { workspace in
                (configID != nil && workspace.id.uuidString == configID) || workspace.primaryPath == config.primaryPath
            }) {
                let action = askDuplicateAction(config.name, existing.tasks.count)
                switch action {
                case .skip:
                    return nil
                case .replace:
                    if (config.tasks ?? []).isEmpty && !existing.tasks.isEmpty {
                        if let freshExport = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext) {
                            config.tasks = freshExport.tasks
                        }
                    }
                    modelContext.delete(existing)
                    return WorkspaceConfigManager.importWorkspace(from: config, modelContext: modelContext)
                case .duplicate:
                    var dupConfig = config
                    dupConfig.name = config.name + " (Imported)"
                    if (dupConfig.tasks ?? []).isEmpty && !existing.tasks.isEmpty {
                        if let freshExport = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext) {
                            dupConfig.tasks = freshExport.tasks
                        }
                    }
                    return WorkspaceConfigManager.importWorkspace(from: dupConfig, modelContext: modelContext)
                }
            }
            return WorkspaceConfigManager.importWorkspace(from: config, modelContext: modelContext)
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "App", fields: [
                "operation": "import_config",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }

    func createWorkspaceFromFolder(_ url: URL, existingWorkspaces: [Workspace],
                                   askDuplicateAction: (String, Int) -> DuplicateAction) -> Workspace? {
        let name = url.lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        if let existing = existingWorkspaces.first(where: { $0.name == name || $0.primaryPath == url.path }) {
            let action = askDuplicateAction(name, existing.tasks.count)
            switch action {
            case .skip:
                return nil
            case .replace:
                if var exportedConfig = WorkspaceConfigManager.export(workspace: existing, modelContext: modelContext) {
                    exportedConfig.name = name
                    exportedConfig.primaryPath = url.path
                    modelContext.delete(existing)
                    return WorkspaceConfigManager.importWorkspace(from: exportedConfig, modelContext: modelContext)
                }
                modelContext.delete(existing)
                return insertWorkspaceFromFolder(name: name, path: url.path)
            case .duplicate:
                return insertWorkspaceFromFolder(name: name + " (Imported)", path: url.path)
            }
        }
        return insertWorkspaceFromFolder(name: name, path: url.path)
    }

    func insertWorkspaceFromFolder(name: String, path: String) -> Workspace {
        let ws = Workspace(name: name, primaryPath: path)
        modelContext.insert(ws)
        for (sName, sIcon, sAllowed, sBlocked, sBehavior) in [
            ("Read-Only", "eye", ["Read", "Glob", "Grep"], ["Write", "Edit", "Bash"],
             "Do not create, modify, or delete any files."),
            ("Safe Bash", "shield", Skill.defaultAllowed, [String](),
             "Never run rm, sudo, curl, pip install, npm install, or any destructive/network commands."),
            ("Test Runner", "checkmark.seal", ["Read", "Bash", "Glob", "Grep"], ["Write", "Edit"],
             "Use Bash only to run test commands. Do not modify source code.")
        ] as [(String, String, [String], [String], String)] {
            let skill = Skill(name: sName, icon: sIcon, allowedTools: sAllowed,
                              disallowedTools: sBlocked, behaviorInstructions: sBehavior)
            skill.workspace = ws
            modelContext.insert(skill)
        }
        return ws
    }

    func importSessionsIfNeeded(for workspace: Workspace) {
        guard workspace.tasks.isEmpty else { return }
        let sessions = SessionScanner.discoverSessions(workspacePath: workspace.primaryPath)
        guard !sessions.isEmpty else { return }
        let count = SessionScanner.importSessions(sessions, into: workspace, modelContext: modelContext)
        AppLogger.audit(.workspaceImported, category: "App", fields: [
            "previous_thread_count": String(count),
            "workspace_id": workspace.id.uuidString
        ])
    }

    func backfillGeneratedThreadTitles(
        claudePath: String,
        model: String = "claude-haiku-4-5-20251001",
        limit: Int = 40
    ) {
        let resolvedClaudePath = claudePath.isEmpty ? SpecEngine.detectedClaudePath : claudePath
        guard FileManager.default.isExecutableFile(atPath: resolvedClaudePath) else {
            AppLogger.audit(.taskStats, category: "UI", fields: [
                "operation": "thread_title_backfill",
                "result": "missing_claude",
                "claude_path": resolvedClaudePath
            ], level: .warning)
            return
        }

        let descriptor = FetchDescriptor<AgentTask>(
            sortBy: [SortDescriptor(\AgentTask.updatedAt, order: .reverse)]
        )
        let tasks = (try? modelContext.fetch(descriptor)) ?? []
        let candidates = Array(tasks.filter(Self.shouldBackfillGeneratedTitle).prefix(limit))
        guard !candidates.isEmpty else { return }

        AppLogger.audit(.taskStats, category: "UI", fields: [
            "operation": "thread_title_backfill",
            "candidate_count": String(candidates.count)
        ], level: .info)

        Task { @MainActor in
            var renamed = 0
            for task in candidates {
                guard let workspace = task.workspace else { continue }
                let originalTitle = task.title
                let originalUpdatedAt = task.updatedAt

                guard let generated = await SpecEngine.generateTitle(
                    goal: task.goal,
                    workspacePath: workspace.primaryPath,
                    claudePath: resolvedClaudePath,
                    model: model
                ),
                Self.isUsableGeneratedTitle(generated),
                generated.caseInsensitiveCompare(originalTitle) != .orderedSame else {
                    continue
                }

                task.title = generated
                task.updatedAt = originalUpdatedAt
                renamed += 1
                WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            }

            AppLogger.audit(.taskStats, category: "UI", fields: [
                "operation": "thread_title_backfill",
                "candidate_count": String(candidates.count),
                "renamed_count": String(renamed)
            ], level: .info)
        }
    }

    private static func shouldBackfillGeneratedTitle(_ task: AgentTask) -> Bool {
        guard task.status != .running else { return false }

        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !goal.isEmpty else { return false }

        let fallbackTitle = fallbackTitle(from: goal)
        let goalPrefix = String(goal.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard title == fallbackTitle || title == goalPrefix else { return false }

        if task.sessionId != nil { return true }
        if title.hasSuffix("...") { return true }
        if title.count > 45 { return true }

        let lowercased = title.lowercased()
        return ["what ", "how ", "why ", "please ", "can you ", "could you "].contains {
            lowercased.hasPrefix($0)
        } || title.contains("?")
    }

    private static func fallbackTitle(from goal: String) -> String {
        let firstLine = goal.components(separatedBy: "\n").first ?? goal
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 60 { return cleaned }

        let prefix = String(cleaned.prefix(57))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    private static func isUsableGeneratedTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 80 else { return false }
        guard !trimmed.contains("\n") else { return false }
        return true
    }

    // MARK: - Migration

    func migrateConnectorCredentials(workspaces: [Workspace]) {
        for ws in workspaces {
            for connector in ws.connectors {
                connector.migrateToKeychain()
            }
        }
    }

    func migrateSkillSecrets(skills: [Skill]) {
        for skill in skills {
            skill.migrateSecretsToKeychain()
        }
    }

    // MARK: - Seeding

    func seedSkills(for workspace: Workspace) {
        let readOnly = Skill(
            name: "Read-Only",
            allowedTools: ["Read", "Glob", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: "You must not create, modify, or delete any files. Only read and analyze."
        )
        readOnly.icon = "lock.shield"
        readOnly.skillDescription = "Restricts agent to read-only file access"
        readOnly.workspace = workspace

        let testRunner = Skill(
            name: "Test Runner",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: [],
            behaviorInstructions: "Use Bash only to run test commands (e.g. swift test, pytest, npm test). Do not use Bash for other purposes."
        )
        testRunner.icon = "checkmark.seal"
        testRunner.skillDescription = "Allows all tools but limits Bash to test commands"
        testRunner.workspace = workspace

        let safeBash = Skill(
            name: "Safe Bash",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: [],
            behaviorInstructions: "Never run rm, sudo, curl, pip install, npm install, or any destructive/network commands in Bash."
        )
        safeBash.icon = "shield"
        safeBash.skillDescription = "Allows all tools but restricts dangerous Bash commands"
        safeBash.workspace = workspace

        for skill in [readOnly, testRunner, safeBash] {
            modelContext.insert(skill)
        }
        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.skillToolPermissionChanged, category: "UI", fields: [
                "operation": "seed_skills",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    enum DuplicateAction {
        case skip, replace, duplicate
    }
}
