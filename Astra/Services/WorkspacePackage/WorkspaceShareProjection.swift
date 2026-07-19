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
        guard var components = URLComponents(string: baseURL) else { return baseURL }
        // Strip userinfo (`user:pass@host`) AND any credential-like query item
        // (e.g. `?api_token=…`), both of which would otherwise carry a secret in
        // the base URL — the free-text scan does not cover `baseURL`.
        let hadUserinfo = components.user != nil || components.password != nil
        components.user = nil
        components.password = nil
        var strippedQuery = false
        if let items = components.queryItems {
            let kept = items.filter { !isCredentialLikeKey($0.name) }
            if kept.count != items.count {
                strippedQuery = true
                components.queryItems = kept.isEmpty ? nil : kept
            }
        }
        guard hadUserinfo || strippedQuery else { return baseURL }
        return components.string ?? baseURL
    }

    /// A query-parameter/env key name that names a credential value. Matches at
    /// component boundaries — splitting on `_`/`-`/`.`/space AND camelCase
    /// transitions — NOT as a substring, so `author`/`tokenizer`/`secretary` are
    /// not misclassified while `accessToken`/`clientSecret`/`authToken` are.
    static func isCredentialLikeKey(_ name: String) -> Bool {
        let credentialWords: Set<String> = [
            "token", "secret", "password", "passwd", "apikey", "key", "auth",
            "bearer", "credential", "credentials"
        ]
        let components = camelAndPunctuationComponents(name)
        return components.contains { credentialWords.contains($0) }
    }

    /// Lowercased word components of an identifier, split on punctuation/space and
    /// camelCase boundaries (`accessToken` -> `access`, `token`; `APIKey` ->
    /// `api`, `key`; `apikey` -> `apikey`).
    static func camelAndPunctuationComponents(_ name: String) -> [String] {
        let scalars = Array(name.unicodeScalars)
        var spaced = String.UnicodeScalarView()
        for (i, sc) in scalars.enumerated() {
            if sc == "_" || sc == "-" || sc == "." || sc == " " {
                spaced.append(" ")
                continue
            }
            if CharacterSet.uppercaseLetters.contains(sc), i > 0 {
                let prev = scalars[i - 1]
                let prevLower = CharacterSet.lowercaseLetters.contains(prev)
                let prevUpper = CharacterSet.uppercaseLetters.contains(prev)
                let nextLower = i + 1 < scalars.count && CharacterSet.lowercaseLetters.contains(scalars[i + 1])
                if prevLower || (prevUpper && nextLower) { spaced.append(" ") }
            }
            spaced.append(sc)
        }
        return String(spaced).lowercased().split(separator: " ").map(String.init)
    }

    /// Blanks the `defaultValue` of any template variable whose NAME is
    /// secret-like (`API_TOKEN`, …). The credential-assignment scan can't
    /// associate the separate `"name"`/`"defaultValue"` JSON fields, so a secret
    /// default would otherwise travel verbatim in a ready-to-use template.
    /// Returns the input unchanged if it doesn't decode as template variables.
    static func templateVariablesJSONBlankingSecrets(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              var variables = try? JSONDecoder().decode([TemplateVariable].self, from: data) else { return json }
        var changed = false
        for index in variables.indices
        where Skill.isSecretEnvironmentKey(variables[index].name) && !variables[index].defaultValue.isEmpty {
            variables[index].defaultValue = ""
            changed = true
        }
        guard changed,
              let encoded = try? JSONEncoder().encode(variables),
              let result = String(data: encoded, encoding: .utf8) else { return json }
        return result
    }

    /// True if the variables blob carries a nonempty secret-named default —
    /// used by validation to reject a hand-tampered package.
    static func templateVariablesCarrySecretDefault(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let variables = try? JSONDecoder().decode([TemplateVariable].self, from: data) else { return false }
        return variables.contains { Skill.isSecretEnvironmentKey($0.name) && !$0.defaultValue.isEmpty }
    }

    /// True if a TEMPLATE variables blob is present but does NOT decode as an
    /// array of `TemplateVariable` (the shape a `TaskTemplate`/`PluginTemplate`
    /// uses). A malformed blob slips past the secret-default scrub (which no-ops
    /// on a decode failure), so it would persist verbatim into the imported
    /// template — possibly carrying a secret default in a shape our decoder
    /// doesn't recognize. Validation rejects it rather than trusting an opaque
    /// payload. An empty string is the legitimate "no variables" value.
    static func templateVariablesJSONIsMalformed(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONDecoder().decode([TemplateVariable].self, from: data)) != nil else { return true }
        return false
    }

    /// True if a ROUTINE/SCHEDULE variables blob is present but does NOT decode
    /// as the `[String: String]` name→value map a `TaskSchedule` stores (a
    /// different shape than a template's `[TemplateVariable]` array). A malformed
    /// blob slips past the routine-path and secret scrubs (both no-op on a decode
    /// failure) and would persist verbatim into the imported schedule. `"{}"` and
    /// an empty string are the legitimate "no variables" values.
    static func scheduleTemplateVariablesJSONIsMalformed(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONDecoder().decode([String: String].self, from: data)) != nil else { return true }
        return false
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
            let ids = ids ?? []
            let resolved = ids.compactMap { map[$0] }
            let combined: [String]
            if ids.isEmpty {
                // Legacy skills stored only names.
                combined = names ?? []
            } else if resolved.count == ids.count {
                combined = resolved
            } else {
                // Some referenced IDs did not resolve — they were filtered from
                // the export by a security policy (e.g. an unsafe connector/tool).
                // Merge the saved fallback names so the dropped reference is
                // preserved and the referential-integrity validation surfaces it,
                // instead of silently exporting a skill missing part of its
                // declared behavior.
                combined = resolved + (names ?? [])
            }
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
                variablesJSON: templateVariablesJSONBlankingSecrets(t.variablesJSON),
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
                templateVariablesJSON: templateVariablesJSONBlankingSecrets(TaskSchedule.templateVariablesJSONWithoutRoutinePaths(s.templateVariablesJSON)),
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
            // Imported standalone (skill = nil): the skill loop deliberately does
            // not re-attach these, since a skill→localTool link auto-grants the
            // tool command + Bash in SkillResolver, defeating grant-stripping.
            modelContext.insert(tool)
            localToolCount += 1
        }

        var skillsByName: [String: Skill] = [:]
        for share in document.skills {
            // Neutralize tool AUTO-APPROVAL from an untrusted sender: `allowedTools`
            // + `customTools` flow into the agent's provider allow-list
            // (`Skill.allAllowedTools` → `--allowedTools`), which SKIPS the
            // permission prompt. An imported skill must not silently pre-authorize
            // e.g. `Bash` — the recipient re-grants after review (the plan
            // discloses what was requested). Restrictions (`disallowedTools`) are
            // safe to carry; only grants are stripped. Mirrors schedules importing
            // disabled and capabilities importing as drafts.
            let skill = Skill(
                name: share.name,
                icon: share.icon,
                skillDescription: share.description,
                allowedTools: [],
                disallowedTools: share.disallowedTools,
                customTools: [],
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
            // Deliberately do NOT wire imported local tools onto the skill.
            // `SkillResolver` auto-adds every linked local tool's `command` to the
            // skill's effective allow-list — and `Bash` for any CLI tool — which
            // flows into the provider `--allowedTools` and SKIPS the permission
            // prompt (see SkillResolver.resolvedAllowedTools / effectiveTools).
            // That would silently re-grant exactly the auto-approval we just
            // stripped by zeroing `allowedTools`/`customTools`. The tool is still
            // imported as a workspace-scoped standalone row (surfaced in the plan);
            // the recipient re-attaches it to the skill after review if desired.
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
            // Strip any hidden `__astra_routine_paths_json` blob on import too:
            // export removes it, but a tampered package could smuggle relative /
            // tilde-prefixed paths the absolute-path scan doesn't catch, which
            // would reactivate `TaskSchedule.routinePaths` once the recipient
            // re-enables the routine.
            schedule.templateVariablesJSON = TaskSchedule.templateVariablesJSONWithoutRoutinePaths(share.templateVariablesJSON)
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
