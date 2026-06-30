import Foundation
import SwiftData
import ASTRACore

/// Exports and imports workspace configurations as shareable JSON files.
/// SwiftData is the local cache. The workspace JSON is the durable recovery and sharing format.
///
/// Data safety contract:
/// - UUIDs are exported for every durable entity so names are display text only.
/// - Connector credential values are never exported. Only credential key names are written.
/// - v1-v9 configs remain importable through optional fields and legacy name fallback.
enum WorkspaceConfigManager {

    // MARK: - Config Schema (v10)

    static let currentVersion = 10

    enum ScheduleImportTrustPolicy {
        case quarantineEnabledSchedules
        case preserveEnabledState

        func enabledState(for config: ScheduleConfig) -> Bool {
            switch self {
            case .quarantineEnabledSchedules:
                false
            case .preserveEnabledState:
                config.isEnabled
            }
        }

        func quarantinedScheduleCount(in schedules: [ScheduleConfig]?) -> Int {
            switch self {
            case .quarantineEnabledSchedules:
                schedules?.filter(\.isEnabled).count ?? 0
            case .preserveEnabledState:
                0
            }
        }
    }

    struct WorkspaceConfigExportResult {
        enum Status: String {
            case exported
            case skippedNoConfig
            case writeFailed
        }

        var status: Status
        var workspaceID: String
        var path: String
        var errorType: String?
        var errorDomain: String?
        var errorCode: Int?
        var errorDescription: String?
        var parentExists: Bool
        var parentWritable: Bool

        var didExport: Bool {
            status == .exported
        }

        var auditFields: [String: String] {
            var fields: [String: String] = [
                "workspace_id": workspaceID,
                "config_file": URL(fileURLWithPath: path).lastPathComponent,
                "path": path,
                "result": status.rawValue,
                "parent_exists": String(parentExists),
                "parent_writable": String(parentWritable)
            ]
            if let errorType {
                fields["error_type"] = errorType
            }
            if let errorDomain {
                fields["error_domain"] = errorDomain
            }
            if let errorCode {
                fields["error_code"] = String(errorCode)
            }
            if let errorDescription {
                fields["error_description"] = errorDescription
            }
            return fields
        }
    }

    struct WorkspaceConfigLoadResult {
        enum Status: String {
            case loaded
            case unreadableFile
            case decodeFailed
        }

        var status: Status
        var path: String
        var config: WorkspaceConfig?
        var errorType: String?
        var errorDomain: String?
        var errorCode: Int?
        var errorDescription: String?

        var didLoad: Bool {
            config != nil
        }
    }

    struct WorkspaceConfigImportResult {
        enum Status: String {
            case imported
        }

        var status: Status
        var workspace: Workspace
        var workspaceID: String
        var skillCount: Int
        var connectorCount: Int
        var localToolCount: Int
        var taskCount: Int
        var quarantinedScheduleCount: Int
        var skippedConnectorCount: Int
        var skippedLocalToolCount: Int

        var didImport: Bool {
            status == .imported
        }

        var auditFields: [String: String] {
            [
                "result": status.rawValue,
                "workspace_id": workspaceID,
                "skill_count": String(skillCount),
                "connector_count": String(connectorCount),
                "local_tool_count": String(localToolCount),
                "task_count": String(taskCount),
                "quarantined_schedule_count": String(quarantinedScheduleCount),
                "skipped_connector_count": String(skippedConnectorCount),
                "skipped_local_tool_count": String(skippedLocalToolCount)
            ]
        }
    }

    struct WorkspaceConfig: Codable, Sendable {
        var version: Int = WorkspaceConfigManager.currentVersion
        var id: String?
        var name: String
        var primaryPath: String
        var additionalPaths: [String]
        var icon: String
        var instructions: String
        var isStarred: Bool? = nil
        /// Absolute path of the worktree new chats default to, or nil for the
        /// repository root. Travels with the workspace; it is re-validated on
        /// import and reset to root when the worktree is absent on this machine.
        var activeWorkingPath: String? = nil
        /// JSON-encoded workspace execution-environment default. Nil means host.
        var activeExecutionEnvironmentJSON: String? = nil
        var lastUsedSkillNames: [String]?
        var enabledGlobalSkillIDs: [String]?
        var enabledGlobalConnectorIDs: [String]?
        var enabledGlobalToolIDs: [String]?
        var enabledCapabilityIDs: [String]?
        var memories: [String]?
        var createdAt: Date?
        var updatedAt: Date?
        var skills: [SkillConfig]
        var connectors: [ConnectorConfig]?
        var localTools: [LocalToolConfig]?
        var templates: [TemplateConfig]?
        var schedules: [ScheduleConfig]?
        var sshConnections: [SSHConnection]
        var tasks: [TaskConfig]?
        var installedPlugins: [InstalledPluginRef]?
        var exportedAt: Date
    }

    struct InstalledPluginRef: Codable, Sendable {
        var id: String
        var version: String
        var name: String?
    }

    struct SkillConfig: Codable, Sendable {
        var id: String?
        var name: String
        var icon: String
        var description: String
        var allowedTools: [String]
        var disallowedTools: [String]
        var customTools: [String]
        var behaviorInstructions: String
        var environmentKeys: [String]
        var environmentValues: [String]
        var isGlobal: Bool?
        var connectorIDs: [String]?
        var localToolIDs: [String]?
        var connectorNames: [String]?
        var localToolNames: [String]?
        var originPackageID: String? = nil
        var originPackageVersion: String? = nil
        var originComponentID: String? = nil
        var originComponentKind: String? = nil
        var originSourceKind: String? = nil
        var createdAt: Date?
        var updatedAt: Date?
    }

    struct ConnectorConfig: Codable, Sendable {
        var id: String?
        var name: String
        var serviceType: String
        var icon: String
        var description: String
        var baseURL: String
        var authMethod: String
        var credentialKeys: [String]
        var configKeys: [String]
        var configValues: [String]
        var isGlobal: Bool?
        var notes: String
        var originPackageID: String? = nil
        var originPackageVersion: String? = nil
        var originComponentID: String? = nil
        var originComponentKind: String? = nil
        var originSourceKind: String? = nil
        var createdAt: Date?
        var updatedAt: Date?
    }

    struct LocalToolConfig: Codable, Sendable {
        var id: String?
        var name: String
        var description: String
        var icon: String
        var toolType: String
        var command: String
        var arguments: String
        var isGlobal: Bool?
        var originPackageID: String? = nil
        var originPackageVersion: String? = nil
        var originComponentID: String? = nil
        var originComponentKind: String? = nil
        var originSourceKind: String? = nil
        var createdAt: Date?
        var updatedAt: Date?
    }

    struct TemplateConfig: Codable, Sendable {
        var id: String?
        var name: String
        var icon: String
        var description: String
        var beforeGoal: String
        var mainGoal: String
        var afterGoal: String
        var beforeBudget: Int
        var mainBudget: Int
        var afterBudget: Int
        var beforeModel: String
        var mainModel: String
        var afterModel: String
        var variablesJSON: String
        var hooksJSON: String
        var passContextToMain: Bool
        var passContextToAfter: Bool
        var defaultSkillIDs: [String]?
        var originPackageID: String? = nil
        var originPackageVersion: String? = nil
        var originComponentID: String? = nil
        var originComponentKind: String? = nil
        var originSourceKind: String? = nil
        var createdAt: Date?
        var updatedAt: Date?
    }

    struct ScheduleConfig: Codable, Sendable {
        var id: String?
        var name: String
        var isEnabled: Bool
        var goal: String
        var routineDescription: String?
        var routineInstructions: String?
        var routinePaths: [String]?
        var templateID: String?
        var templateVariablesJSON: String
        var model: String
        var tokenBudget: Int
        var scheduleType: String
        var nextFireDate: Date
        var intervalSeconds: Int
        var dailyHour: Int
        var dailyMinute: Int
        var weeklyDayOfWeek: Int
        var fireCount: Int
        var skillIDs: [String]?
        var conversationContext: String?
        var resultMode: String?
        var sourceTaskID: String?
        var runResultsJSON: String?
        var runtimeID: String?
        var lastFiredAt: Date?
        var createdAt: Date?
        var updatedAt: Date?
    }

    struct TaskConfig: Codable, Sendable {
        var id: String?
        var title: String
        var goal: String
        var status: String
        var isPinned: Bool?
        var isDone: Bool?
        var inputs: [String]
        var constraints: [String]
        var acceptanceCriteria: [String]
        var tokenBudget: Int
        var tokensUsed: Int
        var model: String
        var runtimeID: String?
        var costUSD: Double
        var sessionId: String?
        var maxTurns: Int
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
        var unreadAt: Date?
        var isolationStrategy: String?
        var validationStrategy: String?
        var testCommand: String?
        var draftMessages: String?
        var chainedGoal: String?
        var chainedFromID: String?
        var useAgentTeam: Bool?
        var teamSize: Int?
        var teamInstructions: String?
        var templateID: String?
        var templateHooksJSON: String?
        var runs: [RunConfig]
        var events: [EventConfig]
        var artifacts: [ArtifactConfig]?
        var skillIDs: [String]?
        var skillNames: [String]
        var skillSnapshots: [SkillSnapshotConfig]?
        var executionEnvironmentSnapshotJSON: String?
    }

    struct RunConfig: Codable, Sendable {
        var id: String?
        var status: String
        var startedAt: Date
        var completedAt: Date?
        var tokensUsed: Int
        var inputTokens: Int?
        var outputTokens: Int?
        var runtimeID: String?
        var providerSessionId: String?
        var providerVersion: String?
        var executionEnvironmentSnapshotJSON: String?
        var exitCode: Int?
        var output: String
        var costUSD: Double
        var stopReason: String
        var fileChangesJSON: String
    }

    struct EventConfig: Codable, Sendable {
        var id: String?
        var type: String
        var payload: String
        var timestamp: Date
        var category: String
        var agentName: String?
        var agentId: String?
        var teamName: String?
        var runIndex: Int?
    }

    // MARK: - Export

    static func export(workspace: Workspace) -> WorkspaceConfig? {
        guard let modelContext = workspace.modelContext else {
            return export(workspace: workspace, globalSkills: [])
        }
        return export(workspace: workspace, modelContext: modelContext)
    }

    static func export(workspace: Workspace, modelContext: ModelContext) -> WorkspaceConfig? {
        let globalSkills = fetchGlobalSkills(modelContext: modelContext)
        let globalConnectors = fetchGlobalConnectors(modelContext: modelContext)
        let globalTools = fetchGlobalTools(modelContext: modelContext)
        return export(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    static func export(
        workspace: Workspace,
        globalSkills: [Skill],
        globalConnectors: [Connector] = [],
        globalTools: [LocalTool] = []
    ) -> WorkspaceConfig? {
        // Guard against faulted/deleted workspace during dealloc
        guard !workspace.isDeleted, workspace.modelContext != nil else { return nil }

        let skills = skillsForExport(workspace: workspace, globalSkills: globalSkills)
        let connectors = connectorsForExport(
            workspace: workspace,
            skills: skills,
            globalConnectors: globalConnectors
        )
        let localTools = toolsForExport(
            workspace: workspace,
            skills: skills,
            globalTools: globalTools
        )

        let skillConfigs = skills.compactMap(skillConfig)
        let connectorConfigs = connectors.compactMap(connectorConfig)
        let toolConfigs = localTools.compactMap(localToolConfig)
        let templateConfigs = workspace.templates.map(templateConfig)
        let scheduleConfigs = workspace.schedules.map(scheduleConfig)
        let sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
        let taskConfigs = workspace.tasks.map(taskConfig)

        var pluginRefs: [InstalledPluginRef] = []
        for (idx, pluginID) in workspace.installedPluginIDs.enumerated() {
            let ver = idx < workspace.installedPluginVersions.count
                ? workspace.installedPluginVersions[idx] : "0.0.0"
            pluginRefs.append(InstalledPluginRef(id: pluginID, version: ver))
        }

        return WorkspaceConfig(
            id: workspace.id.uuidString,
            name: workspace.name,
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths,
            icon: workspace.icon,
            instructions: workspace.instructions,
            isStarred: workspace.isStarred ? true : nil,
            activeWorkingPath: workspace.activeWorkingPath,
            activeExecutionEnvironmentJSON: workspace.activeExecutionEnvironmentJSON,
            lastUsedSkillNames: workspace.lastUsedSkillNames,
            enabledGlobalSkillIDs: workspace.enabledGlobalSkillIDs,
            enabledGlobalConnectorIDs: workspace.enabledGlobalConnectorIDs,
            enabledGlobalToolIDs: workspace.enabledGlobalToolIDs,
            enabledCapabilityIDs: workspace.enabledCapabilityIDs,
            memories: workspace.memories,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            skills: skillConfigs,
            connectors: connectorConfigs,
            localTools: toolConfigs,
            templates: templateConfigs,
            schedules: scheduleConfigs,
            sshConnections: sshConnections,
            tasks: taskConfigs,
            installedPlugins: pluginRefs.isEmpty ? nil : pluginRefs,
            exportedAt: Date()
        )
    }

    static func exportToFile(workspace: Workspace, url: URL) throws {
        guard let config = export(workspace: workspace) else { return }
        try write(config, to: url)
    }

    static func exportToFile(workspace: Workspace, modelContext: ModelContext, url: URL) throws {
        guard let config = export(workspace: workspace, modelContext: modelContext) else { return }
        try write(config, to: url)
    }

    @discardableResult
    static func exportToFileResult(workspace: Workspace, url: URL) -> WorkspaceConfigExportResult {
        guard let config = export(workspace: workspace) else {
            return exportResult(
                status: .skippedNoConfig,
                workspaceID: workspace.id.uuidString,
                url: url,
                error: nil
            )
        }
        return writeResult(config, workspaceID: workspace.id.uuidString, to: url)
    }

    @discardableResult
    static func exportToFileResult(workspace: Workspace, modelContext: ModelContext, url: URL) -> WorkspaceConfigExportResult {
        guard let config = export(workspace: workspace, modelContext: modelContext) else {
            return exportResult(
                status: .skippedNoConfig,
                workspaceID: workspace.id.uuidString,
                url: url,
                error: nil
            )
        }
        return writeResult(config, workspaceID: workspace.id.uuidString, to: url)
    }

    /// Auto-save config to the workspace's primary path for recovery.
    ///
    /// The Sendable `WorkspaceConfig` snapshot is built synchronously here (it must
    /// read SwiftData objects on the current actor), then the JSON encode + atomic
    /// file write are handed to `WorkspaceAutoExportWriter`, which serializes all
    /// auto-export writes off the main actor. This removes the synchronous
    /// `encode(.prettyPrinted)` + `data.write` stall from every `modelContext.save()`
    /// on a live run. The result-returning `exportToFileResult` path (used by tests,
    /// explicit user export, and flush-on-disappear) is intentionally left synchronous.
    static func autoExport(workspace: Workspace) {
        let target = autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logAutoExportSkipped(workspace: workspace, reason: target.reason)
            return
        }
        guard let config = export(workspace: workspace) else { return }
        let workspaceID = workspace.id.uuidString
        Task.detached(priority: .utility) {
            await WorkspaceAutoExportWriter.shared.write(config, to: url, workspaceID: workspaceID)
        }
    }

    static func autoExport(workspace: Workspace, modelContext: ModelContext) {
        let target = autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logAutoExportSkipped(workspace: workspace, reason: target.reason)
            return
        }
        guard let config = export(workspace: workspace, modelContext: modelContext) else { return }
        let workspaceID = workspace.id.uuidString
        Task.detached(priority: .utility) {
            await WorkspaceAutoExportWriter.shared.write(config, to: url, workspaceID: workspaceID)
        }
    }

    struct AutoExportTarget {
        let url: URL?
        let reason: String
    }

    static func autoExportTarget(for workspacePath: String) -> AutoExportTarget {
        guard !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AutoExportTarget(url: nil, reason: "primary_path_empty")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AutoExportTarget(url: nil, reason: "primary_path_unavailable")
        }

        let configPath = WorkspaceFileLayout.workspaceConfigFile(for: workspacePath)
        guard !configPath.isEmpty else {
            return AutoExportTarget(url: nil, reason: "config_path_empty")
        }

        return AutoExportTarget(url: URL(fileURLWithPath: configPath), reason: "ready")
    }

    private static func logAutoExportSkipped(workspace: Workspace, reason: String) {
        AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
            "result": "auto_export_skipped",
            "reason": reason,
            "workspace_id": workspace.id.uuidString
        ], level: .debug)
    }

    private static func exportResult(
        status: WorkspaceConfigExportResult.Status,
        workspaceID: String,
        url: URL,
        error: Error?
    ) -> WorkspaceConfigExportResult {
        let nsError = error.map { $0 as NSError }
        let parent = url.deletingLastPathComponent()
        return WorkspaceConfigExportResult(
            status: status,
            workspaceID: workspaceID,
            path: url.path,
            errorType: error.map { String(describing: type(of: $0)) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription,
            parentExists: FileManager.default.fileExists(atPath: parent.path),
            parentWritable: FileManager.default.isWritableFile(atPath: parent.path)
        )
    }

    private static func writeResult(_ config: WorkspaceConfig, workspaceID: String, to url: URL) -> WorkspaceConfigExportResult {
        do {
            try write(config, to: url)
            return exportResult(status: .exported, workspaceID: workspaceID, url: url, error: nil)
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspaceID, url: url, error: error)
        }
    }

    // MARK: - Import

    static func loadConfig(
        from url: URL,
        accessIntent: HostFileAccessIntent = .explicitUserSelection
    ) throws -> WorkspaceConfig {
        let data = try readConfigData(from: url, accessIntent: accessIntent)
        return try workspaceConfigDecoder().decode(WorkspaceConfig.self, from: data)
    }

    static func loadConfigResult(
        from url: URL,
        accessIntent: HostFileAccessIntent = .explicitUserSelection
    ) -> WorkspaceConfigLoadResult {
        let data: Data
        do {
            data = try readConfigData(from: url, accessIntent: accessIntent)
        } catch {
            return loadResult(status: .unreadableFile, url: url, config: nil, error: error)
        }

        do {
            let config = try workspaceConfigDecoder().decode(WorkspaceConfig.self, from: data)
            return loadResult(status: .loaded, url: url, config: config, error: nil)
        } catch {
            return loadResult(status: .decodeFailed, url: url, config: nil, error: error)
        }
    }

    private static func readConfigData(from url: URL, accessIntent: HostFileAccessIntent) throws -> Data {
        try HostFileAccessBroker().readData(at: url, intent: accessIntent)
    }

    private static func workspaceConfigDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Create a new Workspace + Skills + Connectors + Tools + Templates from a config.
    static func importWorkspace(
        from config: WorkspaceConfig,
        modelContext: ModelContext,
        scheduleTrustPolicy: ScheduleImportTrustPolicy = .quarantineEnabledSchedules
    ) -> Workspace {
        importWorkspaceResult(
            from: config,
            modelContext: modelContext,
            scheduleTrustPolicy: scheduleTrustPolicy
        ).workspace
    }

    /// Create a new Workspace + Skills + Connectors + Tools + Templates from a config.
    static func importWorkspaceResult(
        from config: WorkspaceConfig,
        modelContext: ModelContext,
        scheduleTrustPolicy: ScheduleImportTrustPolicy = .quarantineEnabledSchedules
    ) -> WorkspaceConfigImportResult {
        let workspace = Workspace(
            name: config.name,
            primaryPath: config.primaryPath,
            additionalPaths: config.additionalPaths,
            icon: config.icon,
            instructions: config.instructions
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            workspace.id = id
        }
        workspace.lastUsedSkillNames = config.lastUsedSkillNames ?? []
        workspace.enabledGlobalSkillIDs = config.enabledGlobalSkillIDs ?? []
        workspace.enabledGlobalConnectorIDs = config.enabledGlobalConnectorIDs ?? []
        workspace.enabledGlobalToolIDs = config.enabledGlobalToolIDs ?? []
        workspace.enabledCapabilityIDs = config.enabledCapabilityIDs ?? []
        workspace.memories = config.memories ?? []
        workspace.isStarred = config.isStarred ?? false
        workspace.activeExecutionEnvironmentJSON = sanitizedExecutionEnvironmentJSON(config.activeExecutionEnvironmentJSON)
        workspace.activeWorkingPath = importedActiveWorkingPath(
            config.activeWorkingPath,
            primaryPath: config.primaryPath,
            additionalPaths: config.additionalPaths
        )
        if let refs = config.installedPlugins {
            workspace.installedPluginIDs = refs.map(\.id)
            workspace.installedPluginVersions = refs.map(\.version)
        }
        workspace.createdAt = config.createdAt ?? workspace.createdAt
        workspace.updatedAt = config.updatedAt ?? workspace.updatedAt
        modelContext.insert(workspace)

        var connectorsByID: [String: Connector] = [:]
        var connectorsByName: [String: Connector] = [:]
        var skippedConnectorCount = 0
        for cc in config.connectors ?? [] {
            guard let connector = reusedGlobalConnector(for: cc, modelContext: modelContext) ?? makeConnector(from: cc) else {
                skippedConnectorCount += 1
                continue
            }
            connector.workspace = (connector.isGlobal ? nil : workspace)
            if connector.isGlobal {
                appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)
            }
            if connector.modelContext == nil {
                modelContext.insert(connector)
            }
            connectorsByID[connector.id.uuidString] = connector
            if connectorsByName[connector.name] == nil {
                connectorsByName[connector.name] = connector
            }
        }

        var toolsByID: [String: LocalTool] = [:]
        var toolsByName: [String: LocalTool] = [:]
        var skippedLocalToolCount = 0
        for tc in config.localTools ?? [] {
            guard let tool = reusedGlobalTool(for: tc, modelContext: modelContext) ?? makeLocalTool(from: tc) else {
                skippedLocalToolCount += 1
                continue
            }
            tool.workspace = (tool.isGlobal ? nil : workspace)
            if tool.isGlobal {
                appendUnique(tool.id.uuidString, to: &workspace.enabledGlobalToolIDs)
            }
            if tool.modelContext == nil {
                modelContext.insert(tool)
            }
            toolsByID[tool.id.uuidString] = tool
            if toolsByName[tool.name] == nil {
                toolsByName[tool.name] = tool
            }
        }

        var skillsByID: [String: Skill] = [:]
        var skillsByName: [String: Skill] = [:]
        for sc in config.skills {
            let skill = reusedGlobalSkill(for: sc, modelContext: modelContext) ?? makeSkill(from: sc)
            if skill.modelContext == nil {
                modelContext.insert(skill)
            }
            skill.workspace = (skill.isGlobal ? nil : workspace)
            if skill.isGlobal {
                appendUnique(skill.id.uuidString, to: &workspace.enabledGlobalSkillIDs)
            }
            linkResources(
                skill: skill,
                connectorIDs: sc.connectorIDs,
                connectorNames: sc.connectorNames,
                localToolIDs: sc.localToolIDs,
                localToolNames: sc.localToolNames,
                connectorsByID: connectorsByID,
                connectorsByName: connectorsByName,
                toolsByID: toolsByID,
                toolsByName: toolsByName
            )
            skillsByID[skill.id.uuidString] = skill
            if skillsByName[skill.name] == nil {
                skillsByName[skill.name] = skill
            }
        }

        for tc in config.templates ?? [] {
            let template = makeTemplate(from: tc, workspace: workspace)
            modelContext.insert(template)
        }

        if !config.sshConnections.isEmpty && !config.primaryPath.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: config.primaryPath,
                withIntermediateDirectories: true
            )
            SSHConnectionManager.save(config.sshConnections, workspacePath: config.primaryPath)
        }

        let quarantinedScheduleCount = scheduleTrustPolicy.quarantinedScheduleCount(in: config.schedules)
        for sc in config.schedules ?? [] {
            let schedule = makeImportedSchedule(from: sc, workspace: workspace, trustPolicy: scheduleTrustPolicy)
            modelContext.insert(schedule)
        }

        if let taskConfigs = config.tasks {
            for tc in taskConfigs {
                importTask(
                    tc,
                    workspace: workspace,
                    modelContext: modelContext,
                    skillsByID: &skillsByID,
                    skillsByName: &skillsByName,
                    connectorsByID: &connectorsByID,
                    connectorsByName: &connectorsByName,
                    toolsByID: &toolsByID,
                    toolsByName: &toolsByName
                )
            }
        }

        let result = WorkspaceConfigImportResult(
            status: .imported,
            workspace: workspace,
            workspaceID: workspace.id.uuidString,
            skillCount: workspace.skills.count,
            connectorCount: workspace.connectors.count,
            localToolCount: workspace.localTools.count,
            taskCount: workspace.tasks.count,
            quarantinedScheduleCount: quarantinedScheduleCount,
            skippedConnectorCount: skippedConnectorCount,
            skippedLocalToolCount: skippedLocalToolCount
        )
        AppLogger.audit(.workspaceImported, category: "Persistence", fields: result.auditFields, level: .info)
        return result
    }

    // MARK: - Export Helpers

    private static func loadResult(
        status: WorkspaceConfigLoadResult.Status,
        url: URL,
        config: WorkspaceConfig?,
        error: Error?
    ) -> WorkspaceConfigLoadResult {
        let nsError = error.map { $0 as NSError }
        return WorkspaceConfigLoadResult(
            status: status,
            path: url.path,
            config: config,
            errorType: error.map { String(describing: type(of: $0)) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription
        )
    }

    private static func write(_ config: WorkspaceConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: url)
    }

    private static func fetchGlobalSkills(modelContext: ModelContext) -> [Skill] {
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func fetchGlobalConnectors(modelContext: ModelContext) -> [Connector] {
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func fetchGlobalTools(modelContext: ModelContext) -> [LocalTool] {
        let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func skillsForExport(workspace: Workspace, globalSkills: [Skill]) -> [Skill] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalSkillIDs.compactMap(UUID.init(uuidString:)))
        let taskSkills = workspace.tasks.flatMap(\.skills)
        let enabledGlobals = globalSkills.filter { enabledGlobalIDs.contains($0.id) }
        let all = uniqueByID(workspace.skills + taskSkills + enabledGlobals) { $0.id }
        return all.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private static func connectorsForExport(
        workspace: Workspace,
        skills: [Skill],
        globalConnectors: [Connector]
    ) -> [Connector] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalConnectorIDs.compactMap(UUID.init(uuidString:)))
        let enabledGlobals = globalConnectors.filter { enabledGlobalIDs.contains($0.id) }
        let all = uniqueByID(workspace.connectors + skills.flatMap(\.connectors) + enabledGlobals) { $0.id }
        return all.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private static func toolsForExport(
        workspace: Workspace,
        skills: [Skill],
        globalTools: [LocalTool]
    ) -> [LocalTool] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalToolIDs.compactMap(UUID.init(uuidString:)))
        let enabledGlobals = globalTools.filter { enabledGlobalIDs.contains($0.id) }
        let all = uniqueByID(workspace.localTools + skills.flatMap(\.localTools) + enabledGlobals) { $0.id }
        return all.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private static func skillConfig(_ skill: Skill) -> SkillConfig? {
        // Guard against faulted/deleted SwiftData objects
        guard !skill.isDeleted, skill.modelContext != nil else { return nil }
        return SkillConfig(
            id: skill.id.uuidString,
            name: skill.name,
            icon: skill.icon,
            description: skill.skillDescription,
            allowedTools: skill.allowedTools,
            disallowedTools: skill.disallowedTools,
            customTools: skill.customTools,
            behaviorInstructions: skill.behaviorInstructions,
            environmentKeys: skill.environmentKeys,
            environmentValues: skill.exportableEnvironmentValues,
            isGlobal: skill.isGlobal,
            connectorIDs: skill.connectors.map { $0.id.uuidString },
            localToolIDs: skill.localTools.map { $0.id.uuidString },
            connectorNames: skill.connectors.map(\.name),
            localToolNames: skill.localTools.map(\.name),
            originPackageID: skill.originPackageID,
            originPackageVersion: skill.originPackageVersion,
            originComponentID: skill.originComponentID,
            originComponentKind: skill.originComponentKind,
            originSourceKind: skill.originSourceKind,
            createdAt: skill.createdAt,
            updatedAt: skill.updatedAt
        )
    }

    private static func connectorConfig(_ connector: Connector) -> ConnectorConfig? {
        guard !connector.isDeleted, connector.modelContext != nil else { return nil }
        guard ConnectorSecurityPolicy.isRuntimeSafe(connector) else { return nil }
        return ConnectorConfig(
            id: connector.id.uuidString,
            name: connector.name,
            serviceType: connector.serviceType,
            icon: connector.icon,
            description: connector.connectorDescription,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys,
            configKeys: connector.configKeys,
            configValues: connector.configValues,
            isGlobal: connector.isGlobal,
            notes: connector.notes,
            originPackageID: connector.originPackageID,
            originPackageVersion: connector.originPackageVersion,
            originComponentID: connector.originComponentID,
            originComponentKind: connector.originComponentKind,
            originSourceKind: connector.originSourceKind,
            createdAt: connector.createdAt,
            updatedAt: connector.updatedAt
        )
    }

    private static func localToolConfig(_ tool: LocalTool) -> LocalToolConfig? {
        guard !tool.isDeleted, tool.modelContext != nil else { return nil }
        guard LocalToolSecurityPolicy.isSafe(command: tool.command, arguments: tool.arguments) else { return nil }
        return LocalToolConfig(
            id: tool.id.uuidString,
            name: tool.name,
            description: tool.toolDescription,
            icon: tool.icon,
            toolType: tool.toolType,
            command: tool.command,
            arguments: tool.arguments,
            isGlobal: tool.isGlobal,
            originPackageID: tool.originPackageID,
            originPackageVersion: tool.originPackageVersion,
            originComponentID: tool.originComponentID,
            originComponentKind: tool.originComponentKind,
            originSourceKind: tool.originSourceKind,
            createdAt: tool.createdAt,
            updatedAt: tool.updatedAt
        )
    }

    private static func templateConfig(_ template: TaskTemplate) -> TemplateConfig {
        TemplateConfig(
            id: template.id.uuidString,
            name: template.name,
            icon: template.icon,
            description: template.templateDescription,
            beforeGoal: template.beforeGoal,
            mainGoal: template.mainGoal,
            afterGoal: template.afterGoal,
            beforeBudget: template.beforeBudget,
            mainBudget: template.mainBudget,
            afterBudget: template.afterBudget,
            beforeModel: template.beforeModel,
            mainModel: template.mainModel,
            afterModel: template.afterModel,
            variablesJSON: template.variablesJSON,
            hooksJSON: template.hooksJSON,
            passContextToMain: template.passContextToMain,
            passContextToAfter: template.passContextToAfter,
            defaultSkillIDs: template.defaultSkillIDs.isEmpty ? nil : template.defaultSkillIDs,
            originPackageID: template.originPackageID,
            originPackageVersion: template.originPackageVersion,
            originComponentID: template.originComponentID,
            originComponentKind: template.originComponentKind,
            originSourceKind: template.originSourceKind,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt
        )
    }

    private static func scheduleConfig(_ schedule: TaskSchedule) -> ScheduleConfig {
        ScheduleConfig(
            id: schedule.id.uuidString,
            name: schedule.name,
            isEnabled: schedule.isEnabled,
            goal: schedule.goal,
            routineDescription: schedule.routineDescription.isEmpty ? nil : schedule.routineDescription,
            routineInstructions: schedule.routineInstructions.isEmpty ? nil : schedule.routineInstructions,
            routinePaths: schedule.routinePaths.isEmpty ? nil : schedule.routinePaths,
            templateID: schedule.templateID?.uuidString,
            templateVariablesJSON: schedule.templateVariablesJSON,
            model: schedule.model,
            tokenBudget: schedule.tokenBudget,
            scheduleType: schedule.scheduleType.rawValue,
            nextFireDate: schedule.nextFireDate,
            intervalSeconds: schedule.intervalSeconds,
            dailyHour: schedule.dailyHour,
            dailyMinute: schedule.dailyMinute,
            weeklyDayOfWeek: schedule.weeklyDayOfWeek,
            fireCount: schedule.fireCount,
            skillIDs: schedule.skillIDs.isEmpty ? nil : schedule.skillIDs,
            conversationContext: schedule.conversationContext.isEmpty ? nil : schedule.conversationContext,
            resultMode: schedule.resultMode.rawValue,
            sourceTaskID: schedule.sourceTaskID?.uuidString,
            runResultsJSON: schedule.runResultsJSON == "[]" ? nil : schedule.runResultsJSON,
            runtimeID: schedule.runtimeID,
            lastFiredAt: schedule.lastFiredAt,
            createdAt: schedule.createdAt,
            updatedAt: schedule.updatedAt
        )
    }

    private static func taskConfig(_ task: AgentTask) -> TaskConfig {
        let sortedRuns = task.runs.sorted { $0.startedAt < $1.startedAt }
        let runIDToIndex = Dictionary(
            sortedRuns.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let runConfigs = sortedRuns.map { run in
            RunConfig(
                id: run.id.uuidString,
                status: run.status.rawValue,
                startedAt: run.startedAt,
                completedAt: run.completedAt,
                tokensUsed: run.tokensUsed,
                inputTokens: run.inputTokens,
                outputTokens: run.outputTokens,
                runtimeID: run.runtimeID,
                providerSessionId: run.providerSessionId,
                providerVersion: run.providerVersion,
                executionEnvironmentSnapshotJSON: run.executionEnvironmentSnapshotJSON,
                exitCode: run.exitCode,
                output: run.output,
                costUSD: run.costUSD,
                stopReason: run.stopReason,
                fileChangesJSON: run.fileChangesJSON
            )
        }

        let eventConfigs = task.events.sorted(by: { $0.timestamp < $1.timestamp }).map { event in
            EventConfig(
                id: event.id.uuidString,
                type: event.type,
                payload: event.payload,
                timestamp: event.timestamp,
                category: event.category,
                agentName: event.agentName,
                agentId: event.agentId,
                teamName: event.teamName,
                runIndex: event.run.flatMap { runIDToIndex[$0.id] }
            )
        }

        let snapshots = (task.skillSnapshots.isEmpty
            ? task.skills.map(SkillSnapshotConfig.init(skill:))
            : task.skillSnapshots).map(redactedSkillSnapshot)

        return TaskConfig(
            id: task.id.uuidString,
            title: task.title,
            goal: task.goal,
            status: task.status.rawValue,
            isPinned: task.isPinned ? true : nil,
            isDone: task.isDone ? true : nil,
            inputs: task.inputs,
            constraints: task.constraints,
            acceptanceCriteria: task.acceptanceCriteria,
            tokenBudget: task.tokenBudget,
            tokensUsed: task.tokensUsed,
            model: task.model,
            runtimeID: task.runtimeID,
            costUSD: task.costUSD,
            sessionId: task.sessionId,
            maxTurns: task.maxTurns,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt,
            unreadAt: task.unreadAt,
            isolationStrategy: task.isolationStrategy.rawValue,
            validationStrategy: task.validationStrategy.rawValue,
            testCommand: task.testCommand,
            draftMessages: task.draftMessages,
            chainedGoal: task.chainedGoal,
            chainedFromID: task.chainedFromID?.uuidString,
            useAgentTeam: task.useAgentTeam,
            teamSize: task.teamSize,
            teamInstructions: task.teamInstructions,
            templateID: task.templateID?.uuidString,
            templateHooksJSON: task.templateHooksJSON,
            runs: runConfigs,
            events: eventConfigs,
            artifacts: task.artifacts.map(ArtifactConfig.init(artifact:)),
            skillIDs: task.skills.map { $0.id.uuidString },
            skillNames: task.skills.map(\.name),
            skillSnapshots: snapshots,
            executionEnvironmentSnapshotJSON: sanitizedExecutionEnvironmentJSON(task.executionEnvironmentSnapshotJSON, preservingHost: true)
        )
    }

    private static func uniqueByID<T>(_ values: [T], id: (T) -> UUID) -> [T] {
        var seen = Set<UUID>()
        var result: [T] = []
        for value in values {
            let valueID = id(value)
            guard !seen.contains(valueID) else { continue }
            seen.insert(valueID)
            result.append(value)
        }
        return result
    }

    private static func sanitizedExecutionEnvironmentJSON(_ json: String?, preservingHost: Bool = false) -> String? {
        let environment = ExecutionEnvironmentStore.decode(json)
        return preservingHost
            ? ExecutionEnvironmentStore.encodeSnapshot(environment)
            : ExecutionEnvironmentStore.encode(environment)
    }

    // MARK: - Import Helpers

    private static func makeConnector(from config: ConnectorConfig) -> Connector? {
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: config.baseURL,
            authMethod: config.authMethod,
            credentialKeys: config.credentialKeys
        ) == nil else {
            return nil
        }
        let connector = Connector(
            name: config.name,
            serviceType: config.serviceType,
            icon: config.icon,
            connectorDescription: config.description,
            baseURL: config.baseURL,
            authMethod: config.authMethod
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            connector.id = id
        }
        connector.credentialKeys = config.credentialKeys
        connector.credentialValues = Array(repeating: "", count: config.credentialKeys.count)
        connector.configKeys = config.configKeys
        connector.configValues = config.configValues
        connector.isGlobal = config.isGlobal ?? false
        connector.notes = config.notes
        connector.originPackageID = config.originPackageID
        connector.originPackageVersion = config.originPackageVersion
        connector.originComponentID = config.originComponentID
        connector.originComponentKind = config.originComponentKind
        connector.originSourceKind = config.originSourceKind
        connector.createdAt = config.createdAt ?? connector.createdAt
        connector.updatedAt = config.updatedAt ?? connector.updatedAt
        return connector
    }

    private static func makeConnector(from snapshot: ConnectorSnapshotConfig, workspace: Workspace) -> Connector? {
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: snapshot.baseURL,
            authMethod: snapshot.authMethod,
            credentialKeys: snapshot.credentialKeys
        ) == nil else {
            return nil
        }
        let connector = Connector(
            name: snapshot.name,
            serviceType: snapshot.serviceType,
            icon: snapshot.icon,
            connectorDescription: snapshot.description,
            baseURL: snapshot.baseURL,
            authMethod: snapshot.authMethod
        )
        if let id = snapshot.id.flatMap(UUID.init(uuidString:)) {
            connector.id = id
        }
        connector.credentialKeys = snapshot.credentialKeys
        connector.credentialValues = Array(repeating: "", count: snapshot.credentialKeys.count)
        connector.configKeys = snapshot.configKeys
        connector.configValues = snapshot.configValues
        connector.isGlobal = false
        connector.notes = snapshot.notes
        connector.createdAt = snapshot.createdAt ?? connector.createdAt
        connector.updatedAt = snapshot.updatedAt ?? connector.updatedAt
        connector.workspace = workspace
        return connector
    }

    private static func makeLocalTool(from config: LocalToolConfig) -> LocalTool? {
        guard LocalToolSecurityPolicy.isSafe(command: config.command, arguments: config.arguments) else {
            return nil
        }
        let tool = LocalTool(
            name: config.name,
            toolDescription: config.description,
            icon: config.icon,
            toolType: config.toolType,
            command: config.command,
            arguments: config.arguments
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            tool.id = id
        }
        tool.isGlobal = config.isGlobal ?? false
        tool.originPackageID = config.originPackageID
        tool.originPackageVersion = config.originPackageVersion
        tool.originComponentID = config.originComponentID
        tool.originComponentKind = config.originComponentKind
        tool.originSourceKind = config.originSourceKind
        tool.createdAt = config.createdAt ?? tool.createdAt
        tool.updatedAt = config.updatedAt ?? tool.updatedAt
        return tool
    }

    private static func makeLocalTool(from snapshot: LocalToolSnapshotConfig, workspace: Workspace) -> LocalTool? {
        guard LocalToolSecurityPolicy.isSafe(command: snapshot.command, arguments: snapshot.arguments) else {
            return nil
        }
        let tool = LocalTool(
            name: snapshot.name,
            toolDescription: snapshot.description,
            icon: snapshot.icon,
            toolType: snapshot.toolType,
            command: snapshot.command,
            arguments: snapshot.arguments
        )
        if let id = snapshot.id.flatMap(UUID.init(uuidString:)) {
            tool.id = id
        }
        tool.isGlobal = false
        tool.createdAt = snapshot.createdAt ?? tool.createdAt
        tool.updatedAt = snapshot.updatedAt ?? tool.updatedAt
        tool.workspace = workspace
        return tool
    }

    private static func makeSkill(from config: SkillConfig) -> Skill {
        let skill = Skill(
            name: config.name,
            icon: config.icon,
            skillDescription: config.description,
            allowedTools: config.allowedTools,
            disallowedTools: config.disallowedTools,
            customTools: config.customTools,
            behaviorInstructions: config.behaviorInstructions
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            skill.id = id
        }
        skill.environmentKeys = config.environmentKeys
        let storedValues = Array(config.environmentValues.prefix(config.environmentKeys.count))
        skill.environmentValues = storedValues + Array(repeating: "", count: max(0, config.environmentKeys.count - storedValues.count))
        let builtIn = Skill.isBuiltInName(config.name)
        skill.isBuiltIn = builtIn
        skill.isGlobal = builtIn || (config.isGlobal ?? false)
        skill.originPackageID = config.originPackageID
        skill.originPackageVersion = config.originPackageVersion
        skill.originComponentID = config.originComponentID
        skill.originComponentKind = config.originComponentKind
        skill.originSourceKind = config.originSourceKind
        skill.createdAt = config.createdAt ?? skill.createdAt
        skill.updatedAt = config.updatedAt ?? skill.updatedAt
        skill.migrateSecretsToKeychain()
        return skill
    }

    private static func makeRestoredSkill(from snapshot: SkillSnapshotConfig, workspace: Workspace) -> Skill {
        let restoredName = snapshot.name.hasSuffix(" (Restored)") ? snapshot.name : "\(snapshot.name) (Restored)"
        let restoredDescription = snapshot.description.isEmpty
            ? "Restored from task history snapshot."
            : "\(snapshot.description)\n\nRestored from task history snapshot."
        let skill = Skill(
            name: restoredName,
            icon: snapshot.icon,
            skillDescription: restoredDescription,
            allowedTools: snapshot.allowedTools,
            disallowedTools: snapshot.disallowedTools,
            customTools: snapshot.customTools,
            behaviorInstructions: snapshot.behaviorInstructions
        )
        if let id = snapshot.id.flatMap(UUID.init(uuidString:)) {
            skill.id = id
        }
        skill.environmentKeys = snapshot.environmentKeys
        let storedValues = Array(snapshot.environmentValues.prefix(snapshot.environmentKeys.count))
        skill.environmentValues = storedValues + Array(repeating: "", count: max(0, snapshot.environmentKeys.count - storedValues.count))
        skill.isGlobal = false
        skill.createdAt = snapshot.createdAt ?? skill.createdAt
        skill.updatedAt = Date()
        skill.workspace = workspace
        skill.migrateSecretsToKeychain()
        return skill
    }

    private static func makeTemplate(from config: TemplateConfig, workspace: Workspace) -> TaskTemplate {
        let template = TaskTemplate(
            name: config.name,
            mainGoal: config.mainGoal,
            workspace: workspace,
            icon: config.icon,
            templateDescription: config.description
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            template.id = id
        }
        template.beforeGoal = config.beforeGoal
        template.afterGoal = config.afterGoal
        template.beforeBudget = config.beforeBudget
        template.mainBudget = config.mainBudget
        template.afterBudget = config.afterBudget
        template.beforeModel = config.beforeModel
        template.mainModel = config.mainModel
        template.afterModel = config.afterModel
        template.variablesJSON = config.variablesJSON
        template.hooksJSON = config.hooksJSON
        template.passContextToMain = config.passContextToMain
        template.passContextToAfter = config.passContextToAfter
        template.defaultSkillIDs = config.defaultSkillIDs ?? []
        template.originPackageID = config.originPackageID
        template.originPackageVersion = config.originPackageVersion
        template.originComponentID = config.originComponentID
        template.originComponentKind = config.originComponentKind
        template.originSourceKind = config.originSourceKind
        template.createdAt = config.createdAt ?? template.createdAt
        template.updatedAt = config.updatedAt ?? template.updatedAt
        return template
    }

    private static func redactedSkillSnapshot(_ snapshot: SkillSnapshotConfig) -> SkillSnapshotConfig {
        SkillSnapshotConfig(
            id: snapshot.id,
            name: snapshot.name,
            icon: snapshot.icon,
            description: snapshot.description,
            allowedTools: snapshot.allowedTools,
            disallowedTools: snapshot.disallowedTools,
            customTools: snapshot.customTools,
            behaviorInstructions: snapshot.behaviorInstructions,
            environmentKeys: snapshot.environmentKeys,
            environmentValues: Array(repeating: "", count: snapshot.environmentKeys.count),
            isGlobal: snapshot.isGlobal,
            connectorIDs: snapshot.connectorIDs,
            localToolIDs: snapshot.localToolIDs,
            connectorSnapshots: snapshot.connectorSnapshots,
            localToolSnapshots: snapshot.localToolSnapshots,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
    }

    private static func makeImportedSchedule(
        from config: ScheduleConfig,
        workspace: Workspace,
        trustPolicy: ScheduleImportTrustPolicy
    ) -> TaskSchedule {
        let schedule = TaskSchedule(
            name: config.name,
            goal: config.goal,
            workspace: workspace,
            runtimeID: config.runtimeID ?? AgentRuntimeID.claudeCode.rawValue,
            model: config.model,
            tokenBudget: config.tokenBudget,
            scheduleType: ScheduleType(rawValue: config.scheduleType) ?? .once,
            nextFireDate: config.nextFireDate
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            schedule.id = id
        }
        schedule.isEnabled = trustPolicy.enabledState(for: config)
        schedule.templateID = config.templateID.flatMap(UUID.init(uuidString:))
        schedule.templateVariablesJSON = config.templateVariablesJSON
        schedule.routineDescription = config.routineDescription ?? schedule.routineDescription
        schedule.routineInstructions = config.routineInstructions ?? schedule.routineInstructions
        schedule.routinePaths = config.routinePaths ?? schedule.routinePaths
        schedule.intervalSeconds = config.intervalSeconds
        schedule.dailyHour = config.dailyHour
        schedule.dailyMinute = config.dailyMinute
        schedule.weeklyDayOfWeek = config.weeklyDayOfWeek
        schedule.fireCount = config.fireCount
        schedule.skillIDs = config.skillIDs ?? []
        schedule.conversationContext = config.conversationContext ?? ""
        schedule.resultMode = config.resultMode.flatMap(ScheduleResultMode.init(rawValue:)) ?? .sameThread
        schedule.sourceTaskID = config.sourceTaskID.flatMap(UUID.init(uuidString:))
        schedule.runResultsJSON = config.runResultsJSON ?? "[]"
        schedule.lastFiredAt = config.lastFiredAt
        schedule.createdAt = config.createdAt ?? schedule.createdAt
        schedule.updatedAt = config.updatedAt ?? schedule.updatedAt
        return schedule
    }

    private static func reusedGlobalSkill(for config: SkillConfig, modelContext: ModelContext) -> Skill? {
        guard config.isGlobal == true || Skill.isBuiltInName(config.name) else {
            return nil
        }

        if let idString = config.id,
           let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id && $0.isGlobal })
            if let exact = (try? modelContext.fetch(descriptor))?.first {
                return exact
            }
        }

        guard Skill.isBuiltInName(config.name) else { return nil }
        let name = config.name
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.name == name && $0.isGlobal })
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func reusedGlobalConnector(for config: ConnectorConfig, modelContext: ModelContext) -> Connector? {
        guard config.isGlobal == true else { return nil }
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: config.baseURL,
            authMethod: config.authMethod,
            credentialKeys: config.credentialKeys
        ) == nil else {
            return nil
        }

        if let idString = config.id,
           let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id && $0.isGlobal })
            if let exact = (try? modelContext.fetch(descriptor))?.first {
                return exact
            }
        }

        let name = config.name
        let serviceType = config.serviceType
        let baseURL = config.baseURL
        let descriptor = FetchDescriptor<Connector>(
            predicate: #Predicate {
                $0.name == name &&
                $0.serviceType == serviceType &&
                $0.baseURL == baseURL &&
                $0.isGlobal
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func reusedGlobalTool(for config: LocalToolConfig, modelContext: ModelContext) -> LocalTool? {
        guard config.isGlobal == true else { return nil }
        guard LocalToolSecurityPolicy.isSafe(command: config.command, arguments: config.arguments) else {
            return nil
        }

        if let idString = config.id,
           let id = UUID(uuidString: idString) {
            let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == id && $0.isGlobal })
            if let exact = (try? modelContext.fetch(descriptor))?.first {
                return exact
            }
        }

        let name = config.name
        let toolType = config.toolType
        let command = config.command
        let arguments = config.arguments
        let descriptor = FetchDescriptor<LocalTool>(
            predicate: #Predicate {
                $0.name == name &&
                $0.toolType == toolType &&
                $0.command == command &&
                $0.arguments == arguments &&
                $0.isGlobal
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func linkResources(
        skill: Skill,
        connectorIDs: [String]?,
        connectorNames: [String]?,
        localToolIDs: [String]?,
        localToolNames: [String]?,
        connectorsByID: [String: Connector],
        connectorsByName: [String: Connector],
        toolsByID: [String: LocalTool],
        toolsByName: [String: LocalTool]
    ) {
        if let connectorIDs, !connectorIDs.isEmpty {
            for id in connectorIDs {
                connectorsByID[id]?.skill = skill
            }
        } else {
            for name in connectorNames ?? [] {
                connectorsByName[name]?.skill = skill
            }
        }

        if let localToolIDs, !localToolIDs.isEmpty {
            for id in localToolIDs {
                toolsByID[id]?.skill = skill
            }
        } else {
            for name in localToolNames ?? [] {
                toolsByName[name]?.skill = skill
            }
        }
    }

    private static func importTask(
        _ config: TaskConfig,
        workspace: Workspace,
        modelContext: ModelContext,
        skillsByID: inout [String: Skill],
        skillsByName: inout [String: Skill],
        connectorsByID: inout [String: Connector],
        connectorsByName: inout [String: Connector],
        toolsByID: inout [String: LocalTool],
        toolsByName: inout [String: LocalTool]
    ) {
        let importedRuntime = config.runtimeID.flatMap(AgentRuntimeID.init(rawValue:)) ?? .claudeCode
        let task = AgentTask(
            title: config.title,
            goal: config.goal,
            workspace: workspace,
            tokenBudget: config.tokenBudget,
            model: config.model,
            runtime: importedRuntime
        )
        if let id = config.id.flatMap(UUID.init(uuidString:)) {
            task.id = id
        }
        task.status = TaskStatus(rawValue: config.status) ?? .completed
        task.isPinned = config.isPinned ?? false
        task.isDone = config.isDone ?? false
        task.inputs = config.inputs
        task.constraints = config.constraints
        task.acceptanceCriteria = config.acceptanceCriteria
        task.tokensUsed = config.tokensUsed
        task.runtimeID = importedRuntime.rawValue
        task.costUSD = config.costUSD
        task.sessionId = config.sessionId
        task.maxTurns = config.maxTurns
        task.createdAt = config.createdAt
        task.updatedAt = config.updatedAt
        task.completedAt = config.completedAt
        task.unreadAt = config.unreadAt
        if let value = config.isolationStrategy {
            task.isolationStrategy = IsolationStrategy(rawValue: value) ?? .sameDirectory
        }
        let validation = importedValidationConfiguration(
            strategy: config.validationStrategy,
            testCommand: config.testCommand,
            workspacePath: workspace.primaryPath
        )
        task.validationStrategy = validation.strategy
        task.testCommand = validation.testCommand
        task.draftMessages = config.draftMessages ?? ""
        task.chainedGoal = config.chainedGoal ?? ""
        if let id = config.chainedFromID {
            task.chainedFromID = UUID(uuidString: id)
        }
        task.useAgentTeam = config.useAgentTeam ?? false
        task.teamSize = config.teamSize ?? 3
        task.teamInstructions = config.teamInstructions ?? ""
        if let id = config.templateID {
            task.templateID = UUID(uuidString: id)
        }
        task.templateHooksJSON = config.templateHooksJSON ?? ""
        task.skillSnapshots = config.skillSnapshots ?? []
        task.executionEnvironmentSnapshotJSON = sanitizedExecutionEnvironmentJSON(
            config.executionEnvironmentSnapshotJSON,
            preservingHost: true
        )
        modelContext.insert(task)

        linkSkills(
            to: task,
            skillIDs: config.skillIDs,
            legacySkillNames: config.skillNames,
            snapshots: config.skillSnapshots ?? [],
            workspace: workspace,
            modelContext: modelContext,
            skillsByID: &skillsByID,
            skillsByName: &skillsByName,
            connectorsByID: &connectorsByID,
            connectorsByName: &connectorsByName,
            toolsByID: &toolsByID,
            toolsByName: &toolsByName
        )
        if task.skillSnapshots.isEmpty {
            TaskCapabilitySnapshotter.capture(for: task)
        }

        var importedRuns: [TaskRun] = []
        for rc in config.runs {
            let run = TaskRun(task: task)
            if let id = rc.id.flatMap(UUID.init(uuidString:)) {
                run.id = id
            }
            run.status = RunStatus(rawValue: rc.status) ?? .completed
            run.startedAt = rc.startedAt
            run.completedAt = rc.completedAt
            run.tokensUsed = rc.tokensUsed
            run.inputTokens = rc.inputTokens ?? 0
            run.outputTokens = rc.outputTokens ?? 0
            run.runtimeID = rc.runtimeID ?? task.runtimeID
            run.providerSessionId = rc.providerSessionId
            run.providerVersion = rc.providerVersion
            run.executionEnvironmentSnapshotJSON = sanitizedExecutionEnvironmentJSON(
                rc.executionEnvironmentSnapshotJSON,
                preservingHost: true
            )
            run.exitCode = rc.exitCode
            run.output = rc.output
            run.costUSD = rc.costUSD
            run.stopReason = rc.stopReason
            run.fileChangesJSON = rc.fileChangesJSON
            modelContext.insert(run)
            importedRuns.append(run)
        }

        for ec in config.events {
            let run = ec.runIndex.flatMap { index in
                index < importedRuns.count ? importedRuns[index] : nil
            }
            let event = TaskEvent(
                task: task,
                type: ec.type,
                payload: ec.payload,
                run: run,
                agentName: ec.agentName,
                agentId: ec.agentId,
                teamName: ec.teamName
            )
            if let id = ec.id.flatMap(UUID.init(uuidString:)) {
                event.id = id
            }
            event.timestamp = ec.timestamp
            event.category = ec.category
            modelContext.insert(event)
        }

        for ac in config.artifacts ?? [] {
            let artifact = Artifact(
                task: task,
                type: ac.type,
                path: ac.path,
                content: ac.content,
                version: ac.version
            )
            if let id = ac.id.flatMap(UUID.init(uuidString:)) {
                artifact.id = id
            }
            artifact.createdAt = ac.createdAt
            modelContext.insert(artifact)
        }
    }

    private static func importedValidationConfiguration(
        strategy rawStrategy: String?,
        testCommand rawCommand: String?,
        workspacePath: String?
    ) -> (strategy: ValidationStrategy, testCommand: String) {
        let strategy = rawStrategy.flatMap(ValidationStrategy.init(rawValue:)) ?? .manual
        let command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard strategy == .runTests else {
            return (strategy, command)
        }
        guard ValidationCommandPolicy.isRunTestsCommandAllowed(command, workspacePath: workspacePath) else {
            return (.runTests, "")
        }
        return (.runTests, command)
    }

    private static func linkSkills(
        to task: AgentTask,
        skillIDs: [String]?,
        legacySkillNames: [String],
        snapshots: [SkillSnapshotConfig],
        workspace: Workspace,
        modelContext: ModelContext,
        skillsByID: inout [String: Skill],
        skillsByName: inout [String: Skill],
        connectorsByID: inout [String: Connector],
        connectorsByName: inout [String: Connector],
        toolsByID: inout [String: LocalTool],
        toolsByName: inout [String: LocalTool]
    ) {
        let snapshotsByID = Dictionary(
            snapshots.compactMap { snapshot -> (String, SkillSnapshotConfig)? in
                guard let id = snapshot.id else { return nil }
                return (id, snapshot)
            },
            uniquingKeysWith: { first, _ in first }
        )

        if let skillIDs, !skillIDs.isEmpty {
            for id in skillIDs {
                if let skill = skillsByID[id] {
                    appendUnique(skill, to: &task.skills)
                    continue
                }
                if let snapshot = snapshotsByID[id] {
                    let restored = restoreSkill(
                        from: snapshot,
                        workspace: workspace,
                        modelContext: modelContext,
                        connectorsByID: &connectorsByID,
                        connectorsByName: &connectorsByName,
                        toolsByID: &toolsByID,
                        toolsByName: &toolsByName
                    )
                    skillsByID[restored.id.uuidString] = restored
                    if skillsByName[restored.name] == nil {
                        skillsByName[restored.name] = restored
                    }
                    appendUnique(restored, to: &task.skills)
                }
            }
        } else {
            for name in legacySkillNames {
                if let skill = skillsByName[name] {
                    appendUnique(skill, to: &task.skills)
                }
            }
        }
    }

    private static func restoreSkill(
        from snapshot: SkillSnapshotConfig,
        workspace: Workspace,
        modelContext: ModelContext,
        connectorsByID: inout [String: Connector],
        connectorsByName: inout [String: Connector],
        toolsByID: inout [String: LocalTool],
        toolsByName: inout [String: LocalTool]
    ) -> Skill {
        for connectorSnapshot in snapshot.connectorSnapshots ?? [] {
            guard let id = connectorSnapshot.id, connectorsByID[id] == nil else { continue }
            guard let connector = makeConnector(from: connectorSnapshot, workspace: workspace) else { continue }
            modelContext.insert(connector)
            connectorsByID[connector.id.uuidString] = connector
            if connectorsByName[connector.name] == nil {
                connectorsByName[connector.name] = connector
            }
        }
        for toolSnapshot in snapshot.localToolSnapshots ?? [] {
            guard let id = toolSnapshot.id, toolsByID[id] == nil else { continue }
            guard let tool = makeLocalTool(from: toolSnapshot, workspace: workspace) else { continue }
            modelContext.insert(tool)
            toolsByID[tool.id.uuidString] = tool
            if toolsByName[tool.name] == nil {
                toolsByName[tool.name] = tool
            }
        }

        let skill = makeRestoredSkill(from: snapshot, workspace: workspace)
        modelContext.insert(skill)
        linkResources(
            skill: skill,
            connectorIDs: snapshot.connectorIDs,
            connectorNames: nil,
            localToolIDs: snapshot.localToolIDs,
            localToolNames: nil,
            connectorsByID: connectorsByID,
            connectorsByName: connectorsByName,
            toolsByID: toolsByID,
            toolsByName: toolsByName
        )
        return skill
    }

    private static func appendUnique(_ skill: Skill, to skills: inout [Skill]) {
        guard !skills.contains(where: { $0.id == skill.id }) else { return }
        skills.append(skill)
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private static func importedActiveWorkingPath(
        _ activeWorkingPath: String?,
        primaryPath: String,
        additionalPaths: [String],
        fileManager: FileManager = .default
    ) -> String? {
        guard let active = activeWorkingPath,
              !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let activePath = WorkspacePathPresentation.standardizedPath(active)
        guard !activePath.isEmpty,
              isExistingDirectory(activePath, fileManager: fileManager),
              let canonicalActive = canonicalPath(activePath) else {
            return nil
        }

        let primary = WorkspacePathPresentation.standardizedPath(primaryPath)
        guard canonicalActive != canonicalPath(primary) else {
            return nil
        }

        let workspaceRootPaths = ([primaryPath] + additionalPaths)
            .map(WorkspacePathPresentation.standardizedPath)
            .filter { !$0.isEmpty }
        let canonicalWorkspaceRoots = workspaceRootPaths.compactMap(canonicalPath)

        if canonicalWorkspaceRoots.contains(where: { isPath(canonicalActive, insideOrEqualTo: $0) }) {
            return activePath
        }
        if isRegisteredWorktree(activePath, attachedTo: workspaceRootPaths, fileManager: fileManager) {
            return activePath
        }

        return nil
    }

    private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func canonicalPath(_ path: String) -> String? {
        ExecutionSandbox.canonicalize(path)
    }

    private struct GitDirectoryLayout {
        let gitDirectory: String
        let commonDirectory: String
    }

    private static func isRegisteredWorktree(
        _ activePath: String,
        attachedTo workspaceRootPaths: [String],
        fileManager: FileManager
    ) -> Bool {
        guard let activeLayout = gitDirectoryLayout(for: activePath, fileManager: fileManager),
              worktreeAdminDirectory(activeLayout.gitDirectory, pointsBackTo: activePath, fileManager: fileManager) else {
            return false
        }

        return workspaceRootPaths.contains { rootPath in
            guard let rootLayout = gitDirectoryLayout(for: rootPath, fileManager: fileManager),
                  activeLayout.commonDirectory == rootLayout.commonDirectory else {
                return false
            }
            let worktreesDirectory = URL(fileURLWithPath: rootLayout.commonDirectory, isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
                .path
            return activeLayout.gitDirectory != activeLayout.commonDirectory
                && isPath(activeLayout.gitDirectory, insideOrEqualTo: worktreesDirectory)
        }
    }

    private static func gitDirectoryLayout(for path: String, fileManager: FileManager) -> GitDirectoryLayout? {
        guard let gitDirectory = gitDirectoryReference(for: path, fileManager: fileManager),
              isExistingDirectory(gitDirectory, fileManager: fileManager) else {
            return nil
        }
        let commonDirectory = commonGitDirectory(for: gitDirectory, fileManager: fileManager) ?? gitDirectory
        guard isExistingDirectory(commonDirectory, fileManager: fileManager) else {
            return nil
        }
        return GitDirectoryLayout(gitDirectory: gitDirectory, commonDirectory: commonDirectory)
    }

    private static func commonGitDirectory(for gitDirectory: String, fileManager: FileManager) -> String? {
        let commonDirPath = URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("commondir")
            .path
        guard let data = fileManager.contents(atPath: commonDirPath),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let resolved = value.hasPrefix("/")
            ? value
            : URL(fileURLWithPath: gitDirectory, isDirectory: true)
                .appendingPathComponent(value)
                .standardizedFileURL
                .path
        return canonicalPath(resolved)
    }

    private static func worktreeAdminDirectory(
        _ gitDirectory: String,
        pointsBackTo activePath: String,
        fileManager: FileManager
    ) -> Bool {
        let pointerPath = URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("gitdir")
            .path
        guard let data = fileManager.contents(atPath: pointerPath),
              let raw = String(data: data, encoding: .utf8) else {
            return false
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let resolved = value.hasPrefix("/")
            ? value
            : URL(fileURLWithPath: gitDirectory, isDirectory: true)
                .appendingPathComponent(value)
                .standardizedFileURL
                .path
        guard let canonicalGitFile = canonicalPath(resolved),
              let canonicalActive = canonicalPath(activePath) else {
            return false
        }
        let pointedWorktree = (canonicalGitFile as NSString).lastPathComponent == ".git"
            ? (canonicalGitFile as NSString).deletingLastPathComponent
            : canonicalGitFile
        return pointedWorktree == canonicalActive
    }

    private static func gitDirectoryReference(for path: String, fileManager: FileManager) -> String? {
        let gitPath = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(".git")
            .path
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return canonicalPath(gitPath)
        }
        guard let data = fileManager.contents(atPath: gitPath),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first,
              line.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let rawReference = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawReference.isEmpty else { return nil }
        let referencePath: String
        if rawReference.hasPrefix("/") {
            referencePath = rawReference
        } else {
            referencePath = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(rawReference)
                .standardizedFileURL
                .path
        }
        return canonicalPath(referencePath)
    }

    private static func isPath(_ path: String, insideOrEqualTo root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else { return false }
        if root == "/" {
            return path.hasPrefix("/")
        }
        return path == root || path.hasPrefix(root + "/")
    }
}

/// Serializes workspace auto-export JSON encode + file writes off the main actor.
///
/// Actor isolation guarantees that two auto-exports never write the same file
/// concurrently, and the `.atomic` write means `WorkspaceRecoveryService` /
/// `loadConfig` can never observe a torn file. Auto-export drops `.prettyPrinted`
/// (kept only for explicit user-facing exports via `WorkspaceConfigManager.write`)
/// while preserving `.sortedKeys` so the on-disk recovery file stays deterministic.
actor WorkspaceAutoExportWriter {
    static let shared = WorkspaceAutoExportWriter()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func write(
        _ config: WorkspaceConfigManager.WorkspaceConfig,
        to url: URL,
        workspaceID: String
    ) {
        do {
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            let nsError = error as NSError
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_failed",
                "diagnostic_result": "writeFailed",
                "workspace_id": workspaceID,
                "config_file": url.lastPathComponent,
                "path": url.path,
                "error_type": String(describing: type(of: error)),
                "error_domain": nsError.domain,
                "error_code": String(nsError.code),
                "error_description": nsError.localizedDescription
            ], level: .error)
        }
    }
}
