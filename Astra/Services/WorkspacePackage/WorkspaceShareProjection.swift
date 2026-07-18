import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Maps between the local-recovery `WorkspaceConfig` and the portable
/// `WorkspaceShareDocument`, in both directions.
///
/// - **Export** (`document(from:)`) projects a `WorkspaceConfig` — already
///   produced by `WorkspaceConfigManager.export`, which applies the real
///   security gates (credential-name-only connectors, secret-env blanking,
///   safe-command tools, no OAuth profiles) — down to the allowlist DTO. The
///   projection *is* the redaction boundary: it copies only shareable fields
///   and flattens every UUID resource link to a name, so machine-local and
///   local-authority fields have nowhere to land.
/// - **Import** (`WorkspaceShareImporter`) builds a fresh, fully
///   workspace-scoped object graph from the DTO — new UUIDs, `isGlobal = false`,
///   never the global-reuse or built-in-name paths — so a share can neither
///   collide with the recipient's catalog nor activate anything globally.
enum WorkspaceShareProjection {
    /// Returns `baseURL` with any `user[:password]@` userinfo removed. Leaves a
    /// URL that can't be parsed unchanged (validation catches those separately).
    static func baseURLWithoutCredentials(_ baseURL: String) -> String {
        guard var components = URLComponents(string: baseURL),
              components.user != nil || components.password != nil else {
            return baseURL
        }
        components.user = nil
        components.password = nil
        return components.string ?? baseURL
    }

    static func document(from config: WorkspaceConfigManager.WorkspaceConfig) -> WorkspaceShareDocument {
        let connectorNameByID = Dictionary(
            (config.connectors ?? []).compactMap { c in c.id.map { ($0, c.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        let toolNameByID = Dictionary(
            (config.localTools ?? []).compactMap { t in t.id.map { ($0, t.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        let skillNameByID = Dictionary(
            config.skills.compactMap { s in s.id.map { ($0, s.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        let templateNameByID = Dictionary(
            (config.templates ?? []).compactMap { t in t.id.map { ($0, t.name) } },
            uniquingKeysWith: { first, _ in first }
        )

        func names(fromIDs ids: [String]?, fallback names: [String]?, map: [String: String]) -> [String] {
            let resolved = (ids ?? []).compactMap { map[$0] }
            let combined = resolved.isEmpty ? (names ?? []) : resolved
            return Array(NSOrderedSet(array: combined)).compactMap { $0 as? String }
        }

        let skills = config.skills.map { s in
            ShareSkill(
                name: s.name,
                icon: s.icon,
                description: s.description,
                allowedTools: s.allowedTools,
                disallowedTools: s.disallowedTools,
                customTools: s.customTools,
                behaviorInstructions: s.behaviorInstructions,
                environmentKeys: s.environmentKeys,
                environmentValues: s.environmentValues,
                connectorNames: names(fromIDs: s.connectorIDs, fallback: s.connectorNames, map: connectorNameByID),
                localToolNames: names(fromIDs: s.localToolIDs, fallback: s.localToolNames, map: toolNameByID)
            )
        }

        let connectors = (config.connectors ?? []).map { c in
            ShareConnector(
                name: c.name,
                serviceType: c.serviceType,
                icon: c.icon,
                description: c.description,
                // A base URL like https://user:pass@host embeds a credential;
                // strip the userinfo so it never travels (validation also blocks
                // it as defense in depth for a hand-tampered package).
                baseURL: Self.baseURLWithoutCredentials(c.baseURL),
                authMethod: c.authMethod,
                credentialKeys: c.credentialKeys,
                // Key NAMES only; values (which may hold sensitive data) do not
                // travel — the recipient re-enters them.
                configKeys: c.configKeys,
                notes: c.notes
            )
        }

        let localTools = (config.localTools ?? []).map { t in
            ShareLocalTool(
                name: t.name,
                description: t.description,
                icon: t.icon,
                toolType: t.toolType,
                command: t.command,
                arguments: t.arguments
            )
        }

        let templates = (config.templates ?? []).map { t in
            ShareTemplate(
                name: t.name,
                icon: t.icon,
                description: t.description,
                beforeGoal: t.beforeGoal,
                mainGoal: t.mainGoal,
                afterGoal: t.afterGoal,
                beforeBudget: t.beforeBudget,
                mainBudget: t.mainBudget,
                afterBudget: t.afterBudget,
                beforeModel: t.beforeModel,
                mainModel: t.mainModel,
                afterModel: t.afterModel,
                variablesJSON: t.variablesJSON,
                passContextToMain: t.passContextToMain,
                passContextToAfter: t.passContextToAfter,
                defaultSkillNames: names(fromIDs: t.defaultSkillIDs, fallback: nil, map: skillNameByID)
            )
        }

        let schedules = (config.schedules ?? []).map { s in
            ShareSchedule(
                name: s.name,
                goal: s.goal,
                routineDescription: s.routineDescription ?? "",
                routineInstructions: s.routineInstructions ?? "",
                templateName: s.templateID.flatMap { templateNameByID[$0] },
                // Routine paths are also embedded in the template-variables blob;
                // strip them so the recipient's `routinePaths` getter can't read
                // sender paths back out.
                templateVariablesJSON: TaskSchedule.templateVariablesJSONWithoutRoutinePaths(s.templateVariablesJSON),
                model: s.model,
                tokenBudget: s.tokenBudget,
                scheduleType: s.scheduleType,
                intervalSeconds: s.intervalSeconds,
                dailyHour: s.dailyHour,
                dailyMinute: s.dailyMinute,
                weeklyDayOfWeek: s.weeklyDayOfWeek,
                skillNames: names(fromIDs: s.skillIDs, fallback: nil, map: skillNameByID),
                resultMode: s.resultMode,
                runtimeID: s.runtimeID
            )
        }

        let sshConnections = config.sshConnections.map { c in
            ShareSSHConnection(
                name: c.name,
                host: c.host,
                user: c.user,
                port: c.port,
                remotePath: c.remotePath,
                configAlias: c.configAlias
            )
        }

        return WorkspaceShareDocument(
            name: config.name,
            icon: config.icon,
            instructions: config.instructions,
            capabilityIDs: config.enabledCapabilityIDs ?? [],
            packIDs: config.enabledPackIDs ?? [],
            skills: skills,
            connectors: connectors,
            localTools: localTools,
            templates: templates,
            schedules: schedules,
            sshConnections: sshConnections
        )
    }
}

struct WorkspaceShareImportResult {
    var workspace: Workspace
    var skillCount: Int
    var connectorCount: Int
    var localToolCount: Int
    var scheduleCount: Int
}

/// Builds a fresh, fully workspace-scoped object graph from a
/// `WorkspaceShareDocument`. Every resource is minted with a new `UUID`, owned
/// by the new workspace, `isGlobal = false`; links are resolved by name within
/// this document's own set. It never fetches or reuses the recipient's existing
/// resources and never routes a built-in-named skill into a global row — so
/// there is nothing to collide with and nothing to activate beyond the created
/// workspace.
@MainActor
enum WorkspaceShareImporter {
    static func makeWorkspace(
        from document: WorkspaceShareDocument,
        primaryPath: String,
        modelContext: ModelContext
    ) throws -> WorkspaceShareImportResult {
        let workspace = Workspace(
            name: document.name,
            primaryPath: primaryPath,
            icon: document.icon,
            instructions: document.instructions
        )
        // Enable-intent only; the caller reconciles capabilities to
        // installed-and-approved and packs to the recipient's catalog after apps
        // import. Enabled-GLOBAL sets are intentionally never populated — the DTO
        // cannot express them.
        workspace.enabledCapabilityIDs = document.capabilityIDs
        workspace.enabledPackIDs = document.packIDs
        modelContext.insert(workspace)

        var connectorsByName: [String: Connector] = [:]
        var connectorCount = 0
        for share in document.connectors {
            guard ConnectorSecurityPolicy.credentialTransportViolation(
                baseURL: share.baseURL,
                authMethod: share.authMethod,
                credentialKeys: share.credentialKeys
            ) == nil else { continue }
            let connector = Connector(
                name: share.name,
                serviceType: share.serviceType,
                icon: share.icon,
                connectorDescription: share.description,
                baseURL: share.baseURL,
                authMethod: share.authMethod
            )
            connector.credentialKeys = share.credentialKeys
            connector.credentialValues = Array(repeating: "", count: share.credentialKeys.count)
            // Config key names travel; values do not — the recipient re-enters
            // them (surfaced as a local-setup item in the review).
            connector.configKeys = share.configKeys
            connector.configValues = Array(repeating: "", count: share.configKeys.count)
            connector.isGlobal = false
            connector.notes = share.notes
            connector.workspace = workspace
            modelContext.insert(connector)
            connectorsByName[share.name] = connector
            connectorCount += 1
        }

        var toolsByName: [String: LocalTool] = [:]
        var localToolCount = 0
        for share in document.localTools {
            guard LocalToolSecurityPolicy.isSafe(command: share.command, arguments: share.arguments) else { continue }
            let tool = LocalTool(
                name: share.name,
                toolDescription: share.description,
                icon: share.icon,
                toolType: share.toolType,
                command: share.command,
                arguments: share.arguments
            )
            tool.isGlobal = false
            tool.workspace = workspace
            modelContext.insert(tool)
            toolsByName[share.name] = tool
            localToolCount += 1
        }

        var skillsByName: [String: Skill] = [:]
        for share in document.skills {
            let skill = Skill(
                name: share.name,
                icon: share.icon,
                skillDescription: share.description,
                allowedTools: share.allowedTools,
                disallowedTools: share.disallowedTools,
                customTools: share.customTools,
                behaviorInstructions: share.behaviorInstructions
            )
            skill.environmentKeys = share.environmentKeys
            let values = Array(share.environmentValues.prefix(share.environmentKeys.count))
            let padded = values + Array(repeating: "", count: max(0, share.environmentKeys.count - values.count))
            // Secret-keyed env values never travel; validation blocks a tampered
            // package that carries one, but blank them here as well so an
            // out-of-band import path can never persist a secret to SwiftData or
            // the Keychain via `migrateSecretsToKeychain()` below.
            skill.environmentValues = zip(share.environmentKeys, padded).map { key, value in
                Skill.isSecretEnvironmentKey(key) ? "" : value
            }
            // Always a fresh, workspace-local skill — never a built-in/global
            // row, so a share cannot reuse or collide with the recipient's
            // built-in skills.
            skill.isBuiltIn = false
            skill.isGlobal = false
            skill.workspace = workspace
            modelContext.insert(skill)
            for name in share.connectorNames { connectorsByName[name]?.skill = skill }
            for name in share.localToolNames { toolsByName[name]?.skill = skill }
            skill.migrateSecretsToKeychain()
            skillsByName[share.name] = skill
        }

        var templatesByName: [String: TaskTemplate] = [:]
        for share in document.templates {
            let template = TaskTemplate(
                name: share.name,
                mainGoal: share.mainGoal,
                workspace: workspace,
                icon: share.icon,
                templateDescription: share.description
            )
            template.beforeGoal = share.beforeGoal
            template.afterGoal = share.afterGoal
            template.beforeBudget = share.beforeBudget
            template.mainBudget = share.mainBudget
            template.afterBudget = share.afterBudget
            template.beforeModel = share.beforeModel
            template.mainModel = share.mainModel
            template.afterModel = share.afterModel
            template.variablesJSON = share.variablesJSON
            // Template hooks are deliberately not carried by the share format;
            // the imported template keeps the default (no) hooks.
            template.passContextToMain = share.passContextToMain
            template.passContextToAfter = share.passContextToAfter
            template.defaultSkillIDs = share.defaultSkillNames.compactMap { skillsByName[$0]?.id.uuidString }
            modelContext.insert(template)
            templatesByName[share.name] = template
        }

        var scheduleCount = 0
        for share in document.schedules {
            let schedule = TaskSchedule(
                name: share.name,
                goal: share.goal,
                workspace: workspace,
                runtimeID: share.runtimeID ?? AgentRuntimeID.claudeCode.rawValue,
                model: share.model,
                tokenBudget: share.tokenBudget,
                scheduleType: ScheduleType(rawValue: share.scheduleType) ?? .once,
                nextFireDate: Date()
            )
            // Imported routines are quarantined until the recipient re-enables
            // them (the sender's on/off state is not transferable authority).
            schedule.isEnabled = false
            schedule.templateID = share.templateName.flatMap { templatesByName[$0]?.id }
            schedule.templateVariablesJSON = share.templateVariablesJSON
            schedule.routineDescription = share.routineDescription
            schedule.routineInstructions = share.routineInstructions
            schedule.intervalSeconds = share.intervalSeconds
            schedule.dailyHour = share.dailyHour
            schedule.dailyMinute = share.dailyMinute
            schedule.weeklyDayOfWeek = share.weeklyDayOfWeek
            schedule.skillIDs = share.skillNames.compactMap { skillsByName[$0]?.id.uuidString }
            // A `.sameThread` routine posts results back to its source task, but
            // that task does not travel with the share (no `sourceTaskID`). Left
            // as-is the run would silently behave as `.newTask` while the config
            // claims same-thread; normalize to `.newTask` so behavior matches.
            let requested = share.resultMode.flatMap(ScheduleResultMode.init(rawValue:)) ?? .newTask
            schedule.resultMode = requested == .sameThread ? .newTask : requested
            // Recompute the next fire from now instead of trusting a stale
            // sender date; the routine is quarantined regardless.
            schedule.advanceNextFireDate()
            // A `.once` routine's single fire moment does not travel (no
            // nextFireDate in the share), and the constructor's fabricated `now`
            // would make it immediately due the moment the recipient re-enables
            // it from the routine list without editing. Push it to the far future
            // so re-enabling never auto-fires the sender's un-set date; the user
            // must open the routine and choose a new one.
            if schedule.scheduleType == .once {
                schedule.nextFireDate = .distantFuture
            }
            modelContext.insert(schedule)
            scheduleCount += 1
        }

        let sshConnections = document.sshConnections.map { share in
            SSHConnection(
                name: share.name,
                host: share.host,
                user: share.user,
                port: share.port,
                remotePath: share.remotePath,
                configAlias: share.configAlias
            )
        }
        if !sshConnections.isEmpty {
            // Throwing path: a swallowed write failure would let the import commit
            // its SwiftData rows while the advertised SSH connections are silently
            // absent, breaking the coordinator's all-or-nothing contract. On throw
            // the coordinator rolls back the fresh workspace and its destination.
            try SSHConnectionManager.saveOrThrow(sshConnections, workspacePath: primaryPath)
        }

        return WorkspaceShareImportResult(
            workspace: workspace,
            skillCount: document.skills.count,
            connectorCount: connectorCount,
            localToolCount: localToolCount,
            scheduleCount: scheduleCount
        )
    }
}
